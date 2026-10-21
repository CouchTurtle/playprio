import AppKit

enum PlaybackState: String {
    case playing, paused
    /// Open, but nothing loaded to play (e.g. YouTube Music right after launch),
    /// or an app PlayPrio can't control right now.
    case idle
    case absent

    /// Lower ranks win when picking which tab or app a target stands for.
    var rank: Int {
        switch self {
        case .playing: 0
        case .paused: 1
        case .idle: 2
        case .absent: 3
        }
    }
}

struct SourceStatus {
    var state: PlaybackState
    var title = ""
    var artist = ""
    var album = ""
    var artworkURL: URL?
    /// Playback position and length in seconds, when the source reports them.
    var position: Double?
    var duration: Double?
    /// When `position` was read, so the panel can advance it while playing.
    var readAt = Date()

    /// Parses the JSON the Chrome status scripts return.
    init(json: String) {
        struct Payload: Decodable {
            let state: String
            let title: String?
            let artist: String?
            let album: String?
            let artwork: String?
            let pos: Double?
            let dur: Double?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        state = payload?.state == "playing" ? .playing : payload?.state == "paused" ? .paused : .idle
        title = payload?.title ?? ""
        artist = payload?.artist ?? ""
        album = payload?.album ?? ""
        artworkURL = payload?.artwork.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        position = payload?.pos
        duration = payload?.dur.flatMap { $0 > 0 ? $0 : nil }
    }

    init(state: PlaybackState, title: String = "", artist: String = "", album: String = "",
         artworkURL: URL? = nil, position: Double? = nil, duration: Double? = nil) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.position = position
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// A place music can come from. Scripting methods run on PlayPrio's scripting queue.
protocol MediaTarget: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// The app that owns the audio, so it can be left out of "other apps".
    var ownerBundleID: String { get }
    /// Read on the main thread only.
    var appIcon: NSImage { get }
    var canLaunch: Bool { get }
    var canSkip: Bool { get }
    /// Whether Play may resume this source on its own (music players). Video players and
    /// menu-controlled apps are only resumed when PlayPrio paused them last.
    var autoResume: Bool { get }
    /// Everything except the built-in web sources can be removed from the list.
    var isRemovable: Bool { get }
    func status() throws -> SourceStatus
    func play() throws
    /// Pauses everything this target covers that is playing (every matching tab).
    func pause() throws
    /// True when `pause()` presses a "Play/Pause" toggle, which would resume a source that
    /// is already paused (by macOS, say).
    var pauseIsToggle: Bool { get }
    func next() throws
    func previous() throws
    /// Opens the source when it isn't running. Returns false if this target can't.
    func launch() -> Bool
    /// Brings the tab or app to the front.
    func focus() throws
}

extension MediaTarget {
    var pauseIsToggle: Bool { false }
}

// MARK: - Websites in Chrome

/// A website in Chrome, controlled by running JavaScript in its tab.
final class ChromeTabTarget: MediaTarget {
    struct Scripts {
        /// Must return the JSON `SourceStatus(json:)` reads.
        let status: String
        let play: String
        let pause: String
        let next: String
        let previous: String
    }

    let id: String
    let displayName: String
    let ownerBundleID = Chromium.chrome.bundleID
    let canLaunch: Bool
    let canSkip = true
    let autoResume = true
    let isRemovable = false
    let urlPrefixes: [String]
    /// Host of the installed web app: used for its icon and, if `canLaunch`, to open it.
    private let appHost: String
    private let js: Scripts
    /// The tab the last `status()` picked: the playing one, else a paused one, else any.
    private var currentTabID: String?

    lazy var appIcon: NSImage = {
        let app = ChromeApps.app(forHost: appHost)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Chromium.chrome.bundleID)
        return AppInfo.icon(at: app)
    }()

    init(id: String, displayName: String, urlPrefixes: [String], appHost: String, canLaunch: Bool, js: Scripts) {
        self.id = id
        self.displayName = displayName
        self.urlPrefixes = urlPrefixes
        self.appHost = appHost
        self.canLaunch = canLaunch
        self.js = js
    }

    func status() throws -> SourceStatus {
        currentTabID = nil
        guard Chromium.chrome.isRunning else { return SourceStatus(state: .absent) }
        let tabs = try Chromium.chrome.runJS(js.status, inTabsMatching: urlPrefixes).map { tab in
            (id: tab.tabID, status: SourceStatus(json: tab.value))
        }
        guard let best = tabs.min(by: { $0.status.state.rank < $1.status.state.rank }) else {
            return SourceStatus(state: .absent)
        }
        currentTabID = best.id
        return best.status
    }

    func play() throws { try runInCurrentTab(js.play) }
    func pause() throws {
        guard Chromium.chrome.isRunning else { return }
        _ = try Chromium.chrome.runJS(js.pause, inTabsMatching: urlPrefixes)
    }
    func next() throws { try runInCurrentTab(js.next) }
    func previous() throws { try runInCurrentTab(js.previous) }

    func launch() -> Bool {
        canLaunch && ChromeApps.open(host: appHost, fallback: "https://\(appHost)/")
    }

    func focus() throws {
        if currentTabID == nil { _ = try status() }
        guard let tab = currentTabID else { return }
        try Chromium.chrome.focusTab(id: tab)
    }

    private func runInCurrentTab(_ script: String) throws {
        if currentTabID == nil { _ = try status() }
        guard let tab = currentTabID else { return }
        _ = try Chromium.chrome.runJS(script, inTabsMatching: urlPrefixes, tabIDs: [tab])
    }
}

/// Any tab with a playing (or started) <video>/<audio> element in a Chromium browser, like
/// a local audio file or a site PlayPrio doesn't know. Found by `OtherAudio`; not in the list.
/// Muted media (autoplaying previews) doesn't count.
final class BrowserMediaTarget: MediaTarget {
    static let statusJS = """
    (() => { const all = [...document.querySelectorAll('video, audio')].filter(x => !x.muted && x.volume > 0); const v = all.find(x => !x.paused) || all.find(x => x.currentTime > 0); if (!v) return ''; const m = navigator.mediaSession && navigator.mediaSession.metadata; const file = decodeURIComponent(location.pathname.split('/').pop() || ''); return JSON.stringify({ state: v.paused ? 'paused' : 'playing', title: (m && m.title) || document.title || file, artist: (m && m.artist) || location.hostname, artwork: m && m.artwork && m.artwork.length ? m.artwork[m.artwork.length - 1].src : '', pos: v.currentTime, dur: isFinite(v.duration) ? v.duration : 0 }); })()
    """
    private static let playJS = """
    (() => { const all = [...document.querySelectorAll('video, audio')]; const v = all.find(x => x.currentTime > 0) || all[0]; if (v && v.paused) v.play(); return 'ok'; })()
    """
    private static let pauseJS = """
    (() => { document.querySelectorAll('video, audio').forEach(x => { if (!x.paused) x.pause(); }); return 'ok'; })()
    """

    let browser: Chromium
    let tabID: String
    var id: String { Self.id(browser: browser, tabID: tabID) }
    var displayName: String { browser.name }
    var ownerBundleID: String { browser.bundleID }
    let canLaunch = false
    let canSkip = false
    let autoResume = false
    let isRemovable = false

    lazy var appIcon: NSImage = AppInfo.icon(of: browser.bundleID)

    init(browser: Chromium, tabID: String) {
        self.browser = browser
        self.tabID = tabID
    }

    static func id(browser: Chromium, tabID: String) -> String { "tab:\(browser.bundleID):\(tabID)" }

    func status() throws -> SourceStatus {
        guard browser.isRunning,
              let json = try browser.runJS(Self.statusJS, tabIDs: [tabID]).first?.value
        else { return SourceStatus(state: .absent) }
        return SourceStatus(json: json)
    }

    func play() throws { _ = try browser.runJS(Self.playJS, tabIDs: [tabID]) }
    func pause() throws { _ = try browser.runJS(Self.pauseJS, tabIDs: [tabID]) }
    func next() throws {}
    func previous() throws {}
    func launch() -> Bool { false }
    func focus() throws { try browser.focusTab(id: tabID) }
}

// MARK: - Apps

/// Shared plumbing for app sources: name, icon, running check, launching.
class AppTarget {
    let id: String
    let ownerBundleID: String
    let displayName: String
    let canLaunch = true
    let isRemovable = true

    init(bundleID: String) {
        id = Targets.appSourceID(bundleID)
        ownerBundleID = bundleID
        displayName = AppInfo.name(of: bundleID)
    }

    lazy var appIcon: NSImage = AppInfo.icon(of: ownerBundleID)

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ownerBundleID).first
    }

    func launch() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ownerBundleID) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    func focus() throws { _ = launch() }
}

/// An app with an AppleScript dictionary (Spotify, Music, QuickTime, …), see `KnownApps`.
final class ScriptableAppTarget: AppTarget, MediaTarget {
    let autoResume: Bool
    private let scripts: KnownApps.Scripts

    var canSkip: Bool { scripts.next != nil }

    init(bundleID: String, entry: KnownApps.Entry) {
        scripts = entry.scripts
        autoResume = entry.autoResume
        super.init(bundleID: bundleID)
    }

    /// Never reaches an app that isn't running: `tell application` would launch it. The
    /// check is inside the script, so an app quitting meanwhile isn't relaunched either.
    private func send(_ body: String) throws -> String? {
        let source = """
        if application id "\(ownerBundleID)" is running then
            tell application id "\(ownerBundleID)"
                \(body)
            end tell
        else
            return "not running"
        end if
        """
        let result = try AppleScript.run(source, app: displayName)
        return result == "not running" ? nil : result
    }

    func status() throws -> SourceStatus {
        guard runningApp != nil, let output = try send(scripts.status) else { return SourceStatus(state: .absent) }
        let lines = output.components(separatedBy: "\n")
        let field = { (index: Int) in lines.indices.contains(index) ? lines[index] : "" }
        let seconds = { (index: Int) in Double(field(index)) } // the scripts round to whole seconds
        let state: PlaybackState = field(0) == "playing" ? .playing : field(0) == "paused" ? .paused : .idle
        return SourceStatus(state: state, title: field(1), artist: field(2), album: field(6),
                            artworkURL: field(3).isEmpty ? nil : URL(string: field(3)),
                            position: seconds(4), duration: seconds(5))
    }

    func play() throws { _ = try send(scripts.play) }
    func pause() throws { _ = try send(scripts.pause) }
    func next() throws { if let next = scripts.next { _ = try send(next) } }
    func previous() throws { if let previous = scripts.previous { _ = try send(previous) } }
}

/// Any other app: playing if Core Audio hears it and it offers "Pause" in its menus;
/// controlled by pressing those menu items.
final class MenuAppTarget: AppTarget, MediaTarget {
    let autoResume = false
    let canSkip = true
    /// Core Audio keeps calling an app audible for a moment after it pauses, and a single
    /// "Play/Pause" item can't tell the state; so right after pausing it counts as paused.
    private var pausedAt: Date?

    private func menu() -> MenuControl? {
        runningApp.map { MenuControl(pid: $0.processIdentifier) }
    }

    func status() throws -> SourceStatus {
        guard let menu = menu() else { return SourceStatus(state: .absent) }
        let justPaused = pausedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        let audible = AudioProcesses.bundleIDsPlayingAudio().contains(ownerBundleID)
        if audible && menu.canPause && !justPaused { return SourceStatus(state: .playing) }
        if menu.canPlay { return SourceStatus(state: .paused) }
        return SourceStatus(state: .idle)
    }

    func play() throws {
        pausedAt = nil
        try press(.play)
    }

    func pause() throws {
        try press(.pause)
        pausedAt = Date()
    }

    var pauseIsToggle: Bool { menu()?.pauseIsToggle ?? false }

    func next() throws { try press(.next) }
    func previous() throws { try press(.previous) }

    private func press(_ command: MenuControl.Command) throws {
        guard menu()?.press(command) == true else {
            throw ScriptError.failed("\(displayName) has no menu item for \(command)")
        }
    }
}

// MARK: - Catalog

enum Targets {
    /// Wraps the code that sets `v` (the media element) and `s` (the state) and adds the
    /// Media Session metadata (title, artist, album, cover) the site publishes for the
    /// system's Now Playing, plus position and length (by default the media element's).
    private static func statusJS(_ stateCode: String, album: String = "m ? m.album : ''",
                                 position: String = "v ? v.currentTime : 0",
                                 duration: String = "v && isFinite(v.duration) ? v.duration : 0") -> String {
        """
        (() => { \(stateCode) const m = navigator.mediaSession && navigator.mediaSession.metadata; const art = m && m.artwork && m.artwork.length ? m.artwork[m.artwork.length - 1].src : ''; return JSON.stringify({ state: s, title: m ? m.title : '', artist: m ? m.artist : '', album: \(album), artwork: art, pos: \(position), dur: \(duration) }); })()
        """
    }

    static let youTubeMusic = ChromeTabTarget(
        id: "ytmusic",
        displayName: "YouTube Music",
        urlPrefixes: ["https://music.youtube.com"],
        appHost: "music.youtube.com",
        canLaunch: true,
        js: .init(
            // YouTube Music leaves the Media Session album empty; its player bar shows
            // "Artist • Album • Year" for songs (videos show views instead, so no year).
            // Albums play gaplessly: the video then holds several songs one after another, so
            // its time and length aren't the song's. The player bar's slider (whole seconds)
            // has the song's; it's used whenever the two disagree.
            status: statusJS("""
            const v = document.querySelector('video'); const s = (!v || (!v.src && v.readyState === 0)) ? 'empty' : (v.paused ? 'paused' : 'playing'); const bar = document.querySelector('ytmusic-player-bar #progress-bar'); const barMax = bar ? Number(bar.getAttribute('aria-valuemax')) || 0 : 0; const gapless = !!v && barMax > 0 && Math.abs(v.duration - barMax) > 2;
            """, album: """
            (m && m.album) || (() => { const b = document.querySelector('ytmusic-player-bar .byline'); const p = b ? b.textContent.split('•').map(x => x.trim()) : []; return p.length === 3 && /^\\d{4}$/.test(p[2]) ? p[1] : ''; })()
            """, position: "gapless ? (Number(bar.getAttribute('value')) || 0) + (v.paused ? 0 : 0.5) : (v ? v.currentTime : 0)",
            duration: "gapless ? barMax : (v && isFinite(v.duration) ? v.duration : 0)"),
            play: """
            (() => { const v = document.querySelector('video'); if (!v || !v.paused) return 'ok'; const b = document.querySelector('ytmusic-player-bar #play-pause-button'); if (b) b.click(); else v.play(); return 'ok'; })()
            """,
            pause: """
            (() => { const v = document.querySelector('video'); if (!v || v.paused) return 'ok'; const b = document.querySelector('ytmusic-player-bar #play-pause-button'); if (b) b.click(); else v.pause(); return 'ok'; })()
            """,
            next: """
            (() => { const b = document.querySelector('ytmusic-player-bar .next-button'); if (b) b.click(); return b ? 'ok' : 'none'; })()
            """,
            previous: """
            (() => { const b = document.querySelector('ytmusic-player-bar .previous-button'); if (b) b.click(); return b ? 'ok' : 'none'; })()
            """
        )
    )

    static let youTube = ChromeTabTarget(
        id: "youtube",
        displayName: "YouTube",
        urlPrefixes: ["https://www.youtube.com", "https://m.youtube.com"],
        appHost: "www.youtube.com",
        canLaunch: false,
        js: .init(
            status: statusJS("""
            const v = document.querySelector('video.html5-main-video') || document.querySelector('video'); const s = !v ? 'empty' : (!v.paused ? 'playing' : (v.currentTime > 0 ? 'paused' : 'empty'));
            """),
            play: """
            (() => { const v = document.querySelector('video.html5-main-video') || document.querySelector('video'); if (v && v.paused) v.play(); return 'ok'; })()
            """,
            pause: """
            (() => { document.querySelectorAll('video').forEach(v => { if (!v.paused) v.pause(); }); return 'ok'; })()
            """,
            next: """
            (() => { const b = document.querySelector('.ytp-next-button'); if (b) b.click(); return b ? 'ok' : 'none'; })()
            """,
            previous: """
            (() => { const b = document.querySelector('.ytp-prev-button'); const v = document.querySelector('video.html5-main-video'); if (b && b.offsetParent) b.click(); else if (v) v.currentTime = 0; return 'ok'; })()
            """
        )
    )

    static let builtIns: [MediaTarget] = [youTubeMusic, youTube]

    static func appSourceID(_ bundleID: String) -> String { "app:" + bundleID }

    private static let lock = NSLock()
    private static var appTargets: [String: MediaTarget] = [:]

    /// One target object per app, created on first use: AppleScript if PlayPrio knows
    /// the app, its menus otherwise.
    static func app(_ bundleID: String) -> MediaTarget {
        lock.lock()
        defer { lock.unlock() }
        if let target = appTargets[bundleID] { return target }
        let target: MediaTarget = KnownApps.entries[bundleID].map { ScriptableAppTarget(bundleID: bundleID, entry: $0) }
            ?? MenuAppTarget(bundleID: bundleID)
        appTargets[bundleID] = target
        return target
    }

    /// Every source in the list, enabled or not, unsorted.
    static var all: [MediaTarget] { builtIns + Settings.addedApps.map(app) }

    /// Resolves any app id ("app:<bundle id>"), also for apps that aren't in the list.
    static func target(id: String) -> MediaTarget? {
        id.hasPrefix("app:") ? app(String(id.dropFirst(4))) : builtIns.first { $0.id == id }
    }

    /// Whether PlayPrio could control this app if it were added.
    static func canControl(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        if KnownApps.entries[bundleID] != nil { return true }
        let menu = MenuControl(pid: app.processIdentifier)
        return menu.canPlay || menu.canPause
    }
}

/// Players PlayPrio can drive through AppleScript. Each script runs inside
/// `tell application id "<bundle id>"`; the status script returns lines: state
/// ("playing"/"paused"/other), title, artist, artwork URL, position, length (seconds), album.
/// Properties passed to `round` need an explicit `get`, or AppleScript tries to round the
/// reference itself and fails.
enum KnownApps {
    struct Scripts {
        let status: String
        let play: String
        let pause: String
        var next: String?
        var previous: String?
    }

    struct Entry {
        let scripts: Scripts
        let autoResume: Bool
    }

    /// Music and TV share a dictionary.
    private static let trackScripts = Scripts(
        status: """
        set s to player state as text
        set t to ""
        set a to ""
        set p to ""
        set d to ""
        set al to ""
        try
            set t to name of current track
            set a to artist of current track
            set al to album of current track
            set p to (round (get player position)) as text
            set d to (round (get duration of current track)) as text
        end try
        return s & linefeed & t & linefeed & a & linefeed & "" & linefeed & p & linefeed & d & linefeed & al
        """,
        play: "play", pause: "pause", next: "next track", previous: "previous track")

    static let entries: [String: Entry] = [
        "com.spotify.client": Entry(scripts: Scripts(
            status: """
            set s to player state as text
            set t to ""
            set a to ""
            set u to ""
            set p to ""
            set d to ""
            set al to ""
            try
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set u to artwork url of current track
                set p to (round (get player position)) as text
                set d to (round ((get duration of current track) / 1000)) as text
            end try
            return s & linefeed & t & linefeed & a & linefeed & u & linefeed & p & linefeed & d & linefeed & al
            """,
            play: "play", pause: "pause", next: "next track", previous: "previous track"), autoResume: true),
        "com.apple.Music": Entry(scripts: trackScripts, autoResume: true),
        "com.apple.TV": Entry(scripts: trackScripts, autoResume: false),
        "org.videolan.vlc": Entry(scripts: Scripts(
            status: """
            set s to "paused"
            if playing then set s to "playing"
            set t to ""
            set p to ""
            set d to ""
            try
                set t to name of current item
                set p to (get current time) as text
                set d to (get duration of current item) as text
            end try
            return s & linefeed & t & linefeed & "" & linefeed & "" & linefeed & p & linefeed & d
            """,
            play: "if not playing then play", pause: "if playing then play",
            next: "next", previous: "previous"), autoResume: false),
        "com.apple.QuickTimePlayerX": Entry(scripts: Scripts(
            status: """
            if (count of documents) is 0 then return "idle"
            set s to "paused"
            if playing of document 1 then set s to "playing"
            set p to ""
            set d to ""
            try
                set p to (round (get current time of document 1)) as text
                set d to (round (get duration of document 1)) as text
            end try
            return s & linefeed & (name of document 1) & linefeed & "" & linefeed & "" & linefeed & p & linefeed & d
            """,
            play: "if (count of documents) > 0 then play document 1",
            pause: "if (count of documents) > 0 then pause document 1"), autoResume: false),
    ]
}

/// Chrome's installed web apps ("Chrome Apps.localized"), e.g. the YouTube Music PWA.
enum ChromeApps {
    static func app(forHost host: String) -> URL? {
        let fm = FileManager.default
        let folders = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized"),
                       URL(fileURLWithPath: "/Applications/Chrome Apps.localized")]
        for folder in folders {
            let apps = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                if let start = info?["CrAppModeShortcutURL"] as? String, URL(string: start)?.host == host {
                    return app
                }
            }
        }
        return nil
    }

    /// Opens the installed web app for `host`, or `fallback` in Chrome when there is none.
    static func open(host: String, fallback: String) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        if let app = app(forHost: host) {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
            return true
        }
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Chromium.chrome.bundleID),
              let url = URL(string: fallback) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: config)
        return true
    }
}

/// Name and icon of an installed app.
enum AppInfo {
    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(of bundleID: String) -> NSImage {
        icon(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
    }

    static func icon(at url: URL?) -> NSImage {
        url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? genericIcon
    }

    static let genericIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()
}
