import AppKit
import OsinCore
import SwiftUI

/// Menu bar glyph with a health-coloured dot.
struct MenuBarLabel: View {
    let level: HealthLevel?

    var body: some View {
        Image(nsImage: MenuBarIcon.image(dot: level.map { NSColor($0.color) }))
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        guard let level else { return Text("Osin") }
        return Text("Osin, health \(String(localized: level.title))")
    }
}

enum MenuBarIcon {
    private static let size = NSSize(width: 22, height: 18)

    /// The glyph is drawn with `labelColor` inside a drawing handler, so it resolves against the
    /// menu bar's appearance at draw time. The image is not a template because the dot keeps its colour.
    static func image(dot: NSColor?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(.init(paletteColors: [.labelColor]))
            if let glyph = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let origin = NSPoint(x: 1, y: (rect.height - glyph.size.height) / 2)
                glyph.draw(in: NSRect(origin: origin, size: glyph.size))
            }
            if let dot {
                let diameter: CGFloat = 6
                let dotRect = NSRect(x: rect.maxX - diameter - 0.5, y: 1.5, width: diameter, height: diameter)
                dot.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
