import Foundation
import IOKit

/// When scheduled chores run: daily, weekly on a weekday, or monthly on a day, at a time.
public struct ChoreSchedule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily
        case weekly
        case monthly
    }

    public var frequency: Frequency
    /// Calendar weekday for `.weekly` (1 = Sunday … 7 = Saturday).
    public var weekday: Int
    /// Day of the month for `.monthly` (1–28, so every month has it).
    public var dayOfMonth: Int
    public var hour: Int
    public var minute: Int

    /// A missed run (Mac asleep or Osin not running) is caught up if it is at most this late.
    public static let catchUpWindow: TimeInterval = 86400

    public init(frequency: Frequency = .weekly, weekday: Int = 1, dayOfMonth: Int = 1, hour: Int = 21, minute: Int = 0) {
        self.frequency = frequency
        self.weekday = weekday
        self.dayOfMonth = min(max(dayOfMonth, 1), 28)
        self.hour = hour
        self.minute = minute
    }

    private var components: DateComponents {
        switch frequency {
        case .daily: DateComponents(hour: hour, minute: minute)
        case .weekly: DateComponents(hour: hour, minute: minute, weekday: weekday)
        case .monthly: DateComponents(day: min(max(dayOfMonth, 1), 28), hour: hour, minute: minute)
        }
    }

    /// The latest scheduled time at or before `date`.
    public func occurrence(onOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        if calendar.date(date, matchesComponents: components), calendar.component(.second, from: date) == 0 {
            return date
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, direction: .backward)
    }

    /// The next scheduled time after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// The scheduled time that should run now: the latest one that has not run yet and is at most a
    /// day old. `nil` when nothing is due.
    public func dueOccurrence(now: Date, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        guard let latest = occurrence(onOrBefore: now, calendar: calendar),
              now.timeIntervalSince(latest) <= Self.catchUpWindow
        else { return nil }
        if let lastRun, lastRun >= latest {
            return nil
        }
        return latest
    }
}

/// Chores run in the background only when they cannot get in the way.
public enum ChoreConditions {
    /// The Mac must have been left alone this long.
    public static let minimumIdle: TimeInterval = 300

    public static func met(onACPower: Bool, idleSeconds: TimeInterval) -> Bool {
        onACPower && idleSeconds >= minimumIdle
    }
}

/// Seconds since the last keyboard, mouse or trackpad input (IOHIDSystem's `HIDIdleTime`).
public enum IdleTime {
    public static func seconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return 0 }
        return TimeInterval(value.uint64Value) / 1_000_000_000
    }
}

/// One scheduled cleanup, kept for History and the weekly report.
public struct ChoreRun: Codable, Sendable, Equatable {
    public let date: Date
    /// Deleted outright (regenerable caches and logs).
    public let freedBytes: UInt64
    /// Moved to the Trash (restorable from History).
    public let trashedBytes: UInt64
    public let failures: Int

    public init(date: Date, freedBytes: UInt64, trashedBytes: UInt64, failures: Int) {
        self.date = date
        self.freedBytes = freedBytes
        self.trashedBytes = trashedBytes
        self.failures = failures
    }

    public var totalBytes: UInt64 {
        freedBytes + trashedBytes
    }
}
