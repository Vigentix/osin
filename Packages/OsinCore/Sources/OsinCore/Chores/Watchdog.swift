import Foundation

/// What the watchdog looks for. Thresholds are per app; CPU is a share of one core (1.0 = one full core).
public struct WatchdogSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var cpuThreshold: Double
    public var cpuMinutes: Double
    public var memoryGrowthBytes: UInt64
    public var memoryWindowMinutes: Double
    /// Bundle paths of apps the user asked never to be told about.
    public var ignoredApps: Set<String>

    public init(
        enabled: Bool = true,
        cpuThreshold: Double = 0.8,
        cpuMinutes: Double = 5,
        memoryGrowthBytes: UInt64 = 2_000_000_000,
        memoryWindowMinutes: Double = 30,
        ignoredApps: Set<String> = []
    ) {
        self.enabled = enabled
        self.cpuThreshold = cpuThreshold
        self.cpuMinutes = cpuMinutes
        self.memoryGrowthBytes = memoryGrowthBytes
        self.memoryWindowMinutes = memoryWindowMinutes
        self.ignoredApps = ignoredApps
    }
}

public struct WatchdogAlert: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case highCPU
        case memoryGrowth
    }

    public let kind: Kind
    public let name: String
    public let bundlePath: String
    /// CPU share for `.highCPU`, bytes gained for `.memoryGrowth`.
    public let value: Double
}

/// Watches apps over time and reports ones that stay busy or keep growing. Pure: feed it samples.
public struct Watchdog: Sendable {
    public var settings: WatchdogSettings
    /// When each app and kind last alerted ("bundlePath|kind"). Persist it so a relaunch stays quiet.
    public private(set) var lastAlerts: [String: Date]
    public static let cooldown: TimeInterval = 86400
    static let footprintSpacing: TimeInterval = 25

    private struct Track {
        var busySince: Date?
        var footprints: [(date: Date, bytes: UInt64)] = []
    }

    private var tracks: [String: Track] = [:]
    private var lastEvaluation: Date?
    /// Background samples come every 30 s (up to 35 s with timer tolerance).
    static let maxGap: TimeInterval = 90

    public init(settings: WatchdogSettings, lastAlerts: [String: Date] = [:]) {
        self.settings = settings
        self.lastAlerts = lastAlerts
    }

    /// Evaluates one sample. Only apps are watched (system processes are not offered for quitting),
    /// minus ignored apps and processes in `excluding` (e.g. the one Keep Awake is waiting for).
    public mutating func evaluate(_ groups: [ProcessGroup], at now: Date, excluding pids: Set<Int32> = []) -> [WatchdogAlert] {
        guard settings.enabled else {
            tracks = [:]
            return []
        }
        // A gap (sleep, or Osin not running) breaks every streak: only time actually observed counts.
        if let lastEvaluation, now.timeIntervalSince(lastEvaluation) > Self.maxGap {
            tracks = [:]
        }
        lastEvaluation = now
        var alerts: [WatchdogAlert] = []
        var seen: Set<String> = []
        for group in groups {
            guard let bundle = group.bundlePath, !settings.ignoredApps.contains(bundle), pids.isDisjoint(with: group.pids) else { continue }
            seen.insert(bundle)
            var track = tracks[bundle] ?? Track()

            if group.cpuFraction >= settings.cpuThreshold {
                track.busySince = track.busySince ?? now
            } else {
                track.busySince = nil
            }
            if let since = track.busySince, now.timeIntervalSince(since) >= settings.cpuMinutes * 60, let alert = fire(
                .highCPU,
                group: group,
                bundle: bundle,
                value: group.cpuFraction,
                at: now
            ) {
                alerts.append(alert)
            }

            let window = settings.memoryWindowMinutes * 60
            // One footprint every ~30 s is enough for a 30-minute trend (samples come every 2 s while
            // a window is open).
            if track.footprints.last.map({ now.timeIntervalSince($0.date) >= Self.footprintSpacing }) ?? true {
                track.footprints.append((now, group.footprintBytes))
            }
            track.footprints.removeAll { now.timeIntervalSince($0.date) > window }
            if let oldest = track.footprints.first, now.timeIntervalSince(oldest.date) >= window * 0.9 {
                let peak = track.footprints.map(\.bytes).max() ?? 0
                let gained = group.footprintBytes > oldest.bytes ? group.footprintBytes - oldest.bytes : 0
                // Steady growth: up by the threshold and still at (or near) its highest point.
                if gained >= settings.memoryGrowthBytes, Double(group.footprintBytes) >= Double(peak) * 0.95, let alert = fire(
                    .memoryGrowth,
                    group: group,
                    bundle: bundle,
                    value: Double(gained),
                    at: now
                ) {
                    alerts.append(alert)
                }
            }
            tracks[bundle] = track
        }
        tracks = tracks.filter { seen.contains($0.key) }
        return alerts
    }

    /// The alert to send, or `nil` while this app and kind are cooling down.
    private mutating func fire(
        _ kind: WatchdogAlert.Kind,
        group: ProcessGroup,
        bundle: String,
        value: Double,
        at now: Date
    ) -> WatchdogAlert? {
        let key = "\(bundle)|\(kind.rawValue)"
        if let last = lastAlerts[key], now.timeIntervalSince(last) < Self.cooldown {
            return nil
        }
        lastAlerts[key] = now
        return WatchdogAlert(kind: kind, name: group.name, bundlePath: bundle, value: value)
    }

    /// Undoes cooldowns started at `firedAt` for alerts that could not be shown.
    public mutating func restoreCooldowns(for alerts: [WatchdogAlert], firedAt: Date, previous: [String: Date]) {
        for alert in alerts {
            let key = "\(alert.bundlePath)|\(alert.kind.rawValue)"
            if lastAlerts[key] == firedAt {
                lastAlerts[key] = previous[key]
            }
        }
    }
}
