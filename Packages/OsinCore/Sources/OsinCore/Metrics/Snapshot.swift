import Foundation

public struct CPUSnapshot: Sendable, Equatable {
    /// Busy fraction across all cores (0...1).
    public let total: Double
    public let perCore: [Double]
    /// Average of performance cores; `nil` on Intel.
    public let performance: Double?
    /// Average of efficiency cores; `nil` on Intel.
    public let efficiency: Double?
    public let loadAverage: Double
}

public struct DiskSnapshot: Sendable, Equatable {
    public let totalBytes: UInt64
    /// Includes purgeable space, as Finder reports it.
    public let availableBytes: UInt64
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : 1 - Double(availableBytes) / Double(totalBytes)
    }
}

public struct BatterySnapshot: Sendable, Equatable {
    public let chargeFraction: Double
    public let isCharging: Bool
    public let isOnACPower: Bool
    /// Full-charge vs design capacity (0...1), when known.
    public let health: Double?
    public let cycleCount: Int?
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let receiveBytesPerSecond: Double
    public let sendBytesPerSecond: Double
}

/// Everything Osin knows about the machine at one moment.
public struct SystemSnapshot: Sendable, Equatable {
    public let date: Date
    public let cpu: CPUSnapshot
    public let memory: MemoryStats
    public let disk: DiskSnapshot
    public let battery: BatterySnapshot?
    public let network: NetworkSnapshot
    public let thermal: ThermalLevel
    public let topByMemory: [ProcessGroup]
    public let topByCPU: [ProcessGroup]
    public let health: HealthReport
}
