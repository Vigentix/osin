import Foundation
import Testing
@testable import OsinCore

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
}

struct ChoreScheduleTests {
    /// 2026-11-29 is a Sunday.
    private let weekly = ChoreSchedule(frequency: .weekly, weekday: 1, dayOfMonth: 1, hour: 21, minute: 0)

    @Test func latestOccurrenceFollowsTheFrequency() {
        #expect(weekly.occurrence(onOrBefore: date(2026, 12, 1, 10), calendar: calendar) == date(2026, 11, 29, 21))
        let daily = ChoreSchedule(frequency: .daily, hour: 9, minute: 30)
        #expect(daily.occurrence(onOrBefore: date(2026, 12, 1, 8), calendar: calendar) == date(2026, 11, 30, 9, 30))
        let monthly = ChoreSchedule(frequency: .monthly, dayOfMonth: 15, hour: 21)
        #expect(monthly.occurrence(onOrBefore: date(2026, 12, 1), calendar: calendar) == date(2026, 11, 15, 21))
    }

    @Test func aRunIsDueOnceAndCanCatchUpWithinADay() {
        // Sunday 21:00 passed one hour ago, never ran: due.
        #expect(weekly.dueOccurrence(now: date(2026, 11, 29, 22), lastRun: nil, calendar: calendar) == date(2026, 11, 29, 21))
        // Already ran for it: not due again.
        #expect(weekly.dueOccurrence(now: date(2026, 11, 29, 23), lastRun: date(2026, 11, 29, 21, 5), calendar: calendar) == nil)
        // The Mac slept through it and woke Monday 08:00: still within 24 h, catch up.
        #expect(weekly.dueOccurrence(now: date(2026, 11, 30, 8), lastRun: date(2026, 11, 22, 21), calendar: calendar) == date(
            2026,
            11,
            29,
            21
        ))
        // Missed by more than a day: skipped, wait for next week.
        #expect(weekly.dueOccurrence(now: date(2026, 12, 1, 9), lastRun: date(2026, 11, 22, 21), calendar: calendar) == nil)
    }

    @Test func runsOnceWhenClocksGoBack() throws {
        // Los Angeles, Sunday 1 November 2026: 01:00–02:00 happens twice.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let schedule = ChoreSchedule(frequency: .weekly, weekday: 1, hour: 1, minute: 30)
        let firstRun = try #require(ISO8601DateFormatter().date(from: "2026-11-01T08:35:00Z")) // 01:35 PDT
        let secondPass = try #require(ISO8601DateFormatter().date(from: "2026-11-01T09:35:00Z")) // 01:35 PST
        #expect(schedule.dueOccurrence(now: secondPass, lastRun: firstRun, calendar: losAngeles) == nil)
    }

    @Test func runsOnlyOnPowerAndWhenIdle() {
        #expect(ChoreConditions.met(onACPower: true, idleSeconds: 600))
        #expect(!ChoreConditions.met(onACPower: false, idleSeconds: 600))
        #expect(!ChoreConditions.met(onACPower: true, idleSeconds: 60))
    }

    @Test func scheduleSurvivesACodableRoundTrip() throws {
        let decoded = try JSONDecoder().decode(ChoreSchedule.self, from: JSONEncoder().encode(weekly))
        #expect(decoded == weekly)
    }

    @Test func idleTimeIsReadable() {
        #expect(IdleTime.seconds() >= 0)
    }
}

struct WatchdogTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func app(_ name: String, cpu: Double, memoryGB: Double, pid: Int32 = 10) -> ProcessGroup {
        ProcessGroup(
            id: "/Applications/\(name).app", name: name, bundlePath: "/Applications/\(name).app", pids: [pid],
            footprintBytes: UInt64(memoryGB * 1_000_000_000), cpuFraction: cpu
        )
    }

    private func run(
        _ watchdog: inout Watchdog,
        minutes: Int,
        every seconds: Int = 30,
        excluding: Set<Int32> = [],
        groups: (Int) -> [ProcessGroup]
    ) -> [WatchdogAlert] {
        var alerts: [WatchdogAlert] = []
        for step in 0 ... (minutes * 60 / seconds) {
            alerts += watchdog.evaluate(groups(step), at: start.addingTimeInterval(TimeInterval(step * seconds)), excluding: excluding)
        }
        return alerts
    }

    @Test func sustainedHighCPUAlertsOnceAfterFiveMinutes() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        let early = run(&watchdog, minutes: 4) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }
        #expect(early.isEmpty)
        var later = Watchdog(settings: WatchdogSettings())
        let alerts = run(&later, minutes: 20) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }
        #expect(alerts.map(\.kind) == [.highCPU])
        #expect(alerts.first?.name == "Busy")
    }

    @Test func shortSpikesDoNotCount() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        // Busy for 3 minutes, quiet for 1, busy again for 3.
        let alerts = run(&watchdog, minutes: 7) { step in [app("Spiky", cpu: (6 ... 7).contains(step) ? 0.1 : 0.95, memoryGB: 1)] }
        #expect(alerts.isEmpty)
    }

    @Test func steadyMemoryGrowthAlerts() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        // +2.4 GB over 30 minutes, rising steadily.
        let alerts = run(&watchdog, minutes: 31) { step in [app("Leaky", cpu: 0.1, memoryGB: 1 + Double(step) * 0.04)] }
        #expect(alerts.map(\.kind) == [.memoryGrowth])
    }

    @Test func ignoredAppsAndWatchedProcessesAreSkipped() {
        var settings = WatchdogSettings()
        settings.ignoredApps = ["/Applications/Busy.app"]
        var ignored = Watchdog(settings: settings)
        #expect(run(&ignored, minutes: 10) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }.isEmpty)
        var keepAwake = Watchdog(settings: WatchdogSettings())
        #expect(run(&keepAwake, minutes: 10, excluding: [42]) { _ in [app("Build", cpu: 0.95, memoryGB: 1, pid: 42)] }.isEmpty)
    }

    @Test func systemProcessesAreNotWatched() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        let daemon = ProcessGroup(id: "pid:99", name: "mds_stores", bundlePath: nil, pids: [99], footprintBytes: 1, cpuFraction: 0.99)
        #expect(run(&watchdog, minutes: 10) { _ in [daemon] }.isEmpty)
    }

    @Test func atMostOneAlertPerAppPerDayEvenAfterARelaunch() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        let first = run(&watchdog, minutes: 6) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }
        #expect(first.count == 1)
        var relaunched = Watchdog(settings: WatchdogSettings(), lastAlerts: watchdog.lastAlerts)
        #expect(run(&relaunched, minutes: 12) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }.isEmpty)
    }

    @Test func frequentSamplesStillDetectGrowth() {
        // A dashboard left open samples every 2 s; growth over 30 minutes is still caught.
        var watchdog = Watchdog(settings: WatchdogSettings())
        let alerts = run(&watchdog, minutes: 31, every: 2) { step in [app("Leaky", cpu: 0.1, memoryGB: 1 + Double(step) * 0.0027)] }
        #expect(alerts.map(\.kind) == [.memoryGrowth])
    }

    @Test func sleepBreaksABusyStreak() {
        var watchdog = Watchdog(settings: WatchdogSettings())
        let busy = [app("Busy", cpu: 0.95, memoryGB: 1)]
        // Three busy minutes, the Mac sleeps for an hour, then three more busy minutes: never five in a row.
        var alerts: [WatchdogAlert] = []
        for step in 0 ... 6 {
            alerts += watchdog.evaluate(busy, at: start.addingTimeInterval(Double(step) * 30))
        }
        for step in 0 ... 6 {
            alerts += watchdog.evaluate(busy, at: start.addingTimeInterval(3780 + Double(step) * 30))
        }
        #expect(alerts.isEmpty)
    }

    @Test func disabledWatchdogIsQuiet() {
        var settings = WatchdogSettings()
        settings.enabled = false
        var watchdog = Watchdog(settings: settings)
        #expect(run(&watchdog, minutes: 10) { _ in [app("Busy", cpu: 0.95, memoryGB: 1)] }.isEmpty)
    }
}

struct UsageTrackerTests {
    private func app(_ name: String, cpu: Double) -> ProcessGroup {
        ProcessGroup(
            id: "/Applications/\(name).app",
            name: name,
            bundlePath: "/Applications/\(name).app",
            pids: [1],
            footprintBytes: 1,
            cpuFraction: cpu
        )
    }

    private func sample(
        _ groups: [ProcessGroup] = [], score: Int = 90, pressure: MemoryPressure = .normal, diskFree: Double = 0.4,
        thermal: ThermalLevel = .nominal, keepAwake: Bool = false
    ) -> UsageSample {
        UsageSample(groups: groups, thermal: thermal, score: score, pressure: pressure, diskFree: diskFree, keepAwake: keepAwake)
    }

    @Test func remembersWhenAppsWereLastSeenRunning() {
        let monday = date(2026, 11, 30, 10)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: monday, calendar: calendar))
        tracker.record(sample([app("Xcode", cpu: 0.5)]), interval: 30, at: monday, calendar: calendar)
        #expect(tracker.lastSeen["/Applications/Xcode.app"] == monday)
    }

    @Test func closesTheWeekAtMondayMidnightAndRanksApps() {
        let monday = date(2026, 11, 30, 10)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: monday, calendar: calendar))
        #expect(tracker.weekStart == date(2026, 11, 30))
        tracker.record(
            sample([app("Xcode", cpu: 2), app("Safari", cpu: 0.5)], thermal: .serious, keepAwake: true),
            interval: 3600,
            at: monday,
            calendar: calendar
        )
        #expect(tracker.closedWeeks.isEmpty)
        // First sample of the next week closes this one.
        tracker.record(sample([app("Safari", cpu: 0.1)]), interval: 30, at: date(2026, 12, 7, 0, 5), calendar: calendar)
        let closed = tracker.closedWeeks.last
        #expect(closed?.weekStart == date(2026, 11, 30))
        #expect(closed?.topApps.map(\.name) == ["Xcode", "Safari"])
        #expect(closed?.topApps.first.map { abs($0.cpuHours - 2) < 0.001 } == true)
        #expect(closed?.keepAwakeHours == 1)
        #expect(closed?.hotMinutes == 60)
        #expect(tracker.weekStart == date(2026, 12, 7))
    }

    @Test func healthAndStrainAreWeightedByTime() {
        let monday = date(2026, 11, 30, 10)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: monday, calendar: calendar))
        // Three hours at 90, one hour at 50 under memory pressure: average 80, 60 minutes strained,
        // however often each was sampled.
        for step in 1 ... 360 {
            tracker.record(sample(score: 90), interval: 30, at: monday.addingTimeInterval(Double(step) * 30), calendar: calendar)
        }
        for step in 1 ... 1800 {
            tracker.record(
                sample(score: 50, pressure: .warning, diskFree: 0.05),
                interval: 2,
                at: monday.addingTimeInterval(10800 + Double(step) * 2),
                calendar: calendar
            )
        }
        tracker.record(sample(), interval: 0, at: date(2026, 12, 7, 1), calendar: calendar)
        #expect(tracker.closedWeeks.last?.averageScore == 80)
        #expect(tracker.closedWeeks.last?.pressureMinutes == 60)
        #expect(tracker.closedWeeks.last?.lowDiskDays == 1)
    }

    @Test func aTimeZoneChangeDoesNotCloseTheWeekEarly() {
        // Week started Monday 00:00 in Ho Chi Minh City; the Mac then moves to Los Angeles, where
        // Monday 00:00 is a later instant in the same week.
        let start = date(2026, 11, 30)
        var tracker = UsageTracker(weekStart: start)
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        tracker.record(sample(), interval: 30, at: start.addingTimeInterval(86400), calendar: losAngeles)
        #expect(tracker.closedWeeks.isEmpty)
        #expect(tracker.weekStart == start)
        tracker.record(sample(), interval: 30, at: start.addingTimeInterval(8 * 86400), calendar: losAngeles)
        #expect(tracker.closedWeeks.last?.weekStart == start)
    }

    @Test func countsCleanupsAndChoresInTheirWeek() {
        let monday = date(2026, 11, 30, 10)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: monday, calendar: calendar))
        tracker.addFreed(1000, at: monday, calendar: calendar)
        tracker.addChoreRun(at: monday, calendar: calendar)
        // Freed next week, before any sample of that week arrived: closes this week first.
        tracker.addFreed(500, at: date(2026, 12, 7, 9), calendar: calendar)
        #expect(tracker.closedWeeks.last?.freedBytes == 1000)
        #expect(tracker.closedWeeks.last?.choreRuns == 1)
        tracker.record(sample(), interval: 0, at: date(2026, 12, 14, 9), calendar: calendar)
        #expect(tracker.closedWeeks.map(\.freedBytes) == [1000, 500])
    }

    @Test func anIntervalAcrossMondayMidnightIsSplit() {
        let sunday = date(2026, 12, 6, 23, 59)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: sunday, calendar: calendar))
        tracker.record(sample(keepAwake: true), interval: 0, at: sunday, calendar: calendar)
        // 120 s ending at Monday 00:01: one minute in each week.
        tracker.record(sample(keepAwake: true), interval: 120, at: date(2026, 12, 7, 0, 1), calendar: calendar)
        tracker.record(sample(), interval: 0, at: date(2026, 12, 14, 1), calendar: calendar)
        #expect(tracker.closedWeeks.count == 2)
        #expect(tracker.closedWeeks.map(\.keepAwakeHours) == [60.0 / 3600, 60.0 / 3600])
    }

    @Test func pendingWeeksQueueUpUntilSaved() {
        var tracker = UsageTracker(weekStart: date(2026, 11, 30))
        tracker.record(sample(), interval: 30, at: date(2026, 12, 8), calendar: calendar)
        tracker.record(sample(), interval: 30, at: date(2026, 12, 15), calendar: calendar)
        #expect(tracker.closedWeeks.map(\.weekStart) == [date(2026, 11, 30), date(2026, 12, 7)])
    }

    @Test func anUnreadableRecordIsReportedNotTreatedAsMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("usage.json")
        #expect(try UsageTracker.load(from: url) == nil)
        try Data("{".utf8).write(to: url)
        #expect(throws: (any Error).self) { try UsageTracker.load(from: url) }
    }

    @Test func survivesACodableRoundTrip() throws {
        let monday = date(2026, 11, 30, 10)
        var tracker = UsageTracker(weekStart: UsageTracker.weekStart(containing: monday, calendar: calendar))
        tracker.record(sample([app("Xcode", cpu: 1)], diskFree: 0.05), interval: 30, at: monday, calendar: calendar)
        let decoded = try JSONDecoder().decode(UsageTracker.self, from: JSONEncoder().encode(tracker))
        #expect(decoded == tracker)
    }
}

struct WeeklySummaryTests {
    @Test func summarisesTheWeek() {
        let week = UsageTracker.Week(
            weekStart: date(2026, 11, 30),
            topApps: [],
            averageScore: 80,
            pressureMinutes: 10,
            lowDiskDays: 1,
            keepAwakeHours: 3,
            hotMinutes: 2,
            freedBytes: 1500,
            choreRuns: 1
        )
        let summary = WeeklySummary(week: week)
        #expect(summary.averageScore == 80)
        #expect(summary.freedBytes == 1500)
        #expect(summary.pressureMinutes == 10)
        #expect(summary.lowDiskDays == 1)
        #expect(summary.keepAwakeHours == 3)
        #expect(summary.choreRuns == 1)
    }

    @Test func anUnreadableStoreIsKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-weeks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("weekly.json")
        try Data("not json".utf8).write(to: url)
        let store = WeeklySummaryStore(url: url)
        try store.append(summary(score: 70))
        #expect(try store.load().count == 1)
        let aside = folder.appendingPathComponent("weekly.unreadable.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
    }

    private func summary(
        score: Int?,
        freed: UInt64 = 0,
        pressure: Int = 0,
        lowDisk: Int = 0,
        hot: Int = 0,
        apps: [UsageTracker.AppShare] = [],
        chores: Int = 0
    ) -> WeeklySummary {
        WeeklySummary(
            weekStart: date(2026, 11, 30),
            averageScore: score,
            freedBytes: freed,
            pressureMinutes: pressure,
            lowDiskDays: lowDisk,
            hotMinutes: hot,
            keepAwakeHours: 0,
            choreRuns: chores,
            topApps: apps
        )
    }

    @Test func suggestsWhatTheWeekCallsFor() {
        let busy = summary(
            score: 60,
            pressure: 90,
            lowDisk: 2,
            hot: 100,
            apps: [UsageTracker.AppShare(name: "Xcode", bundlePath: "/Applications/Xcode.app", cpuHours: 12)]
        )
        #expect(busy.suggestions(choresEnabled: true) == [.lowDisk(days: 2), .memoryStrain(minutes: 90), .runningHot])
        #expect(summary(score: 95).suggestions(choresEnabled: false) == [.scheduleChores])
        #expect(summary(score: 95, freed: 10).suggestions(choresEnabled: false).isEmpty)
        #expect(summary(score: 95).suggestions(choresEnabled: true).isEmpty)
    }

    @Test func comparesScoreWithThePreviousWeek() {
        #expect(summary(score: 82).scoreChange(from: summary(score: 75)) == 7)
        #expect(summary(score: 82).scoreChange(from: nil) == nil)
        #expect(summary(score: nil).scoreChange(from: summary(score: 75)) == nil)
    }

    @Test func storeKeepsTheLast52Weeks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-weeks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WeeklySummaryStore(url: folder.appendingPathComponent("weekly.json"))
        for index in 0 ..< 60 {
            let start = date(2026, 1, 5).addingTimeInterval(Double(index) * 7 * 86400)
            try store.append(WeeklySummary(
                weekStart: start,
                averageScore: index,
                freedBytes: 0,
                pressureMinutes: 0,
                lowDiskDays: 0,
                hotMinutes: 0,
                keepAwakeHours: 0,
                choreRuns: 0,
                topApps: []
            ))
        }
        let kept = try store.load()
        #expect(kept.count == 52)
        #expect(kept.last?.averageScore == 59)
        #expect(kept.first?.averageScore == 8)
    }
}
