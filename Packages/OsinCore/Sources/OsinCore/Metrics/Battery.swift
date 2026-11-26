import Foundation

/// Battery health from the `AppleSmartBattery` IORegistry entry.
public enum BatteryHealth {
    /// Full-charge capacity as a fraction of design capacity (0...1), or `nil` when unknown.
    ///
    /// Apple does not publish the formula behind System Settings' "Maximum Capacity", so this is
    /// an approximation: `NominalChargeCapacity`, then `AppleRawMaxCapacity` (Apple Silicon),
    /// then `MaxCapacity` when it is in mAh (Intel; on Apple Silicon it is a percentage).
    public static func fraction(fromRegistry props: [String: Any]) -> Double? {
        guard let design = number(props["DesignCapacity"]), design > 0 else { return nil }
        let full: Double
        if let nominal = number(props["NominalChargeCapacity"]), nominal > 0 {
            full = nominal
        } else if let raw = number(props["AppleRawMaxCapacity"]), raw > 0 {
            full = raw
        } else if let max = number(props["MaxCapacity"]), max > 100 {
            full = max
        } else {
            return nil
        }
        return min(1, full / design)
    }

    /// "Maximum Capacity" exactly as System Settings shows it, from `system_profiler SPPowerDataType -json`.
    public static func maximumCapacity(fromSystemProfilerJSON data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }
        for section in sections {
            guard let info = section["sppower_battery_health_info"] as? [String: Any],
                  let text = info["sppower_battery_health_maximum_capacity"] as? String,
                  let percent = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
            else { continue }
            return min(1, max(0, percent / 100))
        }
        return nil
    }

    /// Runs `system_profiler` (about 0.3 s). Call rarely; health changes over weeks.
    public static func systemReported() async -> Double? {
        guard let data = try? await ProcessRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]) else { return nil }
        return maximumCapacity(fromSystemProfilerJSON: data)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let int as Int: Double(int)
        case let double as Double: double
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }
}
