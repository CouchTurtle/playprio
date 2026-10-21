import AppKit
import SwiftUI

/// Owns the panel window, the SwiftUI view inside it and the open/close animation.
final class PanelController {
    private let store: Store
    private let presentation = PanelPresentation()
    private var panel: StatusPanel?
    private var closing = false
    var onClose: () -> Void = {}

    init(store: Store) {
        self.store = store
    }

    var isShown: Bool { (panel?.isVisible ?? false) && !closing }
    var frame: NSRect? { panel?.frame }

    /// Builds and renders the panel ahead of the first click.
    func prepare() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let panel = makePanel()
        panel.place(at: NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1), iconRect: nil, cardWidth: PanelView.width)
        panel.prerender()
    }

    func show(at click: NSPoint, iconRect: NSRect?) {
        let panel = self.panel ?? makePanel()
        closing = false
        presentation.isPresented = false
        store.startLiveUpdates()
        panel.place(at: click, iconRect: iconRect, cardWidth: PanelView.width)
        panel.show()
        DispatchQueue.main.async { // after the hidden state is on screen, so it animates
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { self.presentation.isPresented = true }
        }
    }

    func close() {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: 0.12)) { presentation.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.closing else { return }
            self.closing = false
            panel.hide()
            self.store.stopLiveUpdates()
            self.onClose()
        }
    }

    private func makePanel() -> StatusPanel {
        let hosting = NSHostingView(rootView: PanelHost(store: store, presentation: presentation,
                                                        dismiss: { [weak self] in self?.close() }))
        hosting.sizingOptions = [] // the window has a fixed size; the card sizes itself inside
        let panel = StatusPanel(content: hosting)
        panel.onDismissRequest = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }
}

final class PanelPresentation: ObservableObject {
    @Published var isPresented = false
}

/// Fills the transparent window: the card at the top, popping in from the menu bar. A click
/// beside the card closes the panel: here if the window receives it, or through the
/// panel's outside-click monitor if it passes through the transparent area.
struct PanelHost: View {
    @ObservedObject var store: Store
    @ObservedObject var presentation: PanelPresentation
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            PanelView(store: store, dismiss: dismiss)
                .scaleEffect(presentation.isPresented ? 1 : 0.92, anchor: .top)
                .offset(y: presentation.isPresented ? 0 : -8)
                .opacity(presentation.isPresented ? 1 : 0)
                .padding(.top, StatusPanel.topGap)
                .padding(.horizontal, StatusPanel.margin)
        }
    }
}
