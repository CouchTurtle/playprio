import AppKit
import Combine
import CryptoKit
import os
import SystemConfiguration

/// The iPhone remote: a web page and a small JSON API on the local network. The page plays
/// silence and hands the Mac's track to iOS, so the iPhone shows it in its own Now Playing
/// views (StandBy, Lock Screen, Control Center); their buttons come back here like the
/// media keys.
///
/// Pairing: the QR code holds the page's URL with a random key after the "#", which browsers
/// never send. API requests carry an HMAC-SHA256 of method, path, time, a nonce and the body,
/// made with that key and valid once within a minute, so someone else on the network can
/// see the track names but can't control anything.
///
/// Lives on the main thread, like `Store`.
final class Companion: ObservableObject {
    static let shared = Companion()

    @Published private(set) var isOn = UserDefaults.standard.bool(forKey: Keys.enabled)
    /// Why the server isn't reachable, if it isn't.
    @Published private(set) var problem: String?
    /// When a paired iPhone last asked for the state (updated every few seconds at most).
    @Published private(set) var lastSeen: Date?

    /// An iPhone asked lately: its page is open and awake.
    var isConnected: Bool {
        lastSeen.map { Date().timeIntervalSince($0) < Self.listenerGone } ?? false
    }

    private enum Keys {
        static let enabled = "companionEnabled"
        static let key = "companionKey"
        static let port = "companionPort"
    }

    /// Fixed, so the iPhone's tab still works after PlayPrio restarts.
    static var port: UInt16 {
        let custom = UserDefaults.standard.integer(forKey: Keys.port)
        return (1...65535).contains(custom) ? UInt16(custom) : 47269
    }

    /// `log stream --predicate 'subsystem == "local.PlayPrio" && category == "Companion"'`
    private static let log = Logger(subsystem: "local.PlayPrio", category: "Companion")
    private static let longPollTimeout: TimeInterval = 25
    /// New with every launch (so with every new build): a page from before offers to reload.
    private static let pageVersion = String(UUID().uuidString.prefix(8))
    private static let maxClockSkew: TimeInterval = 60
    /// How often the sources are checked while an iPhone is listening.
    private static let refreshInterval: TimeInterval = 2
    /// An iPhone that hasn't asked for this long has gone away (or its page sleeps).
    private static let listenerGone: TimeInterval = 45

    private weak var store: Store?
    private var server: CompanionServer?
    private var observation: AnyCancellable?

    private var revision = 0
    private var entries: [Entry] = []
    private var nowID: String?
    private var volume: Float?
    private var muted = false
    private var player: CompanionLibrary.PlayerInfo?
    private var waiters: [UUID: (CompanionServer.Response) -> Void] = [:]
    private var refreshTimer: Timer?
    private var lastPoll = Date.distantPast
    private var seenNonces: [String: Date] = [:]
    private var artworkFiles: [String: Data] = [:]
    private var artworkNames: [URL: String] = [:]
    private var artworkOrder: [URL] = []
    private var library = CompanionLibrary.Home(language: "", shelves: [])
    private var libraryReadAt: Date?
    private var libraryWaiters: [(CompanionServer.Response) -> Void] = []
    private let albums = PageCache<CompanionLibrary.Album>(limit: 60)
    private let artists = PageCache<CompanionLibrary.Artist>(limit: 20)

    /// Starts serving if the remote is switched on, and follows the store from now on.
    func attach(_ store: Store) {
        self.store = store
        // objectWillChange fires before the change lands; the debounce reads it afterwards.
        observation = store.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in self?.storeChanged() }
        if isOn { startServer() }
    }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Keys.enabled)
        isOn = on
        on ? startServer() : stopServer()
    }

    /// Paired iPhones lose access until they scan the new code.
    func newKey() {
        UserDefaults.standard.set(Self.makeKey(), forKey: Keys.key)
        objectWillChange.send()
    }

    /// What the QR code holds. The key goes after "#", so it never travels over the network.
    var pairingURL: URL? {
        address.flatMap { URL(string: "http://\($0)/#k=\(key)") }
    }

    /// Where the iPhone finds the Mac, e.g. for a firewall rule. The IP address rather than
    /// the ".local" name: those names don't cross from one network segment to another.
    var address: String? {
        guard let host = Self.primaryIPv4 ?? (SCDynamicStoreCopyLocalHostName(nil) as String?).map({ $0 + ".local" })
        else { return nil }
        return "\(host):\(Self.port)"
    }

    private static var primaryIPv4: String? {
        guard let store = SCDynamicStoreCreate(nil, "PlayPrio" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String,
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString)
                as? [String: Any] else { return nil }
        return (ipv4["Addresses"] as? [String])?.first
    }

    private var key: String {
        if let existing = UserDefaults.standard.string(forKey: Keys.key), existing.count >= 32 { return existing }
        let fresh = Self.makeKey()
        UserDefaults.standard.set(fresh, forKey: Keys.key)
        return fresh
    }

    private static func makeKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Server

    private func startServer() {
        guard server == nil else { return }
        _ = key // made now, so it's there for scripts/companion-request.sh too
        let server = CompanionServer { [weak self] request, respond in
            guard let self else { return respond(.error(503, "off")) }
            self.handle(request, respond: respond)
        }
        server.onStateChange = { [weak self] problem in self?.problem = problem }
        server.start(port: Self.port)
        self.server = server
        storeChanged()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        problem = nil
        lastSeen = nil
        waiters.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func handle(_ request: CompanionServer.Request, respond: @escaping (CompanionServer.Response) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            respond(CompanionServer.Response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Self.page))
        case ("GET", "/apple-touch-icon.png"), ("GET", "/favicon.ico"):
            guard let icon = Self.webIcon else { return respond(.error(404, "no icon")) }
            respond(.file(icon, type: "image/png", request: request, cache: "max-age=86400"))
        case ("GET", CompanionPage.silencePath), ("HEAD", CompanionPage.silencePath):
            respond(CompanionPage.silence(for: request))
        case ("GET", CompanionPage.noCoverPath):
            respond(.file(Self.noCover, type: "image/png", request: request, cache: "max-age=86400"))
        case ("GET", let path) where path.hasPrefix("/artwork/"):
            guard let jpeg = artworkFiles[String(path.dropFirst("/artwork/".count))] else {
                return respond(.error(404, "no such artwork"))
            }
            respond(.file(jpeg, type: "image/jpeg", request: request, cache: "max-age=86400, immutable"))
        case ("GET", "/api/hello"):
            // Unsigned: the page needs the Mac's clock to sign its first request.
            respond(.json(["time": Date().timeIntervalSince1970]))
        case ("GET", "/api/state"):
            guard isSigned(request) else { return refuse(request, respond) }
            handleState(request, respond: respond)
        case ("POST", "/api/command"):
            guard isSigned(request) else { return refuse(request, respond) }
            respond(handleCommand(request))
        case ("GET", "/api/library"):
            guard isSigned(request) else { return refuse(request, respond) }
            handleLibrary(respond: respond)
        case ("GET", "/api/search"):
            guard isSigned(request) else { return refuse(request, respond) }
            guard let query = request.query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...100).contains(query.count), let store else { return respond(.error(400, "bad query")) }
            CompanionLibrary.send(CompanionLibrary.search(query), with: store) { results in
                respond(results.map { .json($0) } ?? .error(502, "search failed"))
            }
        case ("GET", "/api/artist"):
            guard isSigned(request) else { return refuse(request, respond) }
            guard let id = request.query["id"], let store else { return respond(.error(400, "bad artist")) }
            artists.get(id, load: { CompanionLibrary.send(CompanionLibrary.artist(id: id), with: store, done: $0) }) { artist in
                respond(artist.map { .json($0) } ?? .error(404, "no artist"))
            }
        case ("GET", "/api/album"):
            guard isSigned(request) else { return refuse(request, respond) }
            guard let id = request.query["id"], CompanionLibrary.isValid(id) else {
                return respond(.error(400, "bad album"))
            }
            loadAlbum(id) { album in respond(album.map { .json($0) } ?? .error(404, "no album")) }
        default:
            respond(.error(404, "not found"))
        }
    }

    private func refuse(_ request: CompanionServer.Request, _ respond: (CompanionServer.Response) -> Void) {
        Self.log.error("refused \(request.method, privacy: .public) \(request.target, privacy: .public): bad or missing signature")
        respond(.error(401, "not paired"))
    }

    private static let page = Data(CompanionPage.html.replacingOccurrences(of: "__PAGE_VERSION__", with: pageVersion).utf8)

    /// The page's icon on the iPhone's Home Screen and in Safari's tabs.
    private static let webIcon = Bundle.main.url(forResource: "WebIcon", withExtension: "png").flatMap { try? Data(contentsOf: $0) }

    /// iOS's cover for a song without one (it would show the page's icon): a note on grey,
    /// like the page's own empty cover.
    private static let noCover: Data = {
        let side: CGFloat = 600
        let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let grey = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.06, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(grey, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.6)])) {
            let size = NSSize(width: side * 0.24, height: side * 0.24 * note.size.height / note.size.width)
            note.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }()

    private static var computerName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    }

    /// Answers at once if the iPhone's copy is out of date, else when something changes
    /// (a long poll, so a new track shows up right away).
    private func handleState(_ request: CompanionServer.Request, respond: @escaping (CompanionServer.Response) -> Void) {
        noteListener()
        guard request.query["since"].flatMap(Int.init) == revision else { return respond(.json(currentState())) }
        let id = UUID()
        waiters[id] = respond
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPollTimeout) { [weak self] in
            guard let self, let respond = self.waiters.removeValue(forKey: id) else { return }
            respond(.json(self.currentState()))
        }
    }

    private struct Command: Decodable {
        let action: String
        /// A row's id, to act on that source instead of routing like the media keys; for
        /// "playItem", a shelf item's id.
        let id: String?
        /// For "playTrack": a song, its album or playlist, or both; `params` shuffles a playlist.
        let videoId: String?
        let playlistId: String?
        let params: String?
        /// For "volume": 0…1.
        let value: Double?
        /// For "seek": seconds into the song.
        let position: Double?
    }

    private func handleCommand(_ request: CompanionServer.Request) -> CompanionServer.Response {
        guard let store, let command = try? JSONDecoder().decode(Command.self, from: request.body) else {
            return .error(400, "bad command")
        }
        let accepted = CompanionServer.Response.json(["ok": true], status: 202)
        switch command.action {
        case "playItem":
            // Something from YouTube Music's shelves (see /api/library); an album or playlist
            // plays through its page, which is usually read already.
            guard let id = command.id, CompanionLibrary.isValid(id) else { return .error(400, "bad item") }
            let play = { (playlistID: String?) in
                store.runScript({ CompanionLibrary.play(id: id, playlistID: playlistID) }) { [weak self] played in
                    Self.log.notice("play \(id, privacy: .public): \(played ? "sent" : "failed", privacy: .public)")
                    self?.refreshSoon()
                }
            }
            if id.hasPrefix("browse/") { loadAlbum(id) { play($0?.playlistId) } } else { play(nil) }
        case "playTrack":
            // A song from an album or playlist the iPhone opened (see /api/album).
            let videoID = command.videoId, playlistID = command.playlistId, params = command.params
            store.runScript({ CompanionLibrary.play(videoID: videoID, playlistID: playlistID, params: params) }) { [weak self] played in
                Self.log.notice("play track \(videoID ?? "-", privacy: .public) in \(playlistID ?? "-", privacy: .public): \(played ? "sent" : "failed", privacy: .public)")
                self?.refreshSoon()
            }
        case "repeat", "shuffle":
            let button = command.action
            store.runScript({ CompanionLibrary.press(button) }) { [weak self] _ in self?.refreshPlayerInfo() }
        case "volume":
            guard let value = command.value, value.isFinite, SystemVolume.set(Float(value)) else { return .error(400, "can't set the volume") }
            storeChanged()
        case "seek":
            guard nowID == "ytmusic", let position = command.position, position.isFinite, position >= 0 else {
                return .error(400, "can't seek")
            }
            store.runScript({ CompanionLibrary.seek(to: position) }) { [weak self] _ in self?.refreshSoon() }
        case "playPause", "play", "pause", "next", "previous":
            if let id = command.id {
                // One row's own buttons (scripts/companion-request.sh), not routed.
                guard let row = store.rows.first(where: { $0.id == id }) else { return .error(404, "no such source") }
                switch command.action {
                case "next", "previous": store.skip(row, forward: command.action == "next")
                case "play" where row.state == .playing, "pause" where row.state != .playing: break
                default: store.togglePlayback(row)
                }
            } else {
                // Play and Pause come from iOS's own buttons, which can be a step behind; only
                // act when they'd change something. Otherwise exactly like the media keys.
                let playing = entries.first { $0.item.id == nowID }?.item.state == PlaybackState.playing.rawValue
                switch command.action {
                case "next": store.handleKey(.next, pressedAt: Date())
                case "previous": store.handleKey(.previous, pressedAt: Date())
                case "play" where playing, "pause" where !playing: break
                default: store.handleKey(.playPause, pressedAt: Date())
                }
            }
            refreshSoon()
        default:
            return .error(400, "unknown action")
        }
        return accepted
    }

    /// Actions run on the scripting queue; look again once they've had time to land.
    private func refreshSoon() {
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.store?.refresh() }
        }
    }

    /// An album's or playlist's page (see `PageCache`). One without songs counts as not read.
    private func loadAlbum(_ id: String, done: @escaping (CompanionLibrary.Album?) -> Void) {
        guard let store else { return done(nil) }
        albums.get(id, load: { loaded in
            let started = Date()
            CompanionLibrary.send(CompanionLibrary.album(id: id), with: store) { album in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Self.log.notice("album \(id, privacy: .public): \(album.map { "\($0.tracks.count) tracks" } ?? "failed", privacy: .public) in \(ms) ms")
                loaded(album?.tracks.isEmpty == false ? album : nil)
            }
        }, done: done)
    }

    /// The albums on the home shelves are what gets tapped most: read them ahead, one after
    /// another, so they open at once.
    private func prefetchAlbums(in shelves: [CompanionLibrary.Shelf]) {
        let ids = shelves.flatMap(\.items).map(\.id).filter { $0.hasPrefix("browse/") }.prefix(12)
        func next(_ rest: ArraySlice<String>) {
            guard let id = rest.first else { return }
            loadAlbum(id) { _ in next(rest.dropFirst()) }
        }
        next(ArraySlice(ids))
    }

    /// YouTube Music's shelves, read at most every three minutes. If that fails,
    /// the last ones read are served.
    private func handleLibrary(respond: @escaping (CompanionServer.Response) -> Void) {
        if let readAt = libraryReadAt, Date().timeIntervalSince(readAt) < 180 {
            return respond(.json(library))
        }
        libraryWaiters.append(respond)
        guard libraryWaiters.count == 1, let store else { return }
        CompanionLibrary.send(CompanionLibrary.home, with: store) { [weak self] home in
            guard let self else { return }
            if let home, !home.shelves.isEmpty {
                self.library = home
                self.prefetchAlbums(in: home.shelves)
                self.libraryReadAt = Date()
            }
            let answer = CompanionServer.Response.json(self.library)
            self.libraryWaiters.forEach { $0(answer) }
            self.libraryWaiters.removeAll()
        }
    }

    /// Valid HMAC with the pairing key, recent, and not seen before.
    private func isSigned(_ request: CompanionServer.Request) -> Bool {
        let now = Date()
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < 2 * Self.maxClockSkew }
        guard let time = request.headers["x-playprio-time"], let seconds = TimeInterval(time),
              abs(now.timeIntervalSince1970 - seconds) < Self.maxClockSkew,
              let nonce = request.headers["x-playprio-nonce"], (16...64).contains(nonce.count), seenNonces[nonce] == nil,
              let signature = request.headers["x-playprio-signature"].flatMap(Self.bytes(hex:)) else { return false }
        let message = Data("\(request.method)\n\(request.target)\n\(time)\n\(nonce)\n".utf8) + request.body
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: message,
                                                     using: SymmetricKey(data: Data(key.utf8))) else { return false }
        seenNonces[nonce] = now
        return true
    }

    private static func bytes(hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: Keeping the state fresh

    /// The panel only checks the sources while it's open; while an iPhone listens, do it here.
    private func noteListener() {
        lastPoll = Date()
        if lastSeen.map({ Date().timeIntervalSince($0) > 5 }) ?? true { lastSeen = lastPoll }
        guard refreshTimer == nil else { return }
        store?.refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] timer in
            guard let self, Date().timeIntervalSince(self.lastPoll) < Self.listenerGone else {
                timer.invalidate()
                self?.refreshTimer = nil
                return
            }
            self.store?.refresh()
            self.refreshPlayerInfo()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: State

    /// What the page shows of one row. Positions are sent as of the moment of sending.
    private struct Item: Encodable, Equatable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let app: String
        let state: String
        /// Whether `title` is a track's; otherwise it's the app's name.
        let hasTrack: Bool
        var position: Double?
        let duration: Double?
        let artwork: String?
        let canControl: Bool
        let canSkip: Bool
        /// Only YouTube Music can be told where to jump to.
        let canSeek: Bool
        let getsKey: Bool
    }

    private struct Entry {
        var item: Item
        let readAt: Date
    }

    private struct State: Encodable {
        let rev: Int
        /// The track iOS shows; the one Play/Pause is about.
        let now: Item?
        let rows: [Item]
        let mac: String
        /// The page this Mac serves now (see `pageVersion`).
        let page: String
        /// The Mac's output volume (0…1), nil when the output has none of its own.
        let volume: Float?
        let muted: Bool
        /// YouTube Music's repeat mode and the playing song's artist and album (when it plays there).
        let player: CompanionLibrary.PlayerInfo?
    }

    private func storeChanged() {
        guard server != nil, let store else { return }
        let fresh = store.rows.map { row in
            Entry(item: Item(id: row.id, title: row.title, artist: row.subtitle, album: Self.album(of: row),
                             app: row.appName, state: row.state.rawValue, hasTrack: row.hasTrack, position: row.position,
                             duration: row.duration, artwork: artworkPath(row.artworkURL, images: store.artwork),
                             canControl: row.canControl, canSkip: row.canSkip,
                             canSeek: row.id == "ytmusic" && row.duration != nil, getsKey: row.getsKey),
                  readAt: row.readAt)
        }
        let freshNowID = Self.pickNow(fresh.map(\.item))
        // The volume is read with the sources, so keys pressed on the Mac show up too.
        let freshVolume = SystemVolume.level, freshMuted = SystemVolume.isMuted
        let volumeChanged = freshMuted != muted || (freshVolume == nil) != (volume == nil)
            || abs((freshVolume ?? 0) - (volume ?? 0)) > 0.005
        volume = freshVolume
        muted = freshMuted
        let changed = volumeChanged || freshNowID != nowID || Self.differ(entries, fresh)
        entries = fresh
        nowID = freshNowID
        guard changed else { return }
        publish()
    }

    /// YouTube Music's player bar, read along with the sources while an iPhone listens.
    private func refreshPlayerInfo() {
        guard nowID == "ytmusic", let store else {
            if player != nil { player = nil; publish() }
            return
        }
        store.runScript({ CompanionLibrary.playerInfo() }) { [weak self] info in
            guard let self, info != self.player else { return }
            self.player = info
            self.publish()
        }
    }

    /// A new revision, and an answer to every iPhone waiting for one.
    private func publish() {
        revision += 1
        let answers = waiters.values
        waiters.removeAll()
        let state = CompanionServer.Response.json(currentState())
        answers.forEach { $0(state) }
    }

    /// A track plays: the key's source if it's among them, else the first that plays.
    /// Otherwise the key's source, paused or closed, like the panel's large card. An app
    /// making sound without a track (a game, a video call) never takes its place.
    private static func pickNow(_ items: [Item]) -> String? {
        let controllable = items.filter(\.canControl)
        let playing = controllable.filter { $0.state == PlaybackState.playing.rawValue && $0.hasTrack }
        return (playing.first(where: \.getsKey) ?? playing.first ?? controllable.first(where: \.getsKey)
            ?? controllable.first)?.id
    }

    /// Whether the iPhone needs to hear about it: anything but the clock moving on.
    private static func differ(_ old: [Entry], _ new: [Entry]) -> Bool {
        guard old.count == new.count else { return true }
        for (before, after) in zip(old, new) {
            var a = before.item, b = after.item
            a.position = nil
            b.position = nil
            guard a == b else { return true }
            // A seek, or a track that started over: the position isn't where time put it.
            if let earlier = before.item.position, let later = after.item.position {
                let elapsed = b.state == PlaybackState.playing.rawValue ? after.readAt.timeIntervalSince(before.readAt) : 0
                if abs(later - (earlier + elapsed)) > 3 { return true }
            } else if (before.item.position == nil) != (after.item.position == nil) {
                return true
            }
        }
        return false
    }

    private func currentState() -> State {
        let now = Date()
        let items = entries.map { entry -> Item in
            var item = entry.item
            if item.state == PlaybackState.playing.rawValue, let position = item.position {
                let advanced = position + now.timeIntervalSince(entry.readAt)
                item.position = item.duration.map { min(advanced, $0) } ?? advanced
            }
            return item
        }
        return State(rev: revision, now: items.first { $0.id == nowID }, rows: items, mac: Self.computerName,
                     page: Self.pageVersion, volume: volume, muted: muted, player: player)
    }

    /// The row only has "Artist – Album" in one string.
    private static func album(of row: Store.Row) -> String {
        let prefix = row.subtitle + " – "
        return row.longSubtitle.hasPrefix(prefix) ? String(row.longSubtitle.dropFirst(prefix.count)) : ""
    }

    // MARK: Artwork

    /// Covers are served from here, square and at most 600 px: the iPhone shows them square,
    /// and YouTube's video thumbnails aren't.
    private func artworkPath(_ url: URL?, images: [URL: NSImage]) -> String? {
        guard let url else { return nil }
        if let name = artworkNames[url] { return "/artwork/" + name }
        guard let image = images[url], let jpeg = Self.squareJPEG(image) else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined() + ".jpg"
        artworkNames[url] = name
        artworkFiles[name] = jpeg
        artworkOrder.append(url)
        if artworkOrder.count > 16, let oldest = artworkOrder.first {
            artworkOrder.removeFirst()
            artworkNames.removeValue(forKey: oldest).map { artworkFiles[$0] = nil }
        }
        return "/artwork/" + name
    }

    private static func squareJPEG(_ image: NSImage, maxSide: Int = 600) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let edge = min(source.width, source.height)
        guard edge > 0, let square = source.cropping(to: CGRect(x: (source.width - edge) / 2, y: (source.height - edge) / 2,
                                                                 width: edge, height: edge)) else { return nil }
        let side = min(maxSide, edge)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

/// Pages read from YouTube Music (albums, artists): kept ten minutes, at most `limit` of them,
/// and each asked for only once at a time. Main thread only.
private final class PageCache<Page> {
    private let limit: Int
    private var pages: [String: (page: Page, readAt: Date)] = [:]
    private var waiters: [String: [(Page?) -> Void]] = [:]

    init(limit: Int) {
        self.limit = limit
    }

    /// `load` reads the page and hands it over (nil if it couldn't).
    func get(_ id: String, load: (@escaping (Page?) -> Void) -> Void, done: @escaping (Page?) -> Void) {
        if let cached = pages[id], Date().timeIntervalSince(cached.readAt) < 600 { return done(cached.page) }
        waiters[id, default: []].append(done)
        guard waiters[id]?.count == 1 else { return }
        load { [self] page in
            if let page {
                pages[id] = (page, Date())
                if pages.count > limit, let oldest = pages.min(by: { $0.value.readAt < $1.value.readAt })?.key {
                    pages[oldest] = nil
                }
            }
            waiters.removeValue(forKey: id)?.forEach { $0(page) }
        }
    }
}
