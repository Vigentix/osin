import AppKit
import OsinCore
import SwiftUI

/// Menu bar glyph with a health-coloured dot, plus optional live metrics chosen in Settings.
struct MenuBarLabel: View {
    /// Read here, not passed in: the App's body then does not depend on every sample, and the label
    /// only reads `snapshot` when live metrics are shown (otherwise just the rarely changing level).
    let monitor: SystemMonitor
    let keepAwake: KeepAwakeController
    @AppStorage(Preferences.Key.menuBarCPU) private var showCPU = false
    @AppStorage(Preferences.Key.menuBarMemory) private var showMemory = false
    @AppStorage(Preferences.Key.menuBarNetwork) private var showNetwork = false
    @Environment(\.openWindow) private var openWindow

    private var level: HealthLevel? {
        monitor.healthLevel
    }

    private var keepingAwake: Bool {
        keepAwake.isActive
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(for: level))
            if keepingAwake {
                Image(systemName: "cup.and.saucer.fill")
            }
            if let text = metricsText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // The label lives as long as the app, so it can open the dashboard for notification clicks.
        .onReceive(NotificationCenter.default.publisher(for: .osinOpenDashboard)) { _ in
            openWindow(id: WindowID.dashboard)
            NSApp.activate()
            WindowFront.bringDashboardToFront()
        }
    }

    private var metricsText: String? {
        guard showCPU || showMemory || showNetwork, let snapshot = monitor.snapshot else { return nil }
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
        let health = level.map { Text("Osin, health \(String(localized: $0.title))") } ?? Text("Osin")
        return keepingAwake ? Text("\(health), keeping awake") : health
    }
}

enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 18)

    /// The Osin mark: a ring with a gap at the top right and the health dot inside the gap.
    /// Drawn with `labelColor` inside a drawing handler so it follows the menu bar appearance;
    /// not a template image because the dot keeps its colour.
    /// One image per health level, drawn once.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(for level: HealthLevel?) -> NSImage {
        let key = level.map { "\($0)" } ?? "none"
        if let cached = cache[key] {
            return cached
        }
        let image = image(dot: level.map { NSColor($0.color) })
        cache[key] = image
        return image
    }

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
