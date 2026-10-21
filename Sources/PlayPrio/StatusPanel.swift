import AppKit

/// A transparent, borderless panel hanging below the menu bar. The visible part (the glass
/// card) is drawn by SwiftUI at its top; the window is sized once in `place` and never
/// resized while open, because resizing a window mid-animation makes its content jump.
final class StatusPanel: NSPanel {
    /// Room around the card so its shadow isn't clipped by the window edge.
    static let margin: CGFloat = 20
    /// Gap between the menu bar and the card.
    static let topGap: CGFloat = 6

    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    /// A click elsewhere or Esc: the owner decides how to close (it animates first).
    var onDismissRequest: () -> Void = {}

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 384, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the card draws its own
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    /// Places the window under the menu bar that was clicked. With several displays the
    /// status item's own window can sit in another display's menu bar, so the click decides
    /// the screen; the icon's frame only refines the horizontal center when it's there too.
    func place(at click: NSPoint, iconRect: NSRect?, cardWidth: CGFloat) {
        let screen = NSScreen.screens.first { NSMouseInRect(click, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var midX = click.x
        if let iconRect, screen.frame.contains(NSPoint(x: iconRect.midX, y: iconRect.midY)) {
            midX = iconRect.midX
        }
        let width = cardWidth + Self.margin * 2
        let x = min(max(midX - width / 2, visible.minX), visible.maxX - width)
        // As tall as the screen allows: the card grows inside it without moving the window.
        setFrame(NSRect(x: x, y: visible.minY + 8, width: width, height: visible.height - 8), display: false)
    }

    func show() {
        removeMonitors() // reopened during the close animation
        makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.onDismissRequest()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.window === self else { return event } // Esc
            self?.onDismissRequest()
            return nil
        }
    }

    func hide() {
        orderOut(nil)
        removeMonitors()
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    /// Renders the content once while invisible, so the first real opening (and the first
    /// expansion of the settings) doesn't show views being built.
    func prerender() {
        alphaValue = 0
        orderFrontRegardless()
        contentView?.layoutSubtreeIfNeeded()
        display()
        orderOut(nil)
        alphaValue = 1
    }
}
