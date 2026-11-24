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
    private var evaluator = AlertEvaluator(settings: Preferences.alertSettings)

    static func requestAuthorization() async -> Bool {
        await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func handle(_ snapshot: SystemSnapshot) {
        evaluator.settings = Preferences.alertSettings
        for alert in evaluator.evaluate(AlertReading(snapshot: snapshot), at: Date()) {
            post(alert, snapshot: snapshot)
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
enum Purge {
    @MainActor
    static func run() -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")?.executeAndReturnError(&error)
        return error == nil
    }
}
