import AppKit
import CoreGraphics

enum MediaKey: String {
    case playPause, next, previous
}

/// Catches the keyboard's media keys before macOS routes them to its "Now Playing" app.
///
/// Media keys arrive as `NX_SYSDEFINED` events (type 14, subtype 8). Returning nil from the
/// callback swallows them, so neither QuickTime nor Apple Music ever sees the press. Both
/// key-down and key-up are swallowed, otherwise macOS may still act on the lone key-up.
/// The tap runs on its own thread so a slow AppleScript can never stall it into a timeout.
final class MediaKeyTap {
    /// Asked on the tap thread for every press: should PlayPrio take this key?
    var shouldIntercept: () -> Bool = { true }
    /// Called on the main thread for each intercepted key-down, with when it was pressed.
    var onKey: (MediaKey, Date) -> Void = { _, _ in }
    /// Called on the main thread for ⌃⌥ + Play.
    var onToggle: () -> Void = {}

    private var tap: CFMachPort?
    private var swallowedDowns = Set<Int>() // only touched on the tap thread

    /// Tags the key presses PlayPrio itself sends to macOS so the tap lets them through.
    private static let passThroughMarker: Int64 = 0x504C_5052 // "PLPR"

    /// Sends a media key to macOS as if PlayPrio weren't running; macOS hands it to its
    /// Now Playing app. Used for sources PlayPrio can't control itself.
    static func passToSystem(_ key: MediaKey) {
        let code: Int
        switch key {
        case .playPause: code = 16
        case .next: code = 17
        case .previous: code = 18
        }
        for state in [0xA, 0xB] { // key down, key up
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1
            )?.cgEvent else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: passThroughMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func create(_ location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: refcon)
        }
        guard let port = create(.cghidEventTap) ?? create(.cgSessionEventTap) else { return false }
        tap = port

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "PlayPrio.MediaKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14, event.getIntegerValueField(.eventSourceUserData) != Self.passThroughMarker,
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return pass
        }

        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let flags = ns.data1 & 0x0000_FFFF
        let isDown = (flags & 0xFF00) >> 8 == 0xA
        let isRepeat = flags & 0x1 == 1

        let key: MediaKey
        switch code {
        case 16: key = .playPause            // NX_KEYTYPE_PLAY
        case 17, 19: key = .next             // NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST (F9)
        case 18, 20: key = .previous         // NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND (F7)
        default: return pass
        }

        guard isDown else {
            return swallowedDowns.remove(code) != nil ? nil : pass
        }
        if isRepeat {
            return swallowedDowns.contains(code) ? nil : pass
        }

        let modifiers = event.flags.union(CGEventSource.flagsState(.hidSystemState))
        let option = modifiers.contains(.maskAlternate)
        let control = modifiers.contains(.maskControl)
        let shift = modifiers.contains(.maskShift)

        if key == .playPause && option && control {
            swallowedDowns.insert(code)
            DispatchQueue.main.async { self.onToggle() }
            return nil
        }
        // ⇧ + key = hand this one press to macOS as if PlayPrio weren't running.
        guard !shift, shouldIntercept() else { return pass }

        swallowedDowns.insert(code)
        let pressedAt = Date()
        DispatchQueue.main.async { self.onKey(key, pressedAt) }
        return nil
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
