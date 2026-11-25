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
    private static let size = NSSize(width: 18, height: 18)

    /// The Osin mark: a ring with a gap at the top right and the health dot inside the gap.
    /// Drawn with `labelColor` inside a drawing handler so it follows the menu bar appearance;
    /// not a template image because the dot keeps its colour.
    static func image(dot: NSColor?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.2
            let ring = NSBezierPath()
            // Gap of 65° centred on 45° (top right); angles are counter-clockwise from 3 o'clock.
            ring.appendArc(withCenter: center, radius: radius, startAngle: 77.5, endAngle: 372.5, clockwise: false)
            ring.lineWidth = 2.3
            ring.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            ring.stroke()
            if let dot {
                let dotCenter = NSPoint(x: center.x + radius * 0.707, y: center.y + radius * 0.707)
                let diameter: CGFloat = 5.4
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: dotCenter.x - diameter / 2,
                    y: dotCenter.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
