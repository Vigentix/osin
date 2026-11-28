import AppKit
import OsinCore
import ServiceManagement
import UserNotifications

/// UserDefaults keys. Views bind with `@AppStorage(Preferences.Key.x)`.
enum Preferences {
    enum Key {
        static let onboardingCompleted = "onboardingCompleted"
        static let showDockIcon = "showDockIcon"
        static let menuBarCPU = "menuBarCPU"
        static let menuBarMemory = "menuBarMemory"
        static let menuBarNetwork = "menuBarNetwork"
        static let alertsEnabled = "alertsEnabled"
        static let alertDiskThreshold = "alertDiskThreshold"
        static let alertMemory = "alertMemory"
        static let alertBattery = "alertBattery"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let keepAwakeOptions = "keepAwakeOptions"
        static let keepAwakeStopOnLowBattery = "keepAwakeStopOnLowBattery"
        static let keepAwakeLowBatteryThreshold = "keepAwakeLowBatteryThreshold"
        static let keepAwakeStopWhenHot = "keepAwakeStopWhenHot"
        static let keepAwakeStopWhenUnplugged = "keepAwakeStopWhenUnplugged"
        static let keepAwakeShortcut = "keepAwakeShortcut"
        static let choresEnabled = "choresEnabled"
        static let choreSchedule = "choreSchedule"
        static let choreExcludedRules = "choreExcludedRules"
        static let weeklyReportEnabled = "weeklyReportEnabled"
        static let watchEnabled = "watchEnabled"
        static let watchIgnoredApps = "watchIgnoredApps"
        static let choreKnownRules = "choreKnownRules"
        static let projectRoots = "projectRoots"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.onboardingCompleted: false,
            Key.showDockIcon: false,
            Key.menuBarCPU: false,
            Key.menuBarMemory: false,
            Key.menuBarNetwork: false,
            Key.alertsEnabled: true,
            Key.alertDiskThreshold: 0.10,
            Key.alertMemory: true,
            Key.alertBattery: true,
            Key.automaticUpdateChecks: true,
            Key.keepAwakeStopOnLowBattery: true,
            Key.keepAwakeLowBatteryThreshold: 0.20,
            Key.keepAwakeStopWhenHot: true,
            Key.keepAwakeStopWhenUnplugged: false,
            Key.keepAwakeShortcut: KeepAwakeShortcut.none.rawValue,
            Key.choresEnabled: false,
            Key.weeklyReportEnabled: true,
            Key.watchEnabled: true
        ])
    }

    static var alertSettings: AlertSettings {
        let defaults = UserDefaults.standard
        return AlertSettings(
            enabled: defaults.bool(forKey: Key.alertsEnabled),
            diskFreeThreshold: defaults.double(forKey: Key.alertDiskThreshold),
            memoryPressureEnabled: defaults.bool(forKey: Key.alertMemory),
            batteryHealthEnabled: defaults.bool(forKey: Key.alertBattery)
        )
    }

    static var keepAwakeRules: KeepAwakeRules {
        let defaults = UserDefaults.standard
        return KeepAwakeRules(
            stopOnLowBattery: defaults.bool(forKey: Key.keepAwakeStopOnLowBattery),
            lowBatteryThreshold: defaults.double(forKey: Key.keepAwakeLowBatteryThreshold),
            stopWhenHot: defaults.bool(forKey: Key.keepAwakeStopWhenHot),
            stopWhenUnplugged: defaults.bool(forKey: Key.keepAwakeStopWhenUnplugged)
        )
    }

    /// When scheduled chores run (Sunday 21:00 until changed).
    static var choreSchedule: ChoreSchedule {
        get {
            UserDefaults.standard.data(forKey: Key.choreSchedule).flatMap { try? JSONDecoder().decode(ChoreSchedule.self, from: $0) }
                ?? ChoreSchedule()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.choreSchedule)
        }
    }

    /// Safe rules the user unticked for chores. Stored as exclusions, so new safe rules are included.
    static var choreExcludedRules: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.choreExcludedRules) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Key.choreExcludedRules) }
    }

    /// Safe rules that existed before 0.5: chores include them unless unticked.
    static let originalChoreRules: Set<String> = [
        "xcode.derived-data",
        "xcode.device-support",
        "user.caches",
        "user.logs",
        "dev.package-caches"
    ]

    /// Safe rules the user has seen in Settings › Chores. Newer ones are skipped until turned on.
    static var choreKnownRules: Set<String> {
        get { UserDefaults.standard.stringArray(forKey: Key.choreKnownRules).map(Set.init) ?? originalChoreRules }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Key.choreKnownRules) }
    }

    /// Whether chores skip this rule: unticked, or added since the user last looked.
    static func choreSkips(_ ruleID: String) -> Bool {
        choreExcludedRules.contains(ruleID) || !choreKnownRules.contains(ruleID)
    }

    /// Extra project folders for cold projects and toolchain pins (Settings › Advanced).
    static var projectRoots: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: Key.projectRoots) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: Key.projectRoots) }
    }

    static var watchIgnoredApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.watchIgnoredApps) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Key.watchIgnoredApps) }
    }

    static var watchdogSettings: WatchdogSettings {
        WatchdogSettings(enabled: UserDefaults.standard.bool(forKey: Key.watchEnabled), ignoredApps: watchIgnoredApps)
    }

    @MainActor
    static func applyDockIcon() {
        let show = UserDefaults.standard.bool(forKey: Key.showDockIcon)
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}

/// Launch at login through `SMAppService` (PRD §6.9). Off by default.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Posts local notifications for health alerts. Nothing leaves the Mac.
@MainActor
final class Notifier {
    private static let historyKey = "alertHistory"
    private var evaluator = AlertEvaluator(settings: Preferences.alertSettings, lastAlerts: Notifier.loadHistory())

    /// Last alert times survive relaunches, so a worn battery is mentioned once a month, not every login.
    private static func loadHistory() -> [HealthAlert.Kind: Date] {
        let saved = UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        return saved.reduce(into: [:]) { result, entry in
            if let kind = HealthAlert.Kind(rawValue: entry.key) {
                result[kind] = Date(timeIntervalSince1970: entry.value)
            }
        }
    }

    private func saveHistory() {
        let saved = evaluator.lastAlerts.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value.timeIntervalSince1970 }
        UserDefaults.standard.set(saved, forKey: Self.historyKey)
    }

    /// Where clicking an alert takes the user.
    static func section(forNotification identifier: String) -> DashboardSection {
        switch identifier {
        case "osin.\(HealthAlert.Kind.lowDisk.rawValue)": .cleanup
        case "osin.\(HealthAlert.Kind.memoryPressure.rawValue)": .activity
        default: .system
        }
    }

    /// Reads the notification permission. Nonisolated on purpose: macOS calls the completion handler on a
    /// background queue, and with older SDKs (Xcode 16) a closure written inside this @MainActor class would
    /// be inferred as main-actor isolated, so Swift's runtime isolation check would stop the app.
    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Evaluates alerts for a sample. The notification permission is only read when an alert would
    /// actually fire (rarely), and cooldowns are only saved once macOS will show it.
    func handle(_ snapshot: SystemSnapshot) {
        evaluator.settings = Preferences.alertSettings
        // Every sample is evaluated, even with alerts off (nothing fires then), so memory-pressure
        // tracking stays current. The permission is read only when an alert would fire.
        let before = evaluator.lastAlerts
        let firedAt = Date()
        let alerts = evaluator.evaluate(AlertReading(snapshot: snapshot), at: firedAt)
        guard !alerts.isEmpty else { return }
        Task {
            let status = await Self.authorizationStatus()
            guard status == .authorized || status == .provisional,
                  UserDefaults.standard.bool(forKey: Preferences.Key.alertsEnabled)
            else {
                // Not shown: undo the cooldown it started, so it can fire once notifications are allowed.
                evaluator.restoreCooldowns(for: alerts.map(\.kind), firedAt: firedAt, previous: before)
                return
            }
            for alert in alerts {
                post(alert, snapshot: snapshot)
            }
            saveHistory()
        }
    }

    /// Tells the user Keep Awake ended and why. Skipped when they stopped it themselves.
    func keepAwakeEnded(_ reason: KeepAwakeStopReason, session: KeepAwakeSession, at end: Date) {
        guard reason != .stoppedByUser else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Keep Awake ended")
        content.body = reason.notificationBody(after: end.timeIntervalSince(session.startedAt))
        deliver(UNNotificationRequest(identifier: "osin.keepAwake.ended", content: content, trigger: nil))
    }

    /// The Mac slept during a session (lid closed, Apple menu, or low battery).
    func keepAwakeInterrupted() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your Mac slept during Keep Awake")
        content
            .body =
            String(
                localized: "Keep Awake prevents idle sleep only. Closing the lid still puts the Mac to sleep unless an external display is connected."
            )
        deliver(UNNotificationRequest(identifier: "osin.keepAwake.slept", content: content, trigger: nil))
    }

    /// Keep Awake notifications follow the same "Send notifications" switch as alerts.
    func deliver(_ request: sending UNNotificationRequest) {
        Task { await deliverNow(request) }
    }

    /// Posts the request if notifications are on and allowed. Returns whether macOS accepted it.
    @discardableResult
    func deliverNow(_ request: sending UNNotificationRequest) async -> Bool {
        guard UserDefaults.standard.bool(forKey: Preferences.Key.alertsEnabled) else { return false }
        let status = await Self.authorizationStatus()
        guard status == .authorized || status == .provisional else { return false }
        return await Self.add(request)
    }

    /// Nonisolated with a `@Sendable` handler for the same reason as `authorizationStatus()`.
    nonisolated static func add(_ request: sending UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().add(request) { @Sendable error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func post(_ alert: HealthAlert, snapshot: SystemSnapshot) {
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .lowDisk:
            content.title = String(localized: "Disk almost full")
            content.body = String(localized: "Only \(Format.storage(snapshot.disk.availableBytes)) free. Run Smart Scan to reclaim space.")
        case .memoryPressure:
            content.title = String(localized: "Memory pressure is critical")
            content.body = String(localized: "Your Mac is short on memory. Quit apps you are not using.")
        case .batteryHealth:
            content.title = String(localized: "Battery health is \(Format.percent(alert.reading))")
            content.body = String(localized: "Your battery holds less charge than when new. Consider a service check.")
        }
        let request = UNNotificationRequest(identifier: "osin.\(alert.kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Runs `/usr/sbin/purge` with administrator privileges (Settings › Advanced). Its effect is temporary (ADR 0005).
/// Runs `osascript` as a separate process so the app stays responsive during the password prompt and the purge.
enum Purge {
    static func run() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
