/// One process measured over a sampling interval.
public struct ProcessRecord: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?
    /// Physical footprint (`ri_phys_footprint`), the figure Activity Monitor calls "Memory".
    public let footprintBytes: UInt64
    /// Share of one CPU core over the interval (1.0 = one full core).
    public let cpuFraction: Double

    public init(pid: Int32, name: String, executablePath: String?, footprintBytes: UInt64, cpuFraction: Double) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.footprintBytes = footprintBytes
        self.cpuFraction = cpuFraction
    }
}

/// Processes that belong to the same app (main process plus helpers), or a single non-app process.
public struct ProcessGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Outermost `.app` bundle, when the process lives inside one.
    public let bundlePath: String?
    public let pids: [Int32]
    public let footprintBytes: UInt64
    public let cpuFraction: Double
}

public enum ProcessGrouping {
    public enum Metric: Sendable {
        case memory
        case cpu
    }

    /// The outermost `.app` bundle containing an executable, so helpers group with their app.
    public static func appBundlePath(forExecutable path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    public static func group(_ records: [ProcessRecord]) -> [ProcessGroup] {
        var buckets: [String: [ProcessRecord]] = [:]
        var order: [String] = []
        for record in records {
            let key = appBundlePath(forExecutable: record.executablePath) ?? "pid:\(record.pid)"
            if buckets[key] == nil {
                order.append(key)
            }
            buckets[key, default: []].append(record)
        }
        return order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            let bundle = appBundlePath(forExecutable: first.executablePath)
            let name = bundle.map(displayName(forBundle:))
                ?? first.executablePath?.split(separator: "/").last.map(String.init)
                ?? first.name
            return ProcessGroup(
                id: key,
                name: name,
                bundlePath: bundle,
                pids: members.map(\.pid).sorted(),
                footprintBytes: members.reduce(0) { $0 + $1.footprintBytes },
                cpuFraction: members.reduce(0) { $0 + $1.cpuFraction }
            )
        }
    }

    public static func top(_ groups: [ProcessGroup], by metric: Metric, limit: Int) -> [ProcessGroup] {
        let sorted = switch metric {
        case .memory: groups.sorted { $0.footprintBytes > $1.footprintBytes }
        case .cpu: groups.sorted { $0.cpuFraction > $1.cpuFraction }
        }
        return Array(sorted.prefix(limit))
    }

    private static func displayName(forBundle path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
