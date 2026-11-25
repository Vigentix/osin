// Renders the Osin app icon (ring with a gap and a status dot) into the asset catalog.
//   swift scripts/make-icon.swift
import AppKit

let output = "Osin/Resources/Assets.xcassets/AppIcon.appiconset"
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(_ pixels: Int) -> Data? {
    let scale = CGFloat(pixels) / 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824 pt body centred in 1024, continuous corners.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    color(0x15161C).setFill()
    shape.fill()
    ctx.restoreGState()
    let highlight = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    highlight.lineWidth = 4
    color(0xFFFFFF, 0.08).setStroke()
    highlight.stroke()

    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 238
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = 92
    color(0xFFFFFF, 0.06).setStroke()
    track.stroke()

    // Ring with a 65° gap centred at the top right (45°).
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 77.5, endAngle: 372.5, clockwise: false)
    ring.lineWidth = 92
    ring.lineCapStyle = .round
    color(0x7C6CFF).setStroke()
    ring.stroke()

    let dotCenter = NSPoint(x: center.x + radius * 0.7071, y: center.y + radius * 0.7071)
    color(0x34D399).setFill()
    NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 56, y: dotCenter.y - 56, width: 112, height: 112)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var images: [[String: String]] = []
for entry in sizes {
    guard let data = render(entry.pixels) else { fatalError("render failed") }
    try data.write(to: URL(fileURLWithPath: "\(output)/\(entry.name).png"))
    let parts = entry.name.replacingOccurrences(of: "icon_", with: "").split(separator: "@")
    images.append(["filename": "\(entry.name).png", "idiom": "mac", "scale": parts.count > 1 ? "2x" : "1x", "size": String(parts[0])])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(output)/Contents.json"))
print("Wrote \(sizes.count) icons to \(output)")
