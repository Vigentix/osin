import Foundation

/// What one sample contributes to the usage record.
public struct UsageSample: Sendable {
    public let groups: [ProcessGroup]
    public let thermal: ThermalLevel
    public let score: Int
    public let pressure: MemoryPressure
    /// Free share of the startup disk (0…1).
    public let diskFree: Double
    /// Keep Awake was holding the Mac awake.
    public let keepAwake: Bool

    public init(groups: [ProcessGroup], thermal: ThermalLevel, score: Int, pressure: MemoryPressure, diskFree: Double, keepAwake: Bool) {
        self.groups = groups
        self.thermal = thermal
        self.score = score
        self.pressure = pressure
        self.diskFree = diskFree
        self.keepAwake = keepAwake
    }

    public init(snapshot: SystemSnapshot, keepAwake: Bool) {
        self.init(
            groups: snapshot.processes, thermal: snapshot.thermal, score: snapshot.health.score,
            pressure: snapshot.memory.pressure, diskFree: 1 - snapshot.disk.usedFraction, keepAwake: keepAwake
        )
    }
}

/// Local record of how the Mac and its apps are used: when each app was last seen running (for
/// "not used lately"), and this week's totals for the weekly report. Everything is time-weighted by
/// the interval each sample covers, so a window left open (2 s samples) counts the same as the
/// background (30 s samples). Nothing leaves the Mac.
public struct UsageTracker: Codable, Sendable, Equatable {
    public struct AppShare: Codable, Sendable, Equatable {
        public let name: String
        public let bundlePath: String
        public let cpuHours: Double

        public init(name: String, bundlePath: String, cpuHours: Double) {
            self.name = name
            self.bundlePath = bundlePath
            self.cpuHours = cpuHours
        }
    }

    /// A finished week, kept until the weekly report has used it.
    public struct Week: Codable, Sendable, Equatable {
        public let weekStart: Date
        public let topApps: [AppShare]
        /// Time-weighted average health score, `nil` when nothing was measured.
        public let averageScore: Int?
        /// Time with memory pressure at warning or critical.
        public let pressureMinutes: Int
        /// Days on which free disk space dropped below 10 %.
        public let lowDiskDays: Int
        public let keepAwakeHours: Double
        /// Time the Mac spent running hot (thermal state serious or critical).
        public let hotMinutes: Int
        /// Space freed immediately (deleted caches, emptied Trash).
        public let freedBytes: UInt64
        public let choreRuns: Int

        public init(
            weekStart: Date, topApps: [AppShare], averageScore: Int?, pressureMinutes: Int, lowDiskDays: Int,
            keepAwakeHours: Double, hotMinutes: Int, freedBytes: UInt64 = 0, choreRuns: Int = 0
        ) {
            self.weekStart = weekStart
            self.topApps = topApps
            self.averageScore = averageScore
            self.pressureMinutes = pressureMinutes
            self.lowDiskDays = lowDiskDays
            self.keepAwakeHours = keepAwakeHours
            self.hotMinutes = hotMinutes
            self.freedBytes = freedBytes
            self.choreRuns = choreRuns
        }
    }

    /// Free space below this counts as a low-disk day.
    public static let lowDiskThreshold = 0.10

    public private(set) var lastSeen: [String: Date] = [:]
    public private(set) var weekStart: Date
    /// Finished weeks not yet turned into reports, oldest first. Removed by the caller once saved.
    public var closedWeeks: [Week] = []
    private var cpuSeconds: [String: Double] = [:]
    private var names: [String: String] = [:]
    private var measuredSeconds: Double = 0
    private var scoreSeconds: Double = 0
    private var pressureSeconds: Double = 0
    private var lowDiskDays: Set<Date> = []
    private var keepAwakeSeconds: Double = 0
    private var hotSeconds: Double = 0
    private var freedBytes: UInt64 = 0
    private var choreRuns = 0
    /// Pending weeks kept if reports cannot be saved for a long time.
    static let maxClosedWeeks = 8

    public init(weekStart: Date) {
        self.weekStart = weekStart
    }

    /// Monday 00:00 of the week containing `date`.
    public static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        var iso = calendar
        iso.firstWeekday = 2
        return iso.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Whether `date` falls in a later week than `start`. A time-zone change moves "Monday 00:00" by
    /// up to a day, so a week only counts as later once it starts at least two days after `start`.
    public static func isLaterWeek(_ date: Date, than start: Date, calendar: Calendar = .current) -> Bool {
        weekStart(containing: date, calendar: calendar).timeIntervalSince(start) > 2 * 86400
    }

    /// Whether two week starts name the same week, allowing for a time-zone change in between.
    public static func sameWeek(_ first: Date, _ second: Date) -> Bool {
        abs(first.timeIntervalSince(second)) < 2 * 86400
    }

    /// Records one sample covering the `interval` seconds before `date`. An interval that spans the
    /// start of a new week is split between the two.
    public mutating func record(_ sample: UsageSample, interval: TimeInterval, at date: Date, calendar: Calendar = .current) {
        if Self.isLaterWeek(date, than: weekStart, calendar: calendar) {
            let newWeek = Self.weekStart(containing: date, calendar: calendar)
            let inNewWeek = min(max(date.timeIntervalSince(newWeek), 0), interval)
            accumulate(sample, seconds: interval - inNewWeek, at: newWeek.addingTimeInterval(-1), calendar: calendar)
            roll(to: date, calendar: calendar)
            accumulate(sample, seconds: inNewWeek, at: date, calendar: calendar)
        } else {
            accumulate(sample, seconds: interval, at: date, calendar: calendar)
        }
        for group in sample.groups {
            guard let bundle = group.bundlePath else { continue }
            lastSeen[bundle] = date
            names[bundle] = group.name
        }
    }

    /// Space a cleanup freed immediately.
    public mutating func addFreed(_ bytes: UInt64, at date: Date, calendar: Calendar = .current) {
        rollIfNeeded(to: date, calendar: calendar)
        freedBytes += bytes
    }

    public mutating func addChoreRun(at date: Date, calendar: Calendar = .current) {
        rollIfNeeded(to: date, calendar: calendar)
        choreRuns += 1
    }

    private mutating func accumulate(_ sample: UsageSample, seconds: TimeInterval, at date: Date, calendar: Calendar) {
        guard seconds > 0 else { return }
        for group in sample.groups {
            guard let bundle = group.bundlePath else { continue }
            cpuSeconds[bundle, default: 0] += group.cpuFraction * seconds
        }
        measuredSeconds += seconds
        scoreSeconds += Double(sample.score) * seconds
        if sample.pressure >= .warning {
            pressureSeconds += seconds
        }
        if sample.diskFree < Self.lowDiskThreshold {
            lowDiskDays.insert(calendar.startOfDay(for: date))
        }
        if sample.keepAwake {
            keepAwakeSeconds += seconds
        }
        if sample.thermal >= .serious {
            hotSeconds += seconds
        }
    }

    private mutating func rollIfNeeded(to date: Date, calendar: Calendar) {
        if Self.isLaterWeek(date, than: weekStart, calendar: calendar) {
            roll(to: date, calendar: calendar)
        }
    }

    /// Closes the current week and starts the one containing `date`.
    private mutating func roll(to date: Date, calendar: Calendar) {
        let closed = Week(
            weekStart: weekStart,
            topApps: topApps(limit: 5),
            averageScore: measuredSeconds > 0 ? Int((scoreSeconds / measuredSeconds).rounded()) : nil,
            pressureMinutes: Int(pressureSeconds / 60),
            lowDiskDays: lowDiskDays.count,
            keepAwakeHours: keepAwakeSeconds / 3600,
            hotMinutes: Int(hotSeconds / 60),
            freedBytes: freedBytes,
            choreRuns: choreRuns
        )
        closedWeeks = Array((closedWeeks + [closed]).suffix(Self.maxClosedWeeks))
        weekStart = Self.weekStart(containing: date, calendar: calendar)
        cpuSeconds = [:]
        measuredSeconds = 0
        scoreSeconds = 0
        pressureSeconds = 0
        lowDiskDays = []
        keepAwakeSeconds = 0
        hotSeconds = 0
        freedBytes = 0
        choreRuns = 0
        // Drop "last seen" older than a year, and names nobody refers to any more.
        lastSeen = lastSeen.filter { date.timeIntervalSince($0.value) < 365 * 86400 }
        names = names.filter { lastSeen[$0.key] != nil }
    }

    public func topApps(limit: Int) -> [AppShare] {
        cpuSeconds
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map {
                AppShare(
                    name: names[$0.key] ?? URL(fileURLWithPath: $0.key).deletingPathExtension().lastPathComponent,
                    bundlePath: $0.key,
                    cpuHours: $0.value / 3600
                )
            }
    }

    // MARK: Persistence

    /// `nil` when nothing was saved yet; throws when a saved record cannot be read.
    public static func load(from url: URL) throws -> UsageTracker? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UsageTracker.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
