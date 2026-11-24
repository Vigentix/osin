import Foundation

/// Thermal state, mirroring `ProcessInfo.ThermalState`.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum HealthComponent: String, Sendable, CaseIterable {
    case disk
    case memory
    case cpu
    case thermal
    case battery
}

public enum HealthLevel: Sendable, Equatable {
    case good
    case fair
    case poor

    public init(score: Int) {
        switch score {
        case 80...: self = .good
        case 60 ..< 80: self = .fair
        default: self = .poor
        }
    }
}

/// What the score is computed from. Built by the sampler from a snapshot plus recent history.
public struct HealthInputs: Sendable, Equatable {
    public var diskFreeFraction: Double
    public var memoryPressure: MemoryPressure
    public var swapUsedBytes: UInt64
    public var physicalMemoryBytes: UInt64
    /// Average CPU busy fraction over the last few minutes.
    public var sustainedCPU: Double
    public var thermal: ThermalLevel
    /// `nil` on Macs without a battery.
    public var batteryHealth: Double?

    public init(
        diskFreeFraction: Double,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        physicalMemoryBytes: UInt64,
        sustainedCPU: Double,
        thermal: ThermalLevel,
        batteryHealth: Double?
    ) {
        self.diskFreeFraction = diskFreeFraction
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.sustainedCPU = sustainedCPU
        self.thermal = thermal
        self.batteryHealth = batteryHealth
    }
}

/// Weights and thresholds. Values are a first guess, to be tuned with real use (PRD §6.2).
public struct HealthConfig: Sendable, Equatable {
    public var diskWeight = 30.0
    public var diskOKFreeFraction = 0.20
    public var diskCriticalFreeFraction = 0.05

    public var memoryWeight = 30.0
    public var memoryWarningPenalty = 0.5
    public var memoryCriticalPenalty = 1.0
    /// Penalty added per unit of swap-to-RAM ratio.
    public var swapPenaltyPerRAMRatio = 1.0

    public var cpuWeight = 15.0
    public var cpuOKFraction = 0.70
    public var cpuCriticalFraction = 1.0

    public var thermalWeight = 10.0
    public var thermalPenalties: [ThermalLevel: Double] = [.nominal: 0, .fair: 0.3, .serious: 0.7, .critical: 1]

    public var batteryWeight = 15.0
    public var batteryOKHealth = 0.90
    public var batteryCriticalHealth = 0.60

    public init() {}
}

public struct HealthReport: Sendable, Equatable {
    public let score: Int
    public let level: HealthLevel
    /// Points lost per component, unrounded. Components that do not apply are absent.
    public let exactDeductions: [HealthComponent: Double]

    /// Points lost per component, rounded for display.
    public var deductions: [HealthComponent: Int] {
        exactDeductions.mapValues { Int($0.rounded()) }
    }

    /// Deductions smaller than this are not worth headlining.
    public static let concernThreshold = 5.0

    /// The component costing the most points, when it costs at least `concernThreshold`.
    public var primaryConcern: HealthComponent? {
        guard let worst = exactDeductions.max(by: { $0.value < $1.value }), worst.value >= Self.concernThreshold else {
            return nil
        }
        return worst.key
    }
}

public enum HealthScore {
    public static func evaluate(_ inputs: HealthInputs, config: HealthConfig = HealthConfig()) -> HealthReport {
        var penalties: [HealthComponent: (weight: Double, penalty: Double)] = [
            .disk: (
                config.diskWeight,
                ramp(inputs.diskFreeFraction, ok: config.diskOKFreeFraction, critical: config.diskCriticalFreeFraction)
            ),
            .memory: (config.memoryWeight, memoryPenalty(inputs, config: config)),
            .cpu: (config.cpuWeight, ramp(inputs.sustainedCPU, ok: config.cpuOKFraction, critical: config.cpuCriticalFraction)),
            .thermal: (config.thermalWeight, config.thermalPenalties[inputs.thermal] ?? 0)
        ]
        if let battery = inputs.batteryHealth {
            penalties[.battery] = (config.batteryWeight, ramp(battery, ok: config.batteryOKHealth, critical: config.batteryCriticalHealth))
        }

        let totalWeight = penalties.values.reduce(0) { $0 + $1.weight }
        let deductions = penalties.mapValues { 100 * $0.weight * $0.penalty / totalWeight }
        let score = Int((100 - deductions.values.reduce(0, +)).rounded())
        let clamped = min(100, max(0, score))
        return HealthReport(score: clamped, level: HealthLevel(score: clamped), exactDeductions: deductions)
    }

    private static func memoryPenalty(_ inputs: HealthInputs, config: HealthConfig) -> Double {
        let pressure = switch inputs.memoryPressure {
        case .normal: 0.0
        case .warning: config.memoryWarningPenalty
        case .critical: config.memoryCriticalPenalty
        }
        let swapRatio = inputs.physicalMemoryBytes == 0 ? 0 : Double(inputs.swapUsedBytes) / Double(inputs.physicalMemoryBytes)
        return min(1, pressure + swapRatio * config.swapPenaltyPerRAMRatio)
    }

    /// 0 at `ok`, 1 at `critical`, linear between. Works whether higher or lower values are better.
    private static func ramp(_ value: Double, ok: Double, critical: Double) -> Double {
        guard ok != critical else { return value == ok ? 0 : 1 }
        return min(1, max(0, (value - ok) / (critical - ok)))
    }
}
