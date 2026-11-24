/// Converts cumulative byte counters into a per-second rate.
public enum Throughput {
    /// Bytes per second between two counter readings.
    /// A counter that went backwards (interface reset, disk ejected) yields 0 rather than a spike.
    public static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }
}
