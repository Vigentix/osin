import Foundation

/// One week of "housework", for the Monday report and the trend against the week before.
public struct WeeklySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: Date {
        weekStart
    }

    public let weekStart: Date
    public let averageScore: Int?
    /// Space freed immediately (deleted caches, emptied Trash) during the week.
    public let freedBytes: UInt64
    /// Time spent with memory pressure at warning or critical.
    public let pressureMinutes: Int
    /// Days on which free disk space dropped below 10 %.
    public let lowDiskDays: Int
    /// Time spent running hot.
    public let hotMinutes: Int
    public let keepAwakeHours: Double
    public let choreRuns: Int
    public let topApps: [UsageTracker.AppShare]

    public init(
        weekStart: Date, averageScore: Int?, freedBytes: UInt64, pressureMinutes: Int, lowDiskDays: Int,
        hotMinutes: Int, keepAwakeHours: Double, choreRuns: Int, topApps: [UsageTracker.AppShare]
    ) {
        self.weekStart = weekStart
        self.averageScore = averageScore
        self.freedBytes = freedBytes
        self.pressureMinutes = pressureMinutes
        self.lowDiskDays = lowDiskDays
        self.hotMinutes = hotMinutes
        self.keepAwakeHours = keepAwakeHours
        self.choreRuns = choreRuns
        self.topApps = topApps
    }

    /// The report for a finished week of the usage record.
    public init(week: UsageTracker.Week) {
        self.init(
            weekStart: week.weekStart, averageScore: week.averageScore, freedBytes: week.freedBytes, pressureMinutes: week.pressureMinutes,
            lowDiskDays: week.lowDiskDays, hotMinutes: week.hotMinutes, keepAwakeHours: week.keepAwakeHours, choreRuns: week.choreRuns,
            topApps: week.topApps
        )
    }
}

public extension WeeklySummary {
    /// Something worth doing, drawn from the week.
    enum Suggestion: Equatable, Sendable {
        /// Free space dropped below 10 % on this many days.
        case lowDisk(days: Int)
        /// Memory was strained for this many minutes.
        case memoryStrain(minutes: Int)
        /// The Mac ran hot often.
        case runningHot
        /// One app used a lot of CPU time.
        case heavyApp(name: String, hours: Double)
        /// Nothing was cleaned and chores are off.
        case scheduleChores
    }

    /// At most three suggestions, most useful first.
    func suggestions(choresEnabled: Bool) -> [Suggestion] {
        var result: [Suggestion] = []
        if lowDiskDays > 0 {
            result.append(.lowDisk(days: lowDiskDays))
        }
        if pressureMinutes >= 60 {
            result.append(.memoryStrain(minutes: pressureMinutes))
        }
        if hotMinutes >= 60 {
            result.append(.runningHot)
        }
        if let top = topApps.first, top.cpuHours >= 10 {
            result.append(.heavyApp(name: top.name, hours: top.cpuHours))
        }
        if !choresEnabled, freedBytes == 0, choreRuns == 0 {
            result.append(.scheduleChores)
        }
        return Array(result.prefix(3))
    }

    /// Change in average score against an earlier week, `nil` when either has no score.
    func scoreChange(from previous: WeeklySummary?) -> Int? {
        guard let averageScore, let before = previous?.averageScore else { return nil }
        return averageScore - before
    }

    /// The week after this one starts (the report is about the week that just ended).
    func weekEnd(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86400)
    }
}

/// The last 52 weekly summaries, as JSON in Application Support.
public struct WeeklySummaryStore: Sendable {
    public let url: URL
    public static let keep = 52

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Osin", isDirectory: true).appendingPathComponent("weekly-summaries.json")
    }

    public func load() throws -> [WeeklySummary] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([WeeklySummary].self, from: Data(contentsOf: url))
    }

    /// Adds (or replaces) a week, keeping the newest 52 in order. A file that cannot be read is kept
    /// aside as `weekly-summaries.unreadable.json` instead of being overwritten.
    public func append(_ summary: WeeklySummary) throws {
        var all: [WeeklySummary]
        do {
            all = try load()
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: url, to: aside)
            all = []
        }
        all.removeAll { $0.weekStart == summary.weekStart }
        all.append(summary)
        all.sort { $0.weekStart < $1.weekStart }
        let kept = Array(all.suffix(Self.keep))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(kept).write(to: url, options: .atomic)
    }
}
