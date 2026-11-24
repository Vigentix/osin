import AppKit
import OsinCore
import SwiftUI

/// Menu bar glyph with a health-coloured dot, plus optional live metrics chosen in Settings.
struct MenuBarLabel: View {
    let snapshot: SystemSnapshot?
    @AppStorage(Preferences.Key.menuBarCPU) private var showCPU = false
    @AppStorage(Preferences.Key.menuBarMemory) private var showMemory = false
    @AppStorage(Preferences.Key.menuBarNetwork) private var showNetwork = false

    private var level: HealthLevel? {
        snapshot?.health.level
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(dot: level.map { NSColor($0.color) }))
            if let text = metricsText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var metricsText: String? {
        guard let snapshot else { return nil }
        var parts: [String] = []
        if showCPU {
            parts.append("CPU \(Format.percent(snapshot.cpu.total))")
        }
        if showMemory {
            parts.append(String(localized: snapshot.memory.pressure.title))
        }
        if showNetwork {
            parts.append("↓\(Format.rate(snapshot.network.receiveBytesPerSecond))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
