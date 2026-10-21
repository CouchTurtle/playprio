import ApplicationServices

/// Small typed wrappers around the Accessibility C API.
enum AX {
    /// For every element PlayPrio reads (the default is 6 s): a hung app must not stall it.
    /// Set on the system-wide element, it applies to all; set on an app element, only to that.
    static func limitMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) ?? []
    }

    static func windowTitles(pid: pid_t) -> [String] {
        let windows: [AXUIElement] = value(app(pid), kAXWindowsAttribute) ?? []
        return windows.compactMap { value($0, kAXTitleAttribute) }
    }
}
