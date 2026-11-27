import AppKit
import Observation
import OsinCore
import UserNotifications

/// The "housekeeper" jobs that run alongside monitoring: scheduled chores, the weekly report,
/// watching apps that misbehave, and remembering which apps are used. Fed one snapshot at a time.
@MainActor
@Observable
final class Housekeeper {
    /// Up to 52 weekly summaries, oldest first.
    private(set) var summaries: [WeeklySummary] = []
    /// Recent scheduled cleanups, oldest first.
    private(set) var choreRuns: [ChoreRun] = []
    private(set) var isRunningChore = false
    /// The week whose card the user dismissed with "Got it".
    private(set) var dismissedWeek: Date?

    private enum Key {
        static let choreRuns = "choreRuns"
        static let choresArmedAt = "choresArmedAt"
        static let dismissedWeek = "weeklyCardDismissed"
        static let notifiedWeek = "weeklyReportNotified"
        static let watchHistory = "watchHistory"
    }

    private static let keptChoreRuns = 60

    @ObservationIgnored private let monitor: SystemMonitor
    @ObservationIgnored private let scan: ScanCoordinator
    @ObservationIgnored private let keepAwake: KeepAwakeController
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var usage: UsageTracker
    @ObservationIgnored private var watchdog: Watchdog
    @ObservationIgnored private let store: WeeklySummaryStore?
    @ObservationIgnored private let usageURL: URL?
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastUsageSave = Date()
    @ObservationIgnored private var lastMinuteCheck = Date.distantPast
    /// A week that could not be saved is retried, but not on every sample.
    @ObservationIgnored private var lastCloseAttempt = Date.distantPast
    @ObservationIgnored private var isPostingReport = false
    /// Notifications were off or not allowed: Watch keeps tracking but skips the permission check until then.
    @ObservationIgnored private var watchQuietUntil = Date.distantPast

    init(monitor: SystemMonitor, scan: ScanCoordinator, keepAwake: KeepAwakeController, notifier: Notifier) {
        self.monitor = monitor
        self.scan = scan
        self.keepAwake = keepAwake
        self.notifier = notifier
        let folder = try? CleanupLog.defaultURL().deletingLastPathComponent()
        usageURL = folder?.appendingPathComponent("app-usage.json")
        store = (try? WeeklySummaryStore.defaultURL()).map { WeeklySummaryStore(url: $0) }
        usage = usageURL.flatMap(Self.loadUsage(from:)) ?? UsageTracker(weekStart: UsageTracker.weekStart(containing: Date()))
        watchdog = Watchdog(settings: Preferences.watchdogSettings, lastAlerts: Self.loadWatchHistory())
        summaries = (try? store?.load()) ?? []
        choreRuns = UserDefaults.standard.data(forKey: Key.choreRuns).flatMap { try? JSONDecoder().decode([ChoreRun].self, from: $0) } ?? []
        let dismissed = UserDefaults.standard.double(forKey: Key.dismissedWeek)
        dismissedWeek = dismissed > 0 ? Date(timeIntervalSince1970: dismissed) : nil
    }

    // MARK: Sampling

    func handle(_ snapshot: SystemSnapshot) {
        // CPU time is counted for the time since the previous sample (capped, so a sleep is not counted).
        let interval = lastSample.map { min(max(snapshot.date.timeIntervalSince($0), 0), 60) } ?? 0
        lastSample = snapshot.date
        usage.record(UsageSample(snapshot: snapshot, keepAwake: keepAwake.isActive), interval: interval, at: snapshot.date)
        if !usage.closedWeeks.isEmpty {
            closeWeek()
        }
        // Checkpoint about once a minute, so a crash loses little.
        if snapshot.date.timeIntervalSince(lastUsageSave) >= 60 {
            saveUsage()
        }
        watch(snapshot)
        if snapshot.date.timeIntervalSince(lastMinuteCheck) >= 60 {
            lastMinuteCheck = snapshot.date
            runChoreIfDue(onACPower: snapshot.battery?.isOnACPower ?? true)
            postWeeklyReportIfDue()
        }
    }

    func saveUsage() {
        lastUsageSave = Date()
        guard let usageURL else { return }
        try? usage.save(to: usageURL)
    }

    /// The saved usage record. One that cannot be read is kept aside as `app-usage.unreadable.json`
    /// rather than overwritten.
    private static func loadUsage(from url: URL) -> UsageTracker? {
        do {
            return try UsageTracker.load(from: url)
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    /// When each app was last seen running (bundle path to date), for "not used lately".
    var lastSeen: [String: Date] {
        usage.lastSeen
    }

    // MARK: Chores

    /// Restarts the catch-up window: turning chores on, or changing when they run, never cleans
    /// right away for a time that already passed.
    func armChores() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.choresArmedAt)
    }

    var nextChore: Date? {
        guard UserDefaults.standard.bool(forKey: Preferences.Key.choresEnabled) else { return nil }
        return Preferences.choreSchedule.next(after: Date())
    }

    private var lastChoreReference: Date? {
        let armed = UserDefaults.standard.double(forKey: Key.choresArmedAt)
        let armedAt = armed > 0 ? Date(timeIntervalSince1970: armed) : nil
        return [choreRuns.last?.date, armedAt].compactMap(\.self).max()
    }

    private func runChoreIfDue(onACPower: Bool) {
        guard UserDefaults.standard.bool(forKey: Preferences.Key.choresEnabled), !isRunningChore, !scan.isBusy else { return }
        let now = Date()
        guard Preferences.choreSchedule.dueOccurrence(now: now, lastRun: lastChoreReference) != nil,
              ChoreConditions.met(onACPower: onACPower, idleSeconds: IdleTime.seconds())
        else { return }
        let schedule = Preferences.choreSchedule
        let armedAt = UserDefaults.standard.double(forKey: Key.choresArmedAt)
        let ruleIDs = Set(ScanCoordinator.choreRules().map(\.id)).subtracting(Preferences.choreExcludedRules)
        guard !ruleIDs.isEmpty else { return }
        isRunningChore = true
        Task {
            defer { isRunningChore = false }
            let allowed: @Sendable (String) -> Bool = { Self.choreStillAllowed(schedule: schedule, armedAt: armedAt, ruleID: $0) }
            guard let run = await scan.runChore(ruleIDs: ruleIDs, at: now, stillAllowed: allowed) else { return }
            record(run)
            usage.addChoreRun(at: now)
            saveUsage()
            if run.totalBytes > 0 {
                notifier.choreDone(run)
            }
        }
    }

    /// Re-checked right before each item is removed: chores still on, same schedule, rule still ticked,
    /// still plugged in, user still away. Runs on the cleaner's actor, so it only reads thread-safe state.
    /// `armedAt` changes whenever chores are turned on or rescheduled, which ends a run already under way.
    nonisolated static func choreStillAllowed(schedule: ChoreSchedule, armedAt: Double, ruleID: String) -> Bool {
        UserDefaults.standard.bool(forKey: Preferences.Key.choresEnabled)
            && UserDefaults.standard.double(forKey: Key.choresArmedAt) == armedAt
            && Preferences.choreSchedule == schedule
            && !Preferences.choreExcludedRules.contains(ruleID)
            && ChoreConditions.met(onACPower: BatteryReader.read()?.isOnACPower ?? true, idleSeconds: IdleTime.seconds())
    }

    private func record(_ run: ChoreRun) {
        choreRuns = Array((choreRuns + [run]).suffix(Self.keptChoreRuns))
        UserDefaults.standard.set(try? JSONEncoder().encode(choreRuns), forKey: Key.choreRuns)
    }

    // MARK: Weekly report

    /// The report for the week that just ended, shown from Monday until the end of Wednesday.
    func reportToShow(now: Date = Date()) -> WeeklySummary? {
        #if DEBUG
            // Screenshots are taken on any weekday.
            if DemoData.isActive {
                return summaries.last
            }
        #endif
        let thisWeek = UsageTracker.weekStart(containing: now)
        guard let last = summaries.last, UsageTracker.sameWeek(last.weekEnd(), thisWeek),
              dismissedWeek.map({ !UsageTracker.sameWeek($0, last.weekStart) }) ?? true,
              let thursday = Calendar.current.date(byAdding: .day, value: 3, to: thisWeek), now < thursday
        else { return nil }
        return last
    }

    func previous(of summary: WeeklySummary) -> WeeklySummary? {
        summaries.last { $0.weekStart < summary.weekStart }
    }

    func dismiss(_ summary: WeeklySummary) {
        dismissedWeek = summary.weekStart
        UserDefaults.standard.set(summary.weekStart.timeIntervalSince1970, forKey: Key.dismissedWeek)
    }

    /// Saves the oldest finished week as a report. It stays queued in the usage record (which is
    /// saved too) until the report is written, and is retried hourly if that fails.
    private func closeWeek() {
        guard let week = usage.closedWeeks.first, Date().timeIntervalSince(lastCloseAttempt) > 3600, let store else { return }
        lastCloseAttempt = Date()
        do {
            try store.append(WeeklySummary(week: week))
        } catch {
            saveUsage()
            return
        }
        summaries = (try? store.load()) ?? summaries
        usage.closedWeeks.removeFirst()
        lastCloseAttempt = .distantPast
        saveUsage()
    }

    /// A cleanup (manual or chore) freed space now.
    func recordFreed(_ bytes: UInt64) {
        guard bytes > 0 else { return }
        usage.addFreed(bytes, at: Date())
        // Saved with the next checkpoint (about a minute) and at quit.
    }

    /// Monday from 9:00: one notification about last week (skipped once the card is dismissed).
    /// Marked as sent only once macOS accepted it, so turning notifications on later still delivers it.
    private func postWeeklyReportIfDue() {
        let now = Date()
        guard !isPostingReport, UserDefaults.standard.bool(forKey: Preferences.Key.weeklyReportEnabled),
              UserDefaults.standard.bool(forKey: Preferences.Key.alertsEnabled),
              let summary = reportToShow(now: now),
              let nine = Calendar.current.date(byAdding: .hour, value: 9, to: UsageTracker.weekStart(containing: now)), now >= nine,
              UserDefaults.standard.double(forKey: Key.notifiedWeek) != summary.weekStart.timeIntervalSince1970
        else { return }
        let choresOn = UserDefaults.standard.bool(forKey: Preferences.Key.choresEnabled)
        isPostingReport = true
        Task {
            defer { isPostingReport = false }
            let sent = await notifier.weeklyReport(
                summary, change: summary.scoreChange(from: previous(of: summary)),
                suggestions: summary.suggestions(choresEnabled: choresOn).count
            )
            if sent {
                UserDefaults.standard.set(summary.weekStart.timeIntervalSince1970, forKey: Key.notifiedWeek)
            }
        }
    }

    // MARK: Watch

    func ignore(appAt bundlePath: String) {
        Preferences.watchIgnoredApps.insert(bundlePath)
        watchdog.settings = Preferences.watchdogSettings
    }

    /// Bundle paths of apps with a Dock presence (the ones a user can quit), minus Osin itself.
    private static func regularAppPaths() -> Set<String> {
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let path = app.bundleURL?.standardizedFileURL.path, path != own else { return nil }
            return path
        })
    }

    private func watch(_ snapshot: SystemSnapshot) {
        watchdog.settings = Preferences.watchdogSettings
        guard watchdog.settings.enabled else {
            _ = watchdog.evaluate([], at: snapshot.date)
            return
        }
        let regular = Self.regularAppPaths()
        let apps = snapshot.processes.filter { group in
            group.bundlePath.map { regular.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? false
        }
        let excluded = Set(keepAwake.session?.watchedProcess.map { [$0.pid] } ?? [])
        let before = watchdog.lastAlerts
        let alerts = watchdog.evaluate(apps, at: snapshot.date, excluding: excluded)
        guard !alerts.isEmpty else { return }
        // Not shown now: undo the cooldown, so it fires once notifications are allowed again.
        guard UserDefaults.standard.bool(forKey: Preferences.Key.alertsEnabled), snapshot.date >= watchQuietUntil else {
            watchdog.restoreCooldowns(for: alerts, firedAt: snapshot.date, previous: before)
            return
        }
        Task {
            let status = await Notifier.authorizationStatus()
            guard status == .authorized || status == .provisional else {
                watchdog.restoreCooldowns(for: alerts, firedAt: snapshot.date, previous: before)
                watchQuietUntil = Date().addingTimeInterval(600)
                return
            }
            var unsent: [WatchdogAlert] = []
            for alert in alerts where await !notifier.watch(alert) {
                unsent.append(alert)
            }
            // Not accepted by macOS: no cooldown, so it can be told later.
            watchdog.restoreCooldowns(for: unsent, firedAt: snapshot.date, previous: before)
            saveWatchHistory()
        }
    }

    private static func loadWatchHistory() -> [String: Date] {
        let saved = UserDefaults.standard.dictionary(forKey: Key.watchHistory) as? [String: Double] ?? [:]
        return saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveWatchHistory() {
        // Entries older than the cooldown no longer matter.
        let recent = watchdog.lastAlerts.filter { Date().timeIntervalSince($0.value) < Watchdog.cooldown }
        UserDefaults.standard.set(recent.mapValues(\.timeIntervalSince1970), forKey: Key.watchHistory)
    }
}

#if DEBUG
    extension Housekeeper {
        /// Shows a finished weekly report built from `DemoData` (README screenshots).
        func loadDemo(_ demo: [WeeklySummary]) {
            summaries = demo
            dismissedWeek = nil
        }
    }
#endif
