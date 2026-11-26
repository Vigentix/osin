import Foundation

/// How Keep Awake treats the display while the Mac stays awake.
public enum KeepAwakeMode: String, Codable, Sendable, CaseIterable {
    /// The Mac stays awake; the display stays on unless `keepDisplayOn` is off.
    case awake
    /// The screen locks and the display turns off right away; the Mac keeps working.
    case lockScreen
}

/// A process Keep Awake waits for. The start time tells it apart from a later process that
/// happens to get the same PID.
public struct WatchedProcess: Codable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let name: String
    public let startTime: Date

    public init(pid: Int32, name: String, startTime: Date) {
        self.pid = pid
        self.name = name
        self.startTime = startTime
    }
}

public enum KeepAwakeDuration: Codable, Sendable, Equatable, Hashable {
    case indefinite
    case minutes(Int)
    case until(Date)
    case process(WatchedProcess)
}

/// What the user chose when starting Keep Awake.
public struct KeepAwakeOptions: Codable, Sendable, Equatable {
    public var mode: KeepAwakeMode
    /// Only for `.awake`: keep the display on, or let it turn off on macOS's own schedule.
    public var keepDisplayOn: Bool
    public var duration: KeepAwakeDuration
    /// Optional cap, for indefinite and process sessions in particular.
    public var maxHours: Double?

    public init(
        mode: KeepAwakeMode = .awake,
        keepDisplayOn: Bool = true,
        duration: KeepAwakeDuration = .indefinite,
        maxHours: Double? = nil
    ) {
        self.mode = mode
        self.keepDisplayOn = keepDisplayOn
        self.duration = duration
        self.maxHours = maxHours
    }

    /// The options to offer next time: a watched process or a time already past cannot be reused.
    public func forReuse(now: Date) -> KeepAwakeOptions {
        var reused = self
        switch duration {
        case .process:
            reused.duration = .indefinite
        case let .until(date) where date <= now:
            reused.duration = .indefinite
        default:
            break
        }
        return reused
    }
}

/// A running Keep Awake session.
public struct KeepAwakeSession: Sendable, Equatable {
    public let options: KeepAwakeOptions
    public let startedAt: Date

    public init(options: KeepAwakeOptions, startedAt: Date) {
        self.options = options
        self.startedAt = startedAt
    }

    /// When the chosen time runs out, ignoring the cap.
    var timerDeadline: Date? {
        switch options.duration {
        case .indefinite, .process: nil
        case let .minutes(minutes): startedAt.addingTimeInterval(TimeInterval(minutes) * 60)
        case let .until(date): date
        }
    }

    var capDeadline: Date? {
        options.maxHours.map { startedAt.addingTimeInterval($0 * 3600) }
    }

    /// The earliest moment the session ends on its own, or `nil` when only an event can end it.
    public var deadline: Date? {
        [timerDeadline, capDeadline].compactMap(\.self).min()
    }

    /// Time left. `elapsed` comes from a monotonic clock, so timers and the cap are not fooled by the
    /// wall clock being changed; "until 7:00" naturally follows the wall clock.
    public func remaining(at now: Date, elapsed: TimeInterval) -> TimeInterval? {
        var limits: [TimeInterval] = []
        switch options.duration {
        case let .minutes(minutes): limits.append(TimeInterval(minutes) * 60 - elapsed)
        case let .until(date): limits.append(date.timeIntervalSince(now))
        case .indefinite, .process: break
        }
        if let hours = options.maxHours {
            limits.append(hours * 3600 - elapsed)
        }
        return limits.min().map { max(0, $0) }
    }

    public var watchedProcess: WatchedProcess? {
        if case let .process(process) = options.duration {
            return process
        }
        return nil
    }
}

/// Safety rules that end Keep Awake on their own.
public struct KeepAwakeRules: Codable, Sendable, Equatable {
    public var stopOnLowBattery: Bool
    public var lowBatteryThreshold: Double
    public var stopWhenHot: Bool
    public var stopWhenUnplugged: Bool

    public init(
        stopOnLowBattery: Bool = true,
        lowBatteryThreshold: Double = 0.20,
        stopWhenHot: Bool = true,
        stopWhenUnplugged: Bool = false
    ) {
        self.stopOnLowBattery = stopOnLowBattery
        self.lowBatteryThreshold = lowBatteryThreshold
        self.stopWhenHot = stopWhenHot
        self.stopWhenUnplugged = stopWhenUnplugged
    }
}

/// The power facts the rules look at.
public struct PowerReading: Sendable, Equatable {
    /// `nil` on Macs without a battery.
    public let batteryFraction: Double?
    public let onACPower: Bool
    public let thermal: ThermalLevel

    public init(batteryFraction: Double?, onACPower: Bool, thermal: ThermalLevel) {
        self.batteryFraction = batteryFraction
        self.onACPower = onACPower
        self.thermal = thermal
    }
}

public enum KeepAwakeStopReason: Sendable, Equatable {
    case stoppedByUser
    case timeUp
    case reachedMaxDuration
    case processEnded(name: String)
    case lowBattery
    case tooHot
    case unplugged
}

public enum KeepAwakeEvaluator {
    /// Why the session should end now, or `nil` to keep going. `processAlive` only matters when a
    /// process is watched. A finished process is reported first, then time, then safety rules.
    /// Both wall time (for "until") and monotonic `elapsed` time (for timers and the cap) are needed.
    public static func stopReason( // swiftlint:disable:this function_parameter_count
        for session: KeepAwakeSession,
        at now: Date,
        elapsed: TimeInterval,
        power: PowerReading,
        processAlive: Bool,
        rules: KeepAwakeRules
    ) -> KeepAwakeStopReason? {
        if let process = session.watchedProcess, !processAlive {
            return .processEnded(name: process.name)
        }
        switch session.options.duration {
        case let .minutes(minutes) where elapsed >= TimeInterval(minutes) * 60:
            return .timeUp
        case let .until(date) where now >= date:
            return .timeUp
        default:
            break
        }
        if let hours = session.options.maxHours, elapsed >= hours * 3600 {
            return .reachedMaxDuration
        }
        return safetyStop(power: power, rules: rules)
    }

    /// The safety rules alone, also used to refuse starting (for example at 15 % battery).
    public static func safetyStop(power: PowerReading, rules: KeepAwakeRules) -> KeepAwakeStopReason? {
        let hasBattery = power.batteryFraction != nil
        if rules.stopWhenHot, power.thermal >= .serious {
            return .tooHot
        }
        if rules.stopWhenUnplugged, hasBattery, !power.onACPower {
            return .unplugged
        }
        if rules.stopOnLowBattery, !power.onACPower, let level = power.batteryFraction, level < rules.lowBatteryThreshold {
            return .lowBattery
        }
        return nil
    }
}

/// Whether macOS may restart on its own to install an update (read from the system's
/// Software Update preferences, which every user can read).
public struct SoftwareUpdateStatus: Sendable, Equatable {
    public let pendingMacOSUpdate: String?
    public let installsMacOSUpdatesAutomatically: Bool

    public var mayRestartOnItsOwn: Bool {
        pendingMacOSUpdate != nil && installsMacOSUpdatesAutomatically
    }

    public init(preferences: [String: Any]) {
        let updates = preferences["RecommendedUpdates"] as? [[String: Any]] ?? []
        pendingMacOSUpdate = updates.first { ($0["MobileSoftwareUpdate"] as? Int ?? 0) == 1 }?["Display Name"] as? String
        installsMacOSUpdatesAutomatically = (preferences["AutomaticallyInstallMacOSUpdates"] as? Int ?? 0) == 1
    }

    public static func current() -> SoftwareUpdateStatus {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
        let preferences = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
        return SoftwareUpdateStatus(preferences: preferences)
    }
}
