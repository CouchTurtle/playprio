import AppKit

/// Everything outside the list that makes sound (or has a player loaded), and how PlayPrio
/// can pause it. Only used on the scripting queue.
final class OtherAudio {
    struct Item {
        /// A target id, or "pid:<pid>" for sources reached via macOS.
        let id: String
        /// The app it belongs to, for the icon, the name and for opening it.
        let app: NSRunningApplication
        let target: MediaTarget?
        let status: SourceStatus
        /// No scripting, no menu: its Play/Pause goes to macOS, which hands it to the
        /// system's Now Playing app (usually whatever started playing last).
        let viaSystem: Bool
        /// Whether the media key should pause it. Not for apps that merely keep their audio
        /// output open (games, OBS, music software): the key would never reach the list.
        let keyPausesIt: Bool
        let pid: pid_t
    }

    /// How hard to look for media tabs in browsers (see `Chromium.runJSInLikelyMediaTabs`).
    enum Discovery {
        /// Re-check the tabs known to hold media, and look at active and media-file tabs at
        /// most every few seconds.
        case throttled
        /// Look now.
        case now
    }

    /// Calls and chats make sound too, but they get no Play/Pause at all.
    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "com.skype.skype", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.apple.mobilephone",
    ]
    /// Apps whose sound is media, so the key may be handed to macOS for them.
    private static let mediaApps: Set<String> = Set(Chromium.all.map(\.bundleID)).union([
        "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.apple.finder", "com.apple.mail", "com.apple.Photos", "com.apple.podcasts",
    ])

    private var controllable: [String: (Bool, Date)] = [:]
    /// Sources paused through macOS. Core Audio often keeps calling a paused process
    /// audible, so it counts as paused until its output really stops.
    private var pausedViaSystem: [pid_t: Date] = [:]
    /// Browser tabs seen holding media, so they stay listed (and cheap to check) when paused.
    private var mediaTabs: [Chromium: Set<String>] = [:]
    private var lastDiscovery: [Chromium: Date] = [:]
    /// Browsers that refused scripting (JavaScript from Apple Events off, or no permission):
    /// not asked again for a minute.
    private var scriptingRefused: [Chromium: Date] = [:]
    private var tabTargets: [String: BrowserMediaTarget] = [:]

    func scan(discovery: Discovery) -> [Item] {
        let active = Settings.activeTargets
        let listed = Set(active.map(\.ownerBundleID) + [Bundle.main.bundleIdentifier ?? ""])
        let sources = AudioProcesses.sources()
        let audiblePIDs = Set(sources.map(\.pid))
        pausedViaSystem = pausedViaSystem.filter { audiblePIDs.contains($0.key) && Date().timeIntervalSince($0.value) < 600 }
        var items: [Item] = []
        var handled = Set<String>()

        for browser in Chromium.all {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first else {
                mediaTabs[browser] = nil
                continue
            }
            let excluded = browser == .chrome ? active.compactMap { $0 as? ChromeTabTarget }.flatMap(\.urlPrefixes) : []
            guard let tabs = mediaTabItems(browser, app: app, excluding: excluded, discovery: discovery,
                                           audible: sources.contains { $0.app.bundleIdentifier == browser.bundleID })
            else { continue }
            items += tabs
            handled.insert(browser.bundleID)
        }
        tabTargets = tabTargets.filter { _, target in mediaTabs[target.browser]?.contains(target.tabID) == true }

        for source in sources {
            guard let appID = source.app.bundleIdentifier, !listed.contains(appID), !handled.contains(appID),
                  !items.contains(where: { $0.app.processIdentifier == source.app.processIdentifier }) else { continue }
            if source.bundleID?.hasPrefix("com.apple.quicklook") == true {
                items.append(quickLookItem(source))
            } else if canControl(source.app) {
                let target = Targets.app(appID)
                let status = (try? target.status()) ?? SourceStatus(state: .idle)
                items.append(Item(id: target.id, app: source.app, target: target, status: status,
                                  viaSystem: false, keyPausesIt: true, pid: source.pid))
            } else {
                let isCall = Self.callApps.contains(appID)
                items.append(Item(id: "pid:\(source.pid)", app: source.app, target: nil, status: systemStatus(source.pid),
                                  viaSystem: !isCall, keyPausesIt: !isCall && Self.mediaApps.contains(appID),
                                  pid: source.pid))
            }
        }

        // Known players outside the list with something loaded, like a paused QuickTime video.
        for bundleID in KnownApps.entries.keys.sorted()
        where !listed.contains(bundleID) && !items.contains(where: { $0.app.bundleIdentifier == bundleID }) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let status = try? Targets.app(bundleID).status(),
                  status.state == .playing || status.state == .paused else { continue }
            items.append(Item(id: Targets.appSourceID(bundleID), app: app, target: Targets.app(bundleID),
                              status: status, viaSystem: false, keyPausesIt: true, pid: app.processIdentifier))
        }
        return items
    }

    /// Looks up a media tab found earlier (its id is "tab:<bundle id>:<tab id>").
    func target(id: String) -> MediaTarget? {
        tabTargets[id]
    }

    /// Hands Play/Pause to macOS for a source PlayPrio can't control itself.
    func toggleViaSystem(pid: pid_t, wasPlaying: Bool) {
        MediaKeyTap.passToSystem(.playPause)
        pausedViaSystem[pid] = wasPlaying ? Date() : nil
    }

    // MARK: Browsers

    /// The browser's media tabs, or nil when they can't be listed (scripting refused, or
    /// it's audible but no likely tab holds the sound); then it's handled like any app.
    private func mediaTabItems(_ browser: Chromium, app: NSRunningApplication, excluding excluded: [String],
                               discovery: Discovery, audible: Bool) -> [Item]? {
        if let refused = scriptingRefused[browser], Date().timeIntervalSince(refused) < 60 { return nil }
        let known = mediaTabs[browser] ?? []
        let discover = audible && {
            switch discovery {
            case .now: return true
            case .throttled: return Date().timeIntervalSince(lastDiscovery[browser] ?? .distantPast) > 3
            }
        }()
        guard discover || !known.isEmpty else { return [] }

        let results: [(tabID: String, value: String)]
        do {
            results = try browser.runJSInLikelyMediaTabs(BrowserMediaTarget.statusJS, known: known,
                                                        discover: discover, excluding: excluded)
        } catch {
            scriptingRefused[browser] = Date()
            mediaTabs[browser] = nil
            return nil
        }
        if discover { lastDiscovery[browser] = Date() }
        mediaTabs[browser] = Set(results.map(\.tabID))

        // Sound from a tab PlayPrio didn't look at. Chrome is exempt: its list sources
        // (YouTube Music) explain most of its sound, and they're handled as such.
        if discover && results.isEmpty && browser != .chrome { return nil }

        return results.map { tabID, json in
            let target = tabTarget(browser, tabID)
            return Item(id: target.id, app: app, target: target, status: SourceStatus(json: json),
                        viaSystem: false, keyPausesIt: true, pid: app.processIdentifier)
        }
    }

    private func tabTarget(_ browser: Chromium, _ tabID: String) -> BrowserMediaTarget {
        let id = BrowserMediaTarget.id(browser: browser, tabID: tabID)
        if let existing = tabTargets[id] { return existing }
        let target = BrowserMediaTarget(browser: browser, tabID: tabID)
        tabTargets[id] = target
        return target
    }

    // MARK: Quick Look

    /// Quick Look plays inside a system service, but its panel belongs to the app that
    /// opened it (Finder, Mail), titled with the file name.
    private func quickLookItem(_ source: AudioProcesses.Source) -> Item {
        let file = (AX.windowTitles(pid: source.app.processIdentifier) + AX.windowTitles(pid: source.pid))
            .first { MediaFile.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        var status = systemStatus(source.pid)
        status.title = file ?? "Quick Look"
        status.artist = source.app.localizedName ?? ""
        return Item(id: "pid:\(source.pid)", app: source.app, target: nil, status: status,
                    viaSystem: true, keyPausesIt: true, pid: source.pid)
    }

    // MARK: Helpers

    private func systemStatus(_ pid: pid_t) -> SourceStatus {
        SourceStatus(state: pausedViaSystem[pid] != nil ? .paused : .playing)
    }

    /// Cached for a minute: an app's menus rarely change, and scanning them is slow.
    private func canControl(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        if let (known, checked) = controllable[bundleID], Date().timeIntervalSince(checked) < 60 { return known }
        let result = Targets.canControl(app)
        controllable[bundleID] = (result, Date())
        return result
    }
}
