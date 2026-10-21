import Foundation

/// UserDefaults-backed settings. UserDefaults is thread-safe, so the tap thread may read too.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let order = "targetOrder"
        static let disabledTargets = "disabledTargets"
        static let addedApps = "addedApps"
        static let ignoredApps = "ignoredApps"
        static let autoAddApps = "autoAddApps"
        static let launchIfAbsent = "launchIfAbsent"
        static let blockAppleMusic = "blockAppleMusic"
        static let pauseOnHeadphonesGone = "pauseOnHeadphonesGone"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.order: Targets.builtIns.map(\.id) + [Targets.appSourceID("com.spotify.client")],
            Key.disabledTargets: [String](),
            Key.addedApps: ["com.spotify.client"],
            Key.ignoredApps: [String](),
            Key.autoAddApps: false,
            Key.launchIfAbsent: true,
            Key.blockAppleMusic: false,
            Key.pauseOnHeadphonesGone: false,
        ])
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    static var launchIfAbsent: Bool {
        get { defaults.bool(forKey: Key.launchIfAbsent) }
        set { defaults.set(newValue, forKey: Key.launchIfAbsent) }
    }

    /// Quit Apple Music when macOS opens it for a play command, not when the user opens it.
    static var blockAppleMusic: Bool {
        get { defaults.bool(forKey: Key.blockAppleMusic) }
        set { defaults.set(newValue, forKey: Key.blockAppleMusic) }
    }

    /// Pause when the sound moves from headphones to the speakers or another output.
    static var pauseOnHeadphonesGone: Bool {
        get { defaults.bool(forKey: Key.pauseOnHeadphonesGone) }
        set { defaults.set(newValue, forKey: Key.pauseOnHeadphonesGone) }
    }

    /// Add apps that start making sound to the end of the list automatically.
    static var autoAddApps: Bool {
        get { defaults.bool(forKey: Key.autoAddApps) }
        set { defaults.set(newValue, forKey: Key.autoAddApps) }
    }

    // MARK: Sources

    /// Bundle ids of the apps in the list (the web sources are always there).
    static var addedApps: [String] { defaults.stringArray(forKey: Key.addedApps) ?? [] }

    /// Apps the user removed; auto-add leaves them alone.
    static var ignoredApps: Set<String> { Set(defaults.stringArray(forKey: Key.ignoredApps) ?? []) }

    static func addApp(_ bundleID: String) {
        guard !addedApps.contains(bundleID) else { return }
        defaults.set(addedApps + [bundleID], forKey: Key.addedApps)
        defaults.set(Array(ignoredApps.subtracting([bundleID])), forKey: Key.ignoredApps)
        defaults.set(orderedTargets.map(\.id), forKey: Key.order) // new app lands last
    }

    /// Forgets the app's position and on/off state too, so adding it again starts fresh.
    static func removeApp(_ bundleID: String) {
        let id = Targets.appSourceID(bundleID)
        defaults.set(addedApps.filter { $0 != bundleID }, forKey: Key.addedApps)
        defaults.set(Array(ignoredApps.union([bundleID])), forKey: Key.ignoredApps)
        defaults.set((defaults.stringArray(forKey: Key.order) ?? []).filter { $0 != id }, forKey: Key.order)
        defaults.set((defaults.stringArray(forKey: Key.disabledTargets) ?? []).filter { $0 != id },
                     forKey: Key.disabledTargets)
    }

    /// All sources in priority order. Sources missing from the saved order go last.
    static var orderedTargets: [MediaTarget] {
        let order = defaults.stringArray(forKey: Key.order) ?? []
        return Targets.all.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.id) ?? order.count + a.offset
            let ib = order.firstIndex(of: b.element.id) ?? order.count + b.offset
            return ia < ib
        }.map(\.element)
    }

    /// The sources PlayPrio routes to, in priority order.
    static var activeTargets: [MediaTarget] {
        orderedTargets.filter { isTargetEnabled($0.id) }
    }

    static func isTargetEnabled(_ id: String) -> Bool {
        !(defaults.stringArray(forKey: Key.disabledTargets) ?? []).contains(id)
    }

    static func setTarget(_ id: String, enabled: Bool) {
        var disabled = Set(defaults.stringArray(forKey: Key.disabledTargets) ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(Array(disabled), forKey: Key.disabledTargets)
    }

    static func moveTarget(_ id: String, by offset: Int) {
        var order = orderedTargets.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        defaults.set(order, forKey: Key.order)
    }
}
