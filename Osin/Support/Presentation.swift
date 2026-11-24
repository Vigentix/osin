import OsinCore
import SwiftUI
import SystemConfiguration

enum Brand {
    /// #6352E0, the accent chosen in the mockups.
    static let accent = Color(red: 0x63 / 255, green: 0x52 / 255, blue: 0xE0 / 255)
}

enum MachineInfo {
    /// The user-visible computer name. `Host.current()` can block on DNS, so it is avoided.
    static let computerName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
}

enum Format {
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func storage(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file)
        return String(localized: "\(bytes)/s")
    }

    /// CPU share where 1.0 is one full core, so values above 100% are expected for multi-threaded apps.
    static func cpuShare(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension HealthLevel {
    var color: Color {
        switch self {
        case .good: .green
        case .fair: .orange
        case .poor: .red
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
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

extension HealthComponent {
    /// One-line headline used when this component is the main reason for a low score.
    var concernTitle: LocalizedStringResource {
        switch self {
        case .disk: "Disk almost full"
        case .memory: "Memory under pressure"
        case .cpu: "CPU busy for a while"
        case .thermal: "Mac is running hot"
        case .battery: "Battery is wearing out"
        }
    }
}
