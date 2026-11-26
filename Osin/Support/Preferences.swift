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
            Key.automaticUpdateChecks: true
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

    /// Alerts are only evaluated, and their cooldowns saved, when macOS will actually show them:
    /// the permission is read fresh for every sample, right before deciding.
    func handle(_ snapshot: SystemSnapshot) {
        Task {
            let status = await Self.authorizationStatus()
            guard status == .authorized || status == .provisional else { return }
            evaluator.settings = Preferences.alertSettings
            let alerts = evaluator.evaluate(AlertReading(snapshot: snapshot), at: Date())
            for alert in alerts {
                post(alert, snapshot: snapshot)
            }
            if !alerts.isEmpty {
                saveHistory()
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
