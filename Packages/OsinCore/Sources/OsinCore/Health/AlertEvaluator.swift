import Foundation

public struct AlertSettings: Sendable, Equatable {
    public var enabled: Bool
    /// Alert when free disk space falls below this fraction.
    public var diskFreeThreshold: Double
    public var memoryPressureEnabled: Bool
    public var batteryHealthEnabled: Bool
    /// Alert when battery health falls below this fraction.
    public var batteryHealthThreshold: Double

    public init(
        enabled: Bool = true,
        diskFreeThreshold: Double = 0.10,
        memoryPressureEnabled: Bool = true,
        batteryHealthEnabled: Bool = true,
        batteryHealthThreshold: Double = 0.80
    ) {
        self.enabled = enabled
        self.diskFreeThreshold = diskFreeThreshold
        self.memoryPressureEnabled = memoryPressureEnabled
        self.batteryHealthEnabled = batteryHealthEnabled
        self.batteryHealthThreshold = batteryHealthThreshold
    }
}

/// The inputs alerts look at, taken from a snapshot.
public struct AlertReading: Sendable {
    public let diskFreeFraction: Double
    public let freeBytes: UInt64
    public let memoryPressure: MemoryPressure
    public let batteryHealth: Double?

    public init(diskFreeFraction: Double, freeBytes: UInt64, memoryPressure: MemoryPressure, batteryHealth: Double?) {
        self.diskFreeFraction = diskFreeFraction
        self.freeBytes = freeBytes
        self.memoryPressure = memoryPressure
        self.batteryHealth = batteryHealth
    }

    public init(snapshot: SystemSnapshot) {
        self.init(
            diskFreeFraction: 1 - snapshot.disk.usedFraction,
            freeBytes: snapshot.disk.availableBytes,
            memoryPressure: snapshot.memory.pressure,
            batteryHealth: snapshot.battery?.health
        )
    }
}

public struct HealthAlert: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case lowDisk
        case memoryPressure
        case batteryHealth
    }

    public let kind: Kind
    public let reading: Double
}

/// Decides when to notify (PRD §6.9). Pure: feed it readings and times, it returns alerts to post.
public struct AlertEvaluator: Sendable {
    public static let cooldowns: [HealthAlert.Kind: TimeInterval] = [
        .lowDisk: 86400,
        .memoryPressure: 6 * 3600,
        .batteryHealth: 30 * 86400
    ]
    /// Critical memory pressure must last this long before alerting.
    public static let memorySustain: TimeInterval = 60

    public var settings: AlertSettings
    private var lastAlert: [HealthAlert.Kind: Date] = [:]
    private var criticalSince: Date?

    public init(settings: AlertSettings) {
        self.settings = settings
    }

    public mutating func evaluate(_ reading: AlertReading, at now: Date) -> [HealthAlert] {
        if reading.memoryPressure == .critical {
            criticalSince = criticalSince ?? now
        } else {
            criticalSince = nil
        }
        guard settings.enabled else { return [] }

        var alerts: [HealthAlert] = []
        if reading.diskFreeFraction < settings.diskFreeThreshold {
            fire(.lowDisk, value: reading.diskFreeFraction, at: now, into: &alerts)
        }
        if settings.memoryPressureEnabled, let since = criticalSince, now.timeIntervalSince(since) >= Self.memorySustain {
            fire(.memoryPressure, value: 1, at: now, into: &alerts)
        }
        if settings.batteryHealthEnabled, let health = reading.batteryHealth, health < settings.batteryHealthThreshold {
            fire(.batteryHealth, value: health, at: now, into: &alerts)
        }
        return alerts
    }

    private mutating func fire(_ kind: HealthAlert.Kind, value: Double, at now: Date, into alerts: inout [HealthAlert]) {
        if let last = lastAlert[kind], now.timeIntervalSince(last) < Self.cooldowns[kind, default: 86400] {
            return
        }
        lastAlert[kind] = now
        alerts.append(HealthAlert(kind: kind, reading: value))
    }
}
