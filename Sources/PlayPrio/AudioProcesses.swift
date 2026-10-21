import AppKit
import CoreAudio

/// Which processes are sending sound to an output right now, via Core Audio's process list
/// (public API since macOS 14.2, no permission needed). It's a hint, not proof: Core Audio
/// can keep reporting a process as running for a while after it pauses.
enum AudioProcesses {
    struct Source {
        /// The process actually producing the sound (often a helper or XPC service).
        let pid: pid_t
        let bundleID: String?
        /// The regular app it belongs to (Chrome for Chrome Helper, Finder for Quick Look).
        let app: NSRunningApplication
    }

    /// One refresh asks several times (each menu-controlled app, the other-audio scan); the
    /// answer can't change meaningfully within a fraction of a second.
    private static let cache = Cache()

    static func sources() -> [Source] {
        cache.value(maxAge: 0.3, compute: readSources)
    }

    private static func readSources() -> [Source] {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard AudioProperty.read(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1,
                  let pid = AudioProperty.read(object, kAudioProcessPropertyPID, as: pid_t.self),
                  let app = owningApp(of: pid) else { return nil }
            return Source(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, app: app)
        }
    }

    /// The regular apps making sound, each once.
    static func appsPlayingAudio() -> [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        for source in sources() where !apps.contains(where: { $0.processIdentifier == source.app.processIdentifier }) {
            apps.append(source.app)
        }
        return apps
    }

    static func bundleIDsPlayingAudio() -> Set<String> {
        Set(appsPlayingAudio().compactMap(\.bundleIdentifier))
    }

    /// Audio usually comes from a helper (Chrome Helper, WebKit GPU), not the app itself.
    /// Map it to the app responsible for it, using an undocumented libSystem call when
    /// available and the bundle-id prefix (com.google.Chrome.helper → com.google.Chrome) otherwise.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        for candidate in [pid, responsiblePID?(pid) ?? pid] {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular {
                return app
            }
        }
        guard let helperID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular && app.bundleIdentifier.map { helperID.hasPrefix($0 + ".") } == true
        }
    }

    private final class Cache {
        private let lock = NSLock()
        private var stored: (sources: [Source], at: Date)?

        func value(maxAge: TimeInterval, compute: () -> [Source]) -> [Source] {
            lock.lock()
            defer { lock.unlock() }
            if let stored, Date().timeIntervalSince(stored.at) < maxAge { return stored.sources }
            let sources = compute()
            stored = (sources, Date())
            return sources
        }
    }

    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()
}
