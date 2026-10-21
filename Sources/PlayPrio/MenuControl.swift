import ApplicationServices

/// Controls an app without AppleScript support by pressing its own menu items
/// ("Play", "Pause", "Next", …), found through the Accessibility API.
/// Matching is by exact (normalized) title, English and German.
struct MenuControl {
    enum Command { case play, pause, next, previous }

    private static let titles: [Command: Set<String>] = [
        .play: ["play", "resume", "start playback", "abspielen", "wiedergeben", "wiedergabe", "fortsetzen"],
        .pause: ["pause", "pausieren", "anhalten"],
        .next: ["next", "next track", "next song", "next episode", "next item",
                "nächster titel", "nächster song", "nächste folge", "nächstes objekt"],
        .previous: ["previous", "previous track", "previous song", "previous episode", "previous item",
                    "vorheriger titel", "vorheriger song", "vorherige folge", "vorheriges objekt"],
    ]
    private static let playPauseTitles: Set<String> = [
        "play/pause", "play / pause", "play-pause", "play or pause",
        "abspielen/pausieren", "wiedergabe/pause", "wiedergeben/pausieren",
    ]

    /// Enabled menu items by normalized title.
    private let items: [String: AXUIElement]

    /// Menus that never hold playback commands but can be huge (a browser's bookmarks).
    private static let skippedMenus: Set<String> = [
        "file", "edit", "history", "bookmarks", "window", "help",
        "ablage", "datei", "bearbeiten", "verlauf", "lesezeichen", "fenster", "hilfe",
    ]

    /// Reads only the items directly inside each top-level menu (no submenus), which is
    /// where players put Play/Pause, and at most 80 per menu: every AX read is an IPC call.
    init(pid: pid_t) {
        var items: [String: AXUIElement] = [:]
        if let bar: AXUIElement = AX.value(AX.app(pid), kAXMenuBarAttribute) {
            for top in AX.children(bar).dropFirst() { // skip the Apple menu
                let menuTitle = (AX.value(top, kAXTitleAttribute) as String?).map(Self.normalize) ?? ""
                guard !Self.skippedMenus.contains(menuTitle) else { continue }
                for menu in AX.children(top) {
                    for item in AX.children(menu).prefix(80) {
                        guard let (title, enabled) = Self.titleAndEnabled(item), enabled, !title.isEmpty else { continue }
                        let key = Self.normalize(title)
                        if items[key] == nil { items[key] = item }
                    }
                }
            }
        }
        self.items = items
    }

    var canPlay: Bool { item(for: .play) != nil }
    var canPause: Bool { item(for: .pause) != nil }
    /// Only a "Play/Pause" item: pressing it to pause resumes an app that is already paused.
    var pauseIsToggle: Bool { canPause && Self.titles[.pause]?.contains { items[$0] != nil } != true }

    @discardableResult
    func press(_ command: Command) -> Bool {
        guard let item = item(for: command) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func item(for command: Command) -> AXUIElement? {
        if let match = Self.titles[command]?.lazy.compactMap({ items[$0] }).first { return match }
        guard command == .play || command == .pause else { return nil }
        return Self.playPauseTitles.lazy.compactMap { items[$0] }.first
    }

    /// Title and enabled state in one IPC round trip.
    private static func titleAndEnabled(_ item: AXUIElement) -> (String, Bool)? {
        var values: CFArray?
        let attributes = [kAXTitleAttribute, kAXEnabledAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(item, attributes, [], &values) == .success,
              let list = values as? [Any], list.count == 2, let title = list[0] as? String else { return nil }
        return (title, (list[1] as? Bool) ?? true)
    }

    private static func normalize(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}
