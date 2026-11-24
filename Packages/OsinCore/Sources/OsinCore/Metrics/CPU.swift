/// Cumulative tick counters for one logical CPU, as reported by `host_processor_info`.
/// Counters are 32-bit and wrap around; deltas use wrapping subtraction.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU usage derived from two tick snapshots.
public enum CPUUsage {
    /// Busy fraction (0...1) per logical CPU. Empty when the snapshots have different core counts.
    public static func perCore(previous: [CPUTicks], current: [CPUTicks]) -> [Double] {
        guard previous.count == current.count else { return [] }
        return zip(previous, current).map { before, after in
            let delta = Delta(before, after)
            return delta.total == 0 ? 0 : Double(delta.busy) / Double(delta.total)
        }
    }

    /// Busy fraction (0...1) across all CPUs, weighted by elapsed ticks.
    public static func total(previous: [CPUTicks], current: [CPUTicks]) -> Double? {
        guard previous.count == current.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (before, after) in zip(previous, current) {
            let delta = Delta(before, after)
            busy += delta.busy
            total += delta.total
        }
        return total == 0 ? 0 : Double(busy) / Double(total)
    }

    private struct Delta {
        let busy: UInt64
        let total: UInt64

        init(_ before: CPUTicks, _ after: CPUTicks) {
            let user = UInt64(after.user &- before.user)
            let system = UInt64(after.system &- before.system)
            let nice = UInt64(after.nice &- before.nice)
            let idle = UInt64(after.idle &- before.idle)
            busy = user + system + nice
            total = busy + idle
        }
    }
}

/// Performance / efficiency core layout on Apple Silicon.
///
/// Assumes the kernel numbers efficiency cores first, which holds for M1–M4.
public struct CoreTopology: Sendable, Equatable {
    public let efficiency: Range<Int>
    public let performance: Range<Int>

    public init?(logicalCPUs: Int, performanceCPUs: Int, efficiencyCPUs: Int) {
        guard performanceCPUs > 0, efficiencyCPUs > 0, performanceCPUs + efficiencyCPUs == logicalCPUs else {
            return nil
        }
        efficiency = 0 ..< efficiencyCPUs
        performance = efficiencyCPUs ..< logicalCPUs
    }

    public func averageEfficiency(_ perCore: [Double]) -> Double {
        Self.average(perCore, in: efficiency)
    }

    public func averagePerformance(_ perCore: [Double]) -> Double {
        Self.average(perCore, in: performance)
    }

    private static func average(_ values: [Double], in range: Range<Int>) -> Double {
        let slice = range.clamped(to: values.indices).map { values[$0] }
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0, +) / Double(slice.count)
    }
}
