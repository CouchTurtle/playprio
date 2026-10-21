import CoreImage.CIFilterBuiltins
import SwiftUI

/// The iPhone remote's lines in the panel's settings: on/off, and the QR code that pairs it.
struct CompanionSettings: View {
    @ObservedObject private var companion = Companion.shared
    @State private var showsCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingSwitch(title: "iPhone remote", isOn: Binding(get: { companion.isOn }, set: { companion.setOn($0) }))
                .help("Shows what's playing on your iPhone's Lock Screen and in StandBy, with working buttons.")

            if companion.isOn {
                HStack {
                    // Re-read every few seconds so "connected" goes away when the iPhone does.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(showsCode ? "Hide Code" : "Pair iPhone…") { showsCode.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.playPrioAccent)
                }
                if showsCode, let url = companion.pairingURL {
                    HStack(alignment: .top, spacing: 12) {
                        QRCode(text: url.absoluteString).frame(width: 116, height: 116)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with the iPhone camera, open the page in Safari and tap Start. Then lock the iPhone or put it in StandBy.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let address = companion.address {
                                Text(address)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .help("The iPhone has to be able to reach this address, port included.")
                            }
                            Button("New Key") { companion.newKey() }
                                .controlSize(.small)
                                .help("iPhones paired before lose access until they scan the new code.")
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var status: String {
        if let problem = companion.problem { return problem }
        return companion.isConnected ? "iPhone connected" : "No iPhone connected"
    }
}

private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8) // the quiet zone scanners need
                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
        }
    }

    /// The last code made: the view is redrawn every few seconds while it's shown.
    private static var last: (text: String, image: NSImage?)?

    private static func image(for text: String) -> NSImage? {
        if let last, last.text == text { return last.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let image = filter.outputImage.flatMap { output in
            CIContext().createCGImage(output, from: output.extent).map { NSImage(cgImage: $0, size: output.extent.size) }
        }
        last = (text, image)
        return image
    }
}
