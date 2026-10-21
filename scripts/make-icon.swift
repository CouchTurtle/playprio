// Draws PlayPrio's icon: three stacked cards (the priority list), the front one with a play
// triangle, on PlayPrio's orange (#ff6600). Writes the Mac app icon and the iPhone page's icon.
//
//   swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
//
// Resources/AppIcon.icns  the app (macOS icon grid: an 824 pt rounded square on 1024, shadow)
// Resources/WebIcon.png   the iPhone page (180 px, full bleed: iOS rounds the corners itself)
import AppKit

let resources = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The artwork in a square `box`, in a context whose origin is bottom left.
func drawArtwork(in context: CGContext, box: CGRect, cornerRadius: CGFloat) {
    let shape = CGPath(roundedRect: box, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xFF8533), color(0xFF6600)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])

    // Three frosted cards, back to front: each a step higher, evenly narrower and fainter.
    // Each paints only what the cards in front leave visible, so none shows through
    // another; the front one lets a little of the orange through, like glass.
    let unit = box.width / 824
    let front = CGSize(width: 420 * unit, height: 330 * unit)
    let step = 62 * unit, radius = 60 * unit
    let frontTop = box.midY + (front.height + 2 * step) / 2 - 2 * step + 10 * unit
    let center = CGPoint(x: box.midX, y: frontTop - front.height / 2)
    let cards = (0..<3).map { index -> (path: CGPath, top: CGFloat) in
        let width = front.width * (1 - CGFloat(index) * 0.12)
        let top = frontTop + CGFloat(index) * step
        let rect = CGRect(x: box.midX - width / 2, y: top - front.height, width: width, height: front.height)
        return (CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil), top)
    }
    let glass: [(top: CGFloat, bottom: CGFloat)] = [(0.97, 0.76), (0.64, 0.52), (0.40, 0.30)]
    func whites(_ top: CGFloat, _ bottom: CGFloat) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)] as CFArray, locations: [0, 1])!
    }
    for index in [2, 1, 0] {
        let (card, top) = cards[index]
        let span = (start: CGPoint(x: box.midX, y: top), end: CGPoint(x: box.midX, y: top - front.height))
        if index == 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 30 * unit, color: color(0x7A2E00, 0.35))
            context.addPath(card)
            context.setFillColor(color(0xFFFFFF))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(card)
        context.clip()
        for nearer in cards[..<index] {
            context.addRect(box)
            context.addPath(nearer.path)
            context.clip(using: .evenOdd)
        }
        context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
        context.drawLinearGradient(whites(glass[index].top, glass[index].bottom), start: span.start, end: span.end, options: [])
        // The glass edge: a bright rim on the inside, strongest at the top.
        context.addPath(card)
        context.setLineWidth(6 * unit)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(whites(index == 0 ? 0.9 : 0.45, 0.3), start: span.start, end: span.end, options: [])
        context.restoreGState()
    }

    // The play triangle on the front card, with softly rounded corners.
    let side = 168 * unit
    let tip = CGPoint(x: center.x + side * 0.62, y: center.y)
    let top = CGPoint(x: center.x - side * 0.42, y: center.y + side * 0.62)
    let bottom = CGPoint(x: center.x - side * 0.42, y: center.y - side * 0.62)
    let triangle = CGMutablePath()
    let round = 22 * unit
    triangle.move(to: CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2))
    triangle.addArc(tangent1End: top, tangent2End: tip, radius: round)
    triangle.addArc(tangent1End: tip, tangent2End: bottom, radius: round)
    triangle.addArc(tangent1End: bottom, tangent2End: top, radius: round)
    triangle.closeSubpath()
    context.addPath(triangle)
    context.setFillColor(color(0xFF6600))
    context.fillPath()
    context.restoreGState()
}

func png(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context, CGFloat(size))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

/// macOS: an 824/1024 rounded square with a soft shadow, transparent around it.
func macIcon(_ size: Int) -> Data {
    png(size: size) { context, side in
        let unit = side / 1024
        let box = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: color(0x000000, 0.3))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil))
        context.setFillColor(color(0xFF6600))
        context.fillPath()
        context.restoreGState()
        drawArtwork(in: context, box: box, cornerRadius: 185 * unit)
    }
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try macIcon(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try macIcon(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

// iPhone: full bleed (iOS adds the rounded corners), slightly larger artwork.
try png(size: 180) { context, side in
    drawArtwork(in: context, box: CGRect(x: -side * 0.06, y: -side * 0.06, width: side * 1.12, height: side * 1.12), cornerRadius: 0)
}.write(to: resources.appendingPathComponent("WebIcon.png"))
let preview = fileManager.temporaryDirectory.appendingPathComponent("PlayPrio-icon-preview.png")
try macIcon(1024).write(to: preview)
print("wrote \(resources.path)/AppIcon.icns and WebIcon.png, and a 1024 px preview: \(preview.path)")
