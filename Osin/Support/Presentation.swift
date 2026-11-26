import OsinCore
import SwiftUI
import SystemConfiguration

enum MachineInfo {
    /// The user-visible computer name. `Host.current()` can block on DNS, so it is avoided.
    static let computerName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"

    /// The startup disk's name as Finder shows it ("Macintosh HD" unless renamed).
    static let bootVolumeName: String = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?
        .volumeLocalizedName ?? "Macintosh HD"

    /// "Apple M1 · 8 cores · 16 GB · macOS 26.6"
    static let summary: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let chip = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let memory = ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory)
        let system = "macOS \(version.majorVersion).\(version.minorVersion)"
        return [chip, String(localized: "\(info.processorCount) cores"), memory, system].filter { !$0.isEmpty }.joined(separator: " · ")
    }()
}

enum Format {
    /// "0 KB" rather than ByteCountFormatter's default "Zero KB".
    private static func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func memory(_ value: UInt64) -> String {
        bytes(Int64(clamping: value), style: .memory)
    }

    static func storage(_ value: UInt64) -> String {
        bytes(Int64(clamping: value), style: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let amount = bytes(Int64(bytesPerSecond.rounded()), style: .file)
        return String(localized: "\(amount)/s")
    }

    /// CPU share where 1.0 is one full core, so values above 100% are expected for multi-threaded apps.
    static func cpuShare(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
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

extension CleanupFailure {
    /// The reason in the user's language. System errors already come localized from macOS.
    var localizedReason: String {
        switch kind {
        case .deleteNotAllowed: String(localized: "This rule is not allowed to delete permanently.")
        case .symbolicLink: String(localized: "The item is a symbolic link.")
        case .throughSymbolicLink: String(localized: "The path goes through a symbolic link.")
        case .outsideHome: String(localized: "The item is outside your home folder.")
        case .protectedLocation: String(localized: "The item is in a protected location.")
        case .changedSinceScan: String(localized: "The item changed since the scan. Scan again to include it.")
        case .usedRecently: String(localized: "The item was used recently, so it was kept.")
        case .logUnavailable: String(localized: "Osin could not write its cleanup log, so nothing was removed.")
        case .couldNotCheckAge: String(localized: "Part of the item could not be read, so Osin could not confirm it is old. It was kept.")
        case .originalExists: String(localized: "Something already exists at the original location.")
        case .notTheTrashedItem: String(localized: "The item in the Trash is not the one Osin moved there.")
        case let .system(message): message
        }
    }
}
