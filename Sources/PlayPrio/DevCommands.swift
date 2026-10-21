import AppKit
import SwiftUI

/// Command-line modes for testing without pressing keys or clicking the menu bar.
enum DevCommands {
    static let usage = """
    PlayPrio test commands:
      --probe                                      state of every source and of other sound
      --do playPause|next|previous                 route one key press like the app would
      --pass-key playPause|next|previous           send a key to macOS past PlayPrio
      --headphones-gone                            pause like when headphones disconnect
      --snapshot <file.png> [--expanded]           render the panel (light) with live data
      --panel-test [--expanded]                    open the real panel briefly, print its frame
    """

    /// Runs the command in `args` (the "--" arguments) and returns the exit code.
    static func run(_ args: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1),
                  !args[index + 1].hasPrefix("--") else { return nil }
            return args[index + 1]
        }
        switch args.first {
        case "--probe":
            probe()
            return 0
        case "--do":
            guard let key = value(after: "--do").flatMap(MediaKey.init(rawValue:)) else { break }
            let router = Router()
            router.handle(key)
            print(router.lastAction ?? "-")
            if let problem = router.problem { print("Problem: \(problem)") }
            return 0
        case "--pass-key":
            guard let key = value(after: "--pass-key").flatMap(MediaKey.init(rawValue:)) else { break }
            MediaKeyTap.passToSystem(key)
            return 0
        case "--headphones-gone":
            let router = Router()
            router.pauseAllPlaying()
            print(router.lastAction ?? "-")
            if let problem = router.problem { print("Problem: \(problem)") }
            return 0
        case "--snapshot":
            guard let path = value(after: "--snapshot") else { break }
            return snapshot(to: path, expanded: args.contains("--expanded"))
        case "--panel-test":
            panelTest(expanded: args.contains("--expanded"))
            return 0
        default:
            break
        }
        print(usage)
        return 1
    }

    private static func probe() {
        let router = Router()
        for (target, status) in router.takeSnapshot() {
            let track = [status.title, status.artist].filter { !$0.isEmpty }.joined(separator: " / ")
            print("\(target.displayName): \(status.state.rawValue)\(track.isEmpty ? "" : " – \(track)")")
        }
        if let problem = router.problem { print("Problem: \(problem)") }
        let output = HeadphoneWatcher.defaultOutput
        print("Output: \(HeadphoneWatcher.name(of: output))"
              + (HeadphoneWatcher.isHeadphones(output) ? " (headphones)" : ""))
        let audioApps = AudioProcesses.appsPlayingAudio().compactMap(\.localizedName)
        print("Apps making sound: \(audioApps.isEmpty ? "-" : audioApps.joined(separator: ", "))")
        for item in router.otherAudio.scan(discovery: .now) {
            let how = item.target != nil ? "controlled" : item.viaSystem ? "via macOS" : "no control"
            let name = item.status.title.isEmpty ? item.app.localizedName ?? "?" : item.status.title
            print("Other: \(name) [\(item.app.localizedName ?? "?")]: \(item.status.state.rawValue), \(how)"
                  + (item.keyPausesIt ? "" : ", key ignores it"))
        }
    }

    /// Light only: drawn off screen, the glass's text doesn't take the dark appearance.
    private static func snapshot(to path: String, expanded: Bool) -> Int32 {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        let store = Store()
        store.tapRunning = true
        store.settingsExpanded = expanded
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(3)) // status + covers

        let hosting = NSHostingView(rootView: PanelView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.frame.size = hosting.fittingSize
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return 0
        } catch {
            print("Couldn't write \(path): \(error.localizedDescription)")
            return 1
        }
    }

    /// Opens the real panel as if the main screen's menu bar had been clicked and prints
    /// where the window ended up, and whether expanding the settings moved it.
    private static func panelTest(expanded: Bool) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = Store()
        store.tapRunning = true
        let controller = PanelController(store: store)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        controller.show(at: NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 10), iconRect: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let before = controller.frame ?? .zero
        if expanded {
            store.settingsExpanded = true
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        let frame = controller.frame ?? .zero
        print("screen visible frame:   \(screen.visibleFrame)")
        print("window frame:           \(frame)")
        print("window top at menu bar: \(frame.maxY == screen.visibleFrame.maxY)")
        print("centered on click:      \(abs(frame.midX - screen.frame.midX) < 1)")
        print("window unchanged:       \(before == frame)")
        print("rows:                   \(store.rows.count)")
    }
}
