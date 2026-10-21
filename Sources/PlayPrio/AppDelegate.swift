import AppKit
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "local.PlayPrio", category: "App")

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = MediaKeyTap()
    private let store = Store()
    private let headphones = HeadphoneWatcher()
    private lazy var panel = PanelController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "PlayPrio" // keeps the spot you ⌘-drag it to
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.onStatusChange = { [weak self] in self?.refreshIcon() }
        Companion.shared.attach(store)
        panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }
        tap.shouldIntercept = { Settings.isEnabled }
        tap.onKey = { [weak self] key, pressedAt in self?.store.handleKey(key, pressedAt: pressedAt) }
        tap.onToggle = { [weak self] in self?.store.isEnabled.toggle() }
        headphones.onDisconnect = { [weak self] in self?.store.headphonesGone() }
        headphones.start()

        watchAppleMusic()
        startTapWhenTrusted()
        refreshIcon()
        panel.prepare()
    }

    // MARK: Panel

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isShown {
            panel.close()
            return
        }
        let iconRect = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        panel.show(at: NSEvent.mouseLocation, iconRect: iconRect)
        button.highlight(true)
    }

    // MARK: Accessibility

    private func startTapWhenTrusted() {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt), tap.start() {
            reportTap("running")
            store.tapRunning = true
            return
        }
        reportTap("waiting for Accessibility access")
        // The grant takes effect without a relaunch; poll until it's there.
        _ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.tap.start() else { return }
            timer.invalidate()
            self.reportTap("running")
            self.store.tapRunning = true
        }
    }

    /// Logged, and kept in the defaults so `defaults read local.PlayPrio tapStatus` shows it.
    private func reportTap(_ status: String) {
        Self.log.notice("media key tap: \(status, privacy: .public)")
        UserDefaults.standard.set("\(status) (\(Date().formatted(date: .omitted, time: .standard)))", forKey: "tapStatus")
    }

    // MARK: Apple Music guard

    /// Optional safety net for launches the key tap can't prevent (AirPods, Control Center,
    /// keys passed on to macOS). With nothing else as the Now Playing app, macOS opens Music
    /// for a play command through a background service (mediaremoted), so no app is recorded
    /// as its launcher. When you open Music, the Dock, Finder, Spotlight etc. are; that Music
    /// stays. Coming to the front tells nothing: macOS activates Music in both cases.
    private func watchAppleMusic() {
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard Settings.isEnabled, Settings.blockAppleMusic,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard !Self.wasOpenedByAnApp(app) else { return }
                DispatchQueue.main.async {
                    Self.log.notice("quitting Apple Music: macOS opened it, not an app")
                    app.terminate()
                }
            }
        }
    }

    /// Asks LaunchServices whether an app opened `app`. Scripts (`open` in Terminal, AppleScript)
    /// record none either. Without a clear answer it assumes an app did, so Music is left alone.
    private static func wasOpenedByAnApp(_ app: NSRunningApplication) -> Bool {
        let lsappinfo = Process()
        lsappinfo.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        lsappinfo.arguments = ["info", "-only", "parentasn", String(app.processIdentifier)]
        let pipe = Pipe()
        lsappinfo.standardOutput = pipe
        lsappinfo.standardError = FileHandle.nullDevice
        guard (try? lsappinfo.run()) != nil else { return true }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsappinfo.waitUntilExit()
        return !output.contains("\"LSParentASN\"=[ NULL ]") // else "…"=ASN:0x0-0x2a02a:
    }

    // MARK: Menu-bar icon

    /// Same symbol as the system's Now Playing item, so that one can be hidden.
    private func refreshIcon() {
        let symbol: String
        if !store.tapRunning || store.problem != nil {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = store.isEnabled ? "play.circle" : "play.slash"
        }
        // Sized like the system's own menu-bar symbols (the default is a little smaller).
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PlayPrio")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}
