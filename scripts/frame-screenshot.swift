// Frames raw screenshots for the README: rounded window corners, a hairline border and a soft
// drop shadow on a transparent canvas, so they sit well on GitHub's light and dark themes.
//
// Usage: swift scripts/frame-screenshot.swift <input dir> <output dir> <name>...
// Reads <input dir>/<name>.png (2x renders from `--render-snapshots`), writes <output dir>/<name>.png.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: frame-screenshot.swift <input dir> <output dir> <name>...\n".utf8))
    exit(64)
}

let input = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for name in arguments[3...] {
    let source = input.appendingPathComponent("\(name).png")
    guard let image = NSImage(contentsOf: source), let rep = image.representations.first else {
        FileHandle.standardError.write(Data("missing \(source.path)\n".utf8))
        exit(1)
    }
    let width = CGFloat(rep.pixelsWide)
    let height = CGFloat(rep.pixelsHigh)
    let isDark = name.hasSuffix("-dark")
    // Pixel values at 2x: the popover has smaller corners than a window.
    let radius: CGFloat = name.hasPrefix("popover") ? 28 : 34
    let blur: CGFloat = 56
    let margin: CGFloat = 72

    let canvas = NSSize(width: width + margin * 2, height: height + margin * 2)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width),
        pixelsHigh: Int(canvas.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { exit(1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let frame = NSRect(x: margin, y: margin, width: width, height: height)
    let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

    // Shadow, drawn with the window shape so it follows the corners.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.22)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Content, clipped to the rounded shape.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    image.draw(in: frame, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline border, like a macOS window edge.
    let inset = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
    inset.lineWidth = 2
    (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.14)).setStroke()
    inset.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: output.appendingPathComponent("\(name).png"))
    print("framed \(name).png")
}
