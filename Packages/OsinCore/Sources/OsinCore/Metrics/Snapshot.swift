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

    public init(
        total: Double,
        perCore: [Double],
        performance: Double?,
        efficiency: Double?,
        loadAverage: Double
    ) {
        self.total = total
        self.perCore = perCore
        self.performance = performance
        self.efficiency = efficiency
        self.loadAverage = loadAverage
    }
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

    public init(
        totalBytes: UInt64,
        availableBytes: UInt64,
        readBytesPerSecond: Double,
        writeBytesPerSecond: Double
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct BatterySnapshot: Sendable, Equatable {
    public let chargeFraction: Double
    public let isCharging: Bool
    public let isOnACPower: Bool
    /// Full-charge vs design capacity (0...1), when known.
    public let health: Double?
    public let cycleCount: Int?

    public init(
        chargeFraction: Double,
        isCharging: Bool,
        isOnACPower: Bool,
        health: Double?,
        cycleCount: Int?
    ) {
        self.chargeFraction = chargeFraction
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.health = health
        self.cycleCount = cycleCount
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let receiveBytesPerSecond: Double
    public let sendBytesPerSecond: Double

    public init(
        receiveBytesPerSecond: Double,
        sendBytesPerSecond: Double
    ) {
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.sendBytesPerSecond = sendBytesPerSecond
    }
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
    /// Every readable process group, largest memory footprint first.
    public let processes: [ProcessGroup]
    public let topByMemory: [ProcessGroup]
    public let topByCPU: [ProcessGroup]
    public let health: HealthReport

    public init(
        date: Date,
        cpu: CPUSnapshot,
        memory: MemoryStats,
        disk: DiskSnapshot,
        battery: BatterySnapshot?,
        network: NetworkSnapshot,
        thermal: ThermalLevel,
        processes: [ProcessGroup],
        topByMemory: [ProcessGroup],
        topByCPU: [ProcessGroup],
        health: HealthReport
    ) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.battery = battery
        self.network = network
        self.thermal = thermal
        self.processes = processes
        self.topByMemory = topByMemory
        self.topByCPU = topByCPU
        self.health = health
    }
}
