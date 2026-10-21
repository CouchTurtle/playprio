import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// State behind the panel. Lives on the main thread; all scripting happens on `queue`.
final class Store: ObservableObject {
    /// One line in the Now Playing list: a source from the list, or another app making sound.
    struct Row: Identifiable {
        let id: String
        let title: String
        /// "Artist" for the compact rows.
        let subtitle: String
        /// "Artist – Album" for the large card, like macOS shows it.
        let longSubtitle: String
        let appName: String
        let icon: NSImage
        let artworkURL: URL?
        let state: PlaybackState
        let position: Double?
        let duration: Double?
        let readAt: Date
        let canControl: Bool
        let canSkip: Bool
        /// Play/Pause would go here right now; this row gets the large card.
        let getsKey: Bool
        /// Whether `title` is a track's; otherwise it's the app's name.
        let hasTrack: Bool
        let appURL: URL?
        /// Set for apps outside the list that PlayPrio could control.
        let addableBundleID: String?
        /// Set for apps in the list.
        let removableBundleID: String?
        /// Set for sources PlayPrio can't control itself: Play/Pause goes through macOS.
        let viaSystemPID: pid_t?
    }

    struct TargetSetting: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let enabled: Bool
        let autoResume: Bool
        let removableBundleID: String?
    }

    struct AddableApp: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var keyTargetName: String?
    @Published private(set) var targetSettings: [TargetSetting] = []
    @Published private(set) var addableApps: [AddableApp] = []
    @Published private(set) var artwork: [URL: NSImage] = [:]
    @Published private(set) var lastAction: String?
    @Published private(set) var problem: ScriptError? { didSet { onStatusChange() } }
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var tapRunning = false { didSet { onStatusChange() } }
    @Published var settingsExpanded = false

    @Published var isEnabled = Settings.isEnabled {
        didSet { Settings.isEnabled = isEnabled; onStatusChange() }
    }
    @Published var launchIfAbsent = Settings.launchIfAbsent {
        didSet { Settings.launchIfAbsent = launchIfAbsent }
    }
    @Published var blockAppleMusic = Settings.blockAppleMusic {
        didSet { Settings.blockAppleMusic = blockAppleMusic }
    }
    @Published var pauseOnHeadphonesGone = Settings.pauseOnHeadphonesGone {
        didSet { Settings.pauseOnHeadphonesGone = pauseOnHeadphonesGone }
    }
    @Published var autoAddApps = Settings.autoAddApps {
        didSet { Settings.autoAddApps = autoAddApps; refresh() }
    }

    /// Called when anything the menu-bar icon shows changes.
    var onStatusChange: () -> Void = {}

    private let queue = DispatchQueue(label: "local.PlayPrio.scripting", qos: .userInitiated)
    private let router: Router
    private var liveTimer: Timer?
    private var refreshing = false
    private var loadingArtwork = Set<URL>()
    /// Apps outside the list making sound, found during the last refresh.
    private var audibleAddable: [AddableApp] = []

    init() {
        router = Router(queue: queue)
        reloadTargetSettings()
    }

    // MARK: Playback actions

    func handleKey(_ key: MediaKey, pressedAt: Date) {
        runOnQueue { $0.handle(key, pressedAt: pressedAt) }
    }

    /// The sound moved off headphones: pause, when that option is on.
    func headphonesGone() {
        guard Settings.pauseOnHeadphonesGone else { return }
        runOnQueue { $0.pauseAllPlaying() }
    }

    func togglePlayback(_ row: Row) {
        let id = row.id, pid = row.viaSystemPID, wasPlaying = row.state == .playing
        runOnQueue { router in
            if let pid {
                router.otherAudio.toggleViaSystem(pid: pid, wasPlaying: wasPlaying)
            } else if let target = router.target(id: id) {
                router.toggle(target)
            }
        }
    }

    func skip(_ row: Row, forward: Bool = true) {
        let id = row.id
        runOnQueue { router in
            if let target = router.target(id: id) { router.skip(target, forward: forward) }
        }
    }

    func focus(_ row: Row) {
        let id = row.id, url = row.appURL
        runOnQueue { router in
            if let target = router.target(id: id) {
                router.focus(target)
            } else if let url {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    // MARK: Editing the list

    func setTarget(_ id: String, enabled: Bool) {
        Settings.setTarget(id, enabled: enabled)
        listChanged()
    }

    func moveTarget(_ id: String, by offset: Int) {
        Settings.moveTarget(id, by: offset)
        listChanged()
    }

    func addApp(_ bundleID: String) {
        Settings.addApp(bundleID)
        listChanged()
    }

    func removeApp(_ bundleID: String) {
        Settings.removeApp(bundleID)
        listChanged()
    }

    /// Lets the user pick any app from /Applications.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Add an app to PlayPrio"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addApp(bundleID)
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func listChanged() {
        reloadTargetSettings()
        refresh()
    }

    // MARK: Refreshing

    /// Keeps the panel current while it's open.
    func startLiveUpdates() {
        liveTimer?.invalidate() // reopened during the close animation
        opensAtLogin = SMAppService.mainApp.status == .enabled
        reloadTargetSettings()
        refresh(discovery: .now)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func stopLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func refresh(discovery: OtherAudio.Discovery = .throttled) {
        guard !refreshing else { return }
        refreshing = true
        queue.async { [router] in
            let snapshot = router.takeSnapshot()
            let keyID = router.keyTargetID(snapshot)
            let problem = router.problem
            let extras = router.otherAudio.scan(discovery: discovery)
            DispatchQueue.main.async {
                self.refreshing = false
                self.problem = problem
                self.apply(snapshot, keyID: keyID, extras: extras)
            }
        }
    }

    private func apply(_ snapshot: Router.Snapshot, keyID: String?, extras: [OtherAudio.Item]) {
        var rows = snapshot.filter { $0.status.state != .absent }.map { entry in
            makeRow(id: entry.target.id, name: entry.target.displayName, icon: entry.target.appIcon,
                    status: entry.status, canControl: true, canSkip: entry.target.canSkip,
                    getsKey: entry.target.id == keyID, appURL: nil, addable: nil,
                    removable: entry.target.isRemovable ? entry.target.ownerBundleID : nil)
        }
        rows += extras.map { extra in
            makeRow(id: extra.id, name: extra.app.localizedName ?? extra.app.bundleIdentifier ?? "App",
                    icon: extra.app.icon ?? AppInfo.genericIcon,
                    status: extra.status, canControl: extra.target != nil || extra.viaSystem,
                    canSkip: extra.target?.canSkip ?? false, getsKey: false, appURL: extra.app.bundleURL,
                    addable: extra.target is AppTarget ? extra.app.bundleIdentifier : nil, removable: nil,
                    viaSystemPID: extra.viaSystem ? extra.pid : nil)
        }
        // The key's target isn't open: show it as "Not Playing" on top, like macOS does.
        if let keyID, !rows.contains(where: { $0.id == keyID }), let target = Targets.target(id: keyID) {
            rows.insert(makeRow(id: target.id, name: target.displayName, icon: target.appIcon,
                                status: SourceStatus(state: .absent), canControl: true, canSkip: false,
                                getsKey: true, appURL: nil, addable: nil, removable: nil), at: 0)
        }
        self.rows = rows
        // What Play/Pause would do now: pause what plays (in the list, else other sound it
        // pauses), otherwise resume or open the list's choice.
        let keyName = keyID.flatMap { Targets.target(id: $0)?.displayName }
        let otherPlaying = extras.first { $0.status.state == .playing && $0.keyPausesIt }
            .map { $0.status.title.isEmpty ? $0.app.localizedName ?? "" : $0.status.title }
        keyTargetName = snapshot.contains { $0.status.state == .playing } ? keyName : otherPlaying ?? keyName

        audibleAddable = extras.compactMap { extra in
            guard extra.target is AppTarget, extra.status.state == .playing,
                  let bundleID = extra.app.bundleIdentifier else { return nil }
            return AddableApp(bundleID: bundleID, name: extra.app.localizedName ?? bundleID,
                              icon: extra.app.icon ?? AppInfo.genericIcon)
        }
        if autoAddApps {
            let ignored = Settings.ignoredApps
            let newcomers = audibleAddable.filter { !ignored.contains($0.bundleID) }
            newcomers.forEach { Settings.addApp($0.bundleID) }
            if !newcomers.isEmpty { listChanged() }
        }
        reloadAddableApps()

        let wanted = Set((snapshot.map(\.status) + extras.map(\.status)).compactMap(\.artworkURL))
        if artwork.count > 30 { artwork = artwork.filter { wanted.contains($0.key) } }
        wanted.forEach(loadArtwork)
    }

    private func makeRow(id: String, name: String, icon: NSImage, status: SourceStatus, canControl: Bool,
                         canSkip: Bool, getsKey: Bool, appURL: URL?, addable: String?, removable: String?,
                         viaSystemPID: pid_t? = nil) -> Row {
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = clean(status.title), artist = clean(status.artist), album = clean(status.album)
        let hasTrack = !title.isEmpty && (status.state == .playing || status.state == .paused)
        let subtitle: String
        let longSubtitle: String
        if hasTrack {
            subtitle = artist.isEmpty ? name : artist
            longSubtitle = [artist, album].filter { !$0.isEmpty }.joined(separator: " – ").nonEmpty ?? name
        } else {
            subtitle = status.state == .idle || status.state == .absent ? "Not Playing" : ""
            longSubtitle = subtitle
        }
        return Row(id: id, title: hasTrack ? title : name, subtitle: subtitle, longSubtitle: longSubtitle,
                   appName: name, icon: icon, artworkURL: hasTrack ? status.artworkURL : nil, state: status.state,
                   position: hasTrack ? status.position : nil, duration: hasTrack ? status.duration : nil,
                   readAt: status.readAt, canControl: canControl, canSkip: canSkip && status.state != .absent,
                   getsKey: getsKey, hasTrack: hasTrack, appURL: appURL, addableBundleID: addable,
                   removableBundleID: removable, viaSystemPID: viaSystemPID)
    }

    /// Covers come from page metadata, so only https, nothing local or plain http.
    private func loadArtwork(_ url: URL) {
        guard url.scheme == "https", artwork[url] == nil, loadingArtwork.insert(url).inserted else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                self.loadingArtwork.remove(url)
                if let image { self.artwork[url] = image }
            }
        }.resume()
    }

    // MARK: Helpers

    private func reloadTargetSettings() {
        targetSettings = Settings.orderedTargets.map { target in
            TargetSetting(id: target.id, name: target.displayName, icon: target.appIcon,
                          enabled: Settings.isTargetEnabled(target.id), autoResume: target.autoResume,
                          removableBundleID: target.isRemovable ? target.ownerBundleID : nil)
        }
        reloadAddableApps()
    }

    /// Known players that are installed; looked up once.
    private lazy var installedKnownApps: [AddableApp] = KnownApps.entries.keys.sorted().compactMap { bundleID in
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return nil }
        return AddableApp(bundleID: bundleID, name: AppInfo.name(of: bundleID), icon: AppInfo.icon(of: bundleID))
    }

    /// Apps for the "Add" menu: whatever is playing right now, then installed known players.
    private func reloadAddableApps() {
        let added = Set(Settings.addedApps)
        var seen = Set<String>()
        addableApps = (audibleAddable + installedKnownApps)
            .filter { !added.contains($0.bundleID) && seen.insert($0.bundleID).inserted }
    }

    /// Runs other scripting (the iPhone remote's) on the scripting queue, never alongside
    /// the router's; `done` gets the result on the main thread.
    func runScript<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        queue.async {
            let result = work()
            DispatchQueue.main.async { done(result) }
        }
    }

    /// `runScript` again and again, `interval` apart, until `work` has an answer or `timeout`
    /// passes. The queue is free in between, so a media key pressed meanwhile isn't held up.
    func pollScript<T>(every interval: TimeInterval, for timeout: TimeInterval,
                       _ work: @escaping () -> T?, then done: @escaping (T?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            if let result = work() { return DispatchQueue.main.async { done(result) } }
            guard Date() < deadline else { return DispatchQueue.main.async { done(nil) } }
            queue.asyncAfter(deadline: .now() + interval, execute: attempt)
        }
        queue.async(execute: attempt)
    }

    /// Runs router work on the scripting queue, then publishes its outcome and, while the
    /// panel is open, refreshes so the new state shows right away.
    private func runOnQueue(_ work: @escaping (Router) -> Void) {
        queue.async { [router] in
            work(router)
            let problem = router.problem
            let lastAction = router.lastAction
            DispatchQueue.main.async {
                self.problem = problem
                self.lastAction = lastAction
                UserDefaults.standard.set(lastAction, forKey: "lastAction") // `defaults read local.PlayPrio lastAction`
                if self.liveTimer != nil { self.refresh() }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
