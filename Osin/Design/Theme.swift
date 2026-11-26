import AppKit
import OsinCore
import SwiftUI

/// Design tokens from the v2 mockups. Every colour resolves for light and dark appearance.
enum Theme {
    // Surfaces
    static let background = Color(light: 0xF5F6F8, dark: 0x0E0F13)
    static let surface = Color(light: 0xFFFFFF, dark: 0x16181F)
    static let sidebar = Color(light: 0xECEDF1, dark: 0x111217)
    static let raised = Color(light: 0xF3F4F7, dark: 0x1C1F27)
    static let control = Color(light: 0xE5E7EB, dark: 0x2A2D37)
    static let border = Color(light: 0x0F1115, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let borderStrong = Color(light: 0x0F1115, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.12)
    /// Fill under a hovered row or ghost button.
    static let hover = Color(light: 0x0F1115, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.055)
    static let borderHover = Color(light: 0x0F1115, lightAlpha: 0.22, dark: 0xFFFFFF, darkAlpha: 0.22)
    static let track = Color(light: 0x0F1115, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.07)

    // Text
    static let text = Color(light: 0x0F1115, dark: 0xECEEF3)
    static let text2 = Color(light: 0x5B6170, dark: 0xA3A8B5)
    static let text3 = Color(light: 0x5B6170, dark: 0x7C8291)

    /// Brand
    /// Rings, charts and icons.
    static let accent = Color(light: 0x5B4BE8, dark: 0x7C6CFF)
    /// Filled buttons; white text on it passes WCAG AA in both modes.
    static let accentButton = Color(light: 0x5B4BE8, dark: 0x6B5AF7)
    static let accentText = Color(light: 0x4B3BD8, dark: 0xA99FFF)
    static let accentSoft = Color(light: 0x5B4BE8, lightAlpha: 0.12, dark: 0x7C6CFF, darkAlpha: 0.16)

    // Status: fills for marks, text variants for small type
    static let good = Color(light: 0x059669, dark: 0x34D399)
    static let goodText = Color(light: 0x047857, dark: 0x6EE7B7)
    static let fair = Color(light: 0xD97706, dark: 0xFBBF24)
    static let fairText = Color(light: 0x92400E, dark: 0xFCD34D)
    static let poor = Color(light: 0xDC2626, dark: 0xF87171)
    static let poorText = Color(light: 0xB91C1C, dark: 0xFCA5A5)

    // Data series
    static let teal = Color(light: 0x0D9488, dark: 0x2DD4BF)
    static let blue = Color(light: 0x2563EB, dark: 0x4F8CFF)
    static let neutralSeries = Color(light: 0xCBD0D8, dark: 0x3A3F4B)

    // Shape
    static let cardRadius: CGFloat = 14
    static let heroRadius: CGFloat = 18
}

extension Color {
    /// A colour that follows the current appearance.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension HealthLevel {
    var color: Color {
        switch self {
        case .good: Theme.good
        case .fair: Theme.fair
        case .poor: Theme.poor
        }
    }

    var textColor: Color {
        switch self {
        case .good: Theme.goodText
        case .fair: Theme.fairText
        case .poor: Theme.poorText
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    var eyebrow: LocalizedStringResource {
        switch self {
        case .good: "ALL GOOD"
        case .fair: "WORTH A LOOK"
        case .poor: "NEEDS ATTENTION"
        }
    }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: Theme.good
        case .warning: Theme.fair
        case .critical: Theme.poor
        }
    }

    var textColor: Color {
        switch self {
        case .normal: Theme.goodText
        case .warning: Theme.fairText
        case .critical: Theme.poorText
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Disk fullness bands shared by every screen.
enum DiskLevel {
    case ok
    case low
    case critical

    init(_ disk: DiskSnapshot) {
        self.init(freeFraction: 1 - disk.usedFraction)
    }

    init(freeFraction free: Double) {
        self = free < 0.05 ? .critical : (free < 0.20 ? .low : .ok)
    }

    var color: Color {
        switch self {
        case .ok: Theme.good
        case .low: Theme.fair
        case .critical: Theme.poor
        }
    }

    var textColor: Color {
        switch self {
        case .ok: Theme.text
        case .low: Theme.fairText
        case .critical: Theme.poorText
        }
    }
}

extension HealthComponent {
    var title: LocalizedStringResource {
        switch self {
        case .disk: "disk"
        case .memory: "memory & swap"
        case .cpu: "CPU"
        case .thermal: "thermal"
        case .battery: "battery"
        }
    }
}
