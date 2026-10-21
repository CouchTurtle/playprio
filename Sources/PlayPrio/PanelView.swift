import SwiftUI

extension Color {
    /// PlayPrio's orange (#ff6600, as in the icon), used whatever the system accent color is.
    static let playPrioAccent = Color(.sRGB, red: 1, green: 0x66 / 255, blue: 0)
}

/// Modeled on macOS's own Now Playing popover: a large card for the music PlayPrio routes
/// the keys to, compact rows for everything else making sound, and PlayPrio's own settings
/// folded away at the bottom.
struct PanelView: View {
    @ObservedObject var store: Store
    var dismiss: () -> Void = {}

    static let width: CGFloat = 344

    private var hero: Store.Row? { store.rows.first(where: \.getsKey) ?? store.rows.first }
    private var others: [Store.Row] { store.rows.filter { $0.id != hero?.id } }

    var body: some View {
        VStack(spacing: 0) {
            banner
            if let hero {
                HeroCard(
                    row: hero,
                    artwork: hero.artworkURL.flatMap { store.artwork[$0] },
                    onPrevious: { store.skip(hero, forward: false) },
                    onToggle: { store.togglePlayback(hero) },
                    onNext: { store.skip(hero) },
                    onFocus: {
                        store.focus(hero)
                        dismiss()
                    }
                )
                .contextMenu { rowMenu(hero) }
            }
            ForEach(others) { row in
                RowDivider()
                NowPlayingRow(
                    row: row,
                    artwork: row.artworkURL.flatMap { store.artwork[$0] },
                    onToggle: { store.togglePlayback(row) },
                    onNext: { store.skip(row) },
                    onFocus: {
                        store.focus(row)
                        dismiss()
                    }
                )
                .contextMenu { rowMenu(row) }
            }
            RowDivider()
            PlayPrioSection(store: store, dismiss: dismiss)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.playPrioAccent)
        .modifier(CardBackground())
    }

    @ViewBuilder private func rowMenu(_ row: Store.Row) -> some View {
        Button("Open \(row.appName)") {
            store.focus(row)
            dismiss()
        }
        Divider()
        if let bundleID = row.addableBundleID {
            Button("Add to PlayPrio") { store.addApp(bundleID) }
        }
        if let bundleID = row.removableBundleID {
            Button("Remove from PlayPrio") { store.removeApp(bundleID) }
        }
        if row.addableBundleID == nil, row.removableBundleID == nil, Targets.target(id: row.id) != nil {
            Text("Built into PlayPrio")
        }
    }

    // MARK: Problems

    @ViewBuilder private var banner: some View {
        if !store.tapRunning {
            Banner(text: "PlayPrio needs Accessibility access to catch the media keys.",
                   button: "Open", action: { openSettings("Privacy_Accessibility") })
        } else {
            switch store.problem {
            case .javaScriptDisabled(let app)?:
                Banner(text: "\(app): View → Developer → Allow JavaScript from Apple Events.")
            case .notAuthorized(let app)?:
                Banner(text: "PlayPrio isn't allowed to control \(app).",
                       button: "Open", action: { openSettings("Privacy_Automation") })
            case .failed(let message)?:
                Banner(text: message)
            case nil:
                EmptyView()
            }
        }
    }

    private func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
        dismiss()
    }
}

/// The card's chrome: Liquid Glass on macOS 26, a blurred material with a hairline before.
private struct CardBackground: ViewModifier {
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func body(content: Content) -> some View {
        #if compiler(>=6.2) // the macOS 26 SDK, which has Liquid Glass
        if #available(macOS 26.0, *) {
            content
                .clipShape(Self.shape)
                .glassEffect(.regular, in: Self.shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content
            .clipShape(Self.shape)
            .background(.regularMaterial, in: Self.shape)
            .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

// MARK: - Large card

/// The big player from macOS's Now Playing: cover, title, "Artist – Album",
/// ⏮ ▶ ⏭ and a progress bar with elapsed/remaining time.
private struct HeroCard: View {
    let row: Store.Row
    let artwork: NSImage?
    let onPrevious: () -> Void
    let onToggle: () -> Void
    let onNext: () -> Void
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            LargeCover(artwork: artwork, icon: row.icon)
                .onTapGesture(perform: onFocus)
                .help("Open \(row.appName)")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if !row.longSubtitle.isEmpty {
                        Text(row.longSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TransportButton(symbol: "backward.fill", size: 17, enabled: row.canSkip, action: onPrevious)
                    TransportButton(symbol: row.state == .playing ? "pause.fill" : "play.fill", size: 26,
                                    enabled: row.canControl, action: onToggle)
                        .frame(width: 58)
                    TransportButton(symbol: "forward.fill", size: 17, enabled: row.canSkip, action: onNext)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                ProgressBar(position: row.position, duration: row.duration, readAt: row.readAt,
                            playing: row.state == .playing)
            }
            .frame(height: 112)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

private struct LargeCover: View {
    let artwork: NSImage?
    let icon: NSImage

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
                    .overlay(Image(nsImage: icon).resizable().frame(width: 56, height: 56))
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(artwork == nil ? 0 : 0.25), radius: 6, y: 2)
    }
}

/// Advances on its own while playing; the sources are only polled every 1.5 s.
private struct ProgressBar: View {
    let position: Double?
    let duration: Double?
    let readAt: Date
    let playing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let total = duration ?? 0
            let elapsed = min(total, max(0, (position ?? 0) + (playing ? context.date.timeIntervalSince(readAt) : 0)))
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule().fill(Color.playPrioAccent)
                            .frame(width: total > 0 ? proxy.size.width * elapsed / total : 0)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(total > 0 ? Self.format(elapsed) : "--:--")
                    Spacer()
                    Text(total > 0 ? "-" + Self.format(total - elapsed) : "--:--")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .opacity(total > 0 ? 1 : 0.4)
        }
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Now Playing rows

private struct NowPlayingRow: View {
    let row: Store.Row
    let artwork: NSImage?
    let onToggle: () -> Void
    let onNext: () -> Void
    let onFocus: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Cover(artwork: artwork, icon: row.icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            TransportButton(symbol: row.state == .playing ? "pause.fill" : "play.fill", size: 22,
                            enabled: row.canControl, action: onToggle)
            TransportButton(symbol: "forward.fill", size: 18, enabled: row.canSkip, action: onNext)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 13)
        .background(Color.primary.opacity(hovering ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onFocus)
    }
}

private struct Cover: View {
    let artwork: NSImage?
    let icon: NSImage

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .offset(x: 5, y: 5)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay(Image(nsImage: icon).resizable().frame(width: 28, height: 28))
            }
        }
        .frame(width: 48, height: 48, alignment: .topLeading)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.primary.opacity(enabled ? (hovering ? 0.95 : 0.72) : 0.22))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
    }
}

// MARK: - PlayPrio section

private struct PlayPrioSection: View {
    @ObservedObject var store: Store
    let dismiss: () -> Void

    private var status: String {
        guard store.isEnabled else { return "Media keys: macOS default" }
        return store.keyTargetName.map { "Media keys → \($0)" } ?? "Media keys: PlayPrio"
    }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Deliberately quiet: one small line that only says where the keys go.
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isEnabled ? Color.playPrioAccent : Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(status).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(store.settingsExpanded ? 180 : 0))
            }
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.smooth(duration: 0.25)) { store.settingsExpanded.toggle() }
            }

            // Always built, only folded to zero height: building the switches and menus on the
            // first expand made that frame hitch.
            VStack(alignment: .leading, spacing: 4) {
                SettingSwitch(title: "Route media keys with PlayPrio", isOn: $store.isEnabled)
                    .help("⌃⌥ + Play toggles this too")
                Divider().padding(.vertical, 6)
                priorityList
                Divider().padding(.vertical, 6)
                SettingSwitch(title: "Auto-add apps that make sound", isOn: $store.autoAddApps)
                    .help("Apps PlayPrio can control join the end of the list when they start playing.")
                SettingSwitch(title: "Play opens YouTube Music when closed", isOn: $store.launchIfAbsent)
                SettingSwitch(title: "Quit Apple Music when it opens by itself", isOn: $store.blockAppleMusic)
                    .help("When macOS opens Music for the play key, headphones or Control Center. Music you open yourself stays open.")
                SettingSwitch(title: "Pause when headphones disconnect", isOn: $store.pauseOnHeadphonesGone)
                    .help("When the sound moves from headphones (Bluetooth, USB, wired) to the speakers or another output, pause what PlayPrio controls.")
                SettingSwitch(title: "Open at login",
                              isOn: Binding(get: { store.opensAtLogin }, set: { store.setOpensAtLogin($0) }))
                Divider().padding(.vertical, 6)
                CompanionSettings()
                Divider().padding(.vertical, 6)
                ShortcutRow(keys: "⇧ + media key", meaning: "goes to macOS as usual")
                ShortcutRow(keys: "⌃⌥ + Play", meaning: "turns PlayPrio on/off")
                Divider().padding(.vertical, 6)
                HStack {
                    Text(store.lastAction.map { "Last: \($0)" } ?? "Ready")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Quit PlayPrio") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(height: store.settingsExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(store.settingsExpanded ? 1 : 0)
            .allowsHitTesting(store.settingsExpanded)
            .accessibilityHidden(!store.settingsExpanded)
        }
    }

    private var priorityList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Priority").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(store.addableApps) { app in
                        Button {
                            store.addApp(app.bundleID)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                    if !store.addableApps.isEmpty { Divider() }
                    Button("Other App…") {
                        dismiss()
                        store.chooseApp()
                    }
                } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            ForEach(Array(store.targetSettings.enumerated()), id: \.element.id) { index, target in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Toggle("", isOn: Binding(get: { target.enabled },
                                             set: { store.setTarget(target.id, enabled: $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Image(nsImage: target.icon).resizable().frame(width: 16, height: 16)
                    Text(target.name).font(.system(size: 12))
                        .foregroundStyle(target.enabled ? .primary : .secondary)
                        .lineLimit(1)
                    if !target.autoResume {
                        Text("pause only")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help("The media key pauses it while it plays, but Play only resumes it if PlayPrio paused it last.")
                    }
                    Spacer()
                    SmallIconButton(symbol: "chevron.up", enabled: index > 0) { store.moveTarget(target.id, by: -1) }
                    SmallIconButton(symbol: "chevron.down", enabled: index < store.targetSettings.count - 1) {
                        store.moveTarget(target.id, by: 1)
                    }
                    if let bundleID = target.removableBundleID {
                        SmallIconButton(symbol: "minus") { store.removeApp(bundleID) }
                            .help("Remove from the list")
                    } else {
                        Color.clear.frame(width: 22, height: 22)
                    }
                }
            }
        }
    }
}

// MARK: - Small pieces

private struct SmallIconButton: View {
    let symbol: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovering = $0 }
    }
}

struct SettingSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.vertical, 1)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let meaning: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            Text(meaning).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct Banner: View {
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.playPrioAccent)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.playPrioAccent.opacity(0.15)))
        .padding(10)
    }
}
