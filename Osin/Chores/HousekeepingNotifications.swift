import AppKit
import OsinCore
import UserNotifications

/// Where clicking a notification takes the user.
struct NotificationDestination: Equatable {
    var section: DashboardSection
    var cleanupTab: CleanupTab = .smartScan
    var showsWeeklyReport = false
}

extension Notifier {
    enum Category {
        static let chore = "osin.chore"
        static let watch = "osin.watch"
        static let weekly = "osin.weekly"
    }

    enum Action {
        static let view = "osin.view"
        static let quit = "osin.watch.quit"
        static let ignore = "osin.watch.ignore"
        static let activity = "osin.watch.activity"
    }

    nonisolated static let bundlePathKey = "bundlePath"

    /// Buttons shown on chore, watch and weekly notifications.
    static func registerCategories() {
        let view = UNNotificationAction(identifier: Action.view, title: String(localized: "View"), options: [.foreground])
        let report = UNNotificationAction(identifier: Action.view, title: String(localized: "See Report"), options: [.foreground])
        let quit = UNNotificationAction(identifier: Action.quit, title: String(localized: "Quit App"), options: [.destructive])
        let ignore = UNNotificationAction(identifier: Action.ignore, title: String(localized: "Ignore This App"), options: [])
        let activity = UNNotificationAction(identifier: Action.activity, title: String(localized: "Open Activity"), options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Category.chore, actions: [view], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.weekly, actions: [report], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.watch, actions: [quit, ignore, activity], intentIdentifiers: [])
        ])
    }

    /// Where a notification (or its View button) leads.
    static func destination(forNotification identifier: String) -> NotificationDestination {
        if identifier == "osin.chore" {
            return NotificationDestination(section: .cleanup, cleanupTab: .history)
        }
        if identifier == "osin.weekly" {
            return NotificationDestination(section: .overview, showsWeeklyReport: true)
        }
        if identifier.hasPrefix("osin.watch.") {
            return NotificationDestination(section: .activity)
        }
        return NotificationDestination(section: section(forNotification: identifier))
    }

    /// A scheduled cleanup removed something. Not sent when there was nothing to clean.
    func choreDone(_ run: ChoreRun) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Osin cleaned up \(Format.storage(run.totalBytes))")
        content.body = run.failures > 0
            ? String(localized: "Scheduled cleanup removed caches and logs. \(run.failures) items could not be removed; see History.")
            : String(localized: "Scheduled cleanup removed caches and logs that apps rebuild. Details are in History.")
        content.categoryIdentifier = Category.chore
        deliver(UNNotificationRequest(identifier: "osin.chore", content: content, trigger: nil))
    }

    /// Monday's summary of last week.
    func weeklyReport(_ summary: WeeklySummary, change: Int?, suggestions: Int) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your week on this Mac")
        var parts: [String] = []
        if let score = summary.averageScore {
            switch change {
            case let .some(delta) where delta > 0: parts.append(String(localized: "Health averaged \(score), up \(delta)."))
            case let .some(delta) where delta < 0: parts.append(String(localized: "Health averaged \(score), down \(-delta)."))
            default: parts.append(String(localized: "Health averaged \(score)."))
            }
        }
        if summary.freedBytes > 0 {
            parts.append(String(localized: "Osin freed \(Format.storage(summary.freedBytes))."))
        }
        if suggestions > 0 {
            parts.append(String(localized: "\(suggestions) suggestions inside."))
        }
        content.body = parts.isEmpty ? String(localized: "See how your Mac did last week.") : parts.joined(separator: " ")
        content.categoryIdentifier = Category.weekly
        return await deliverNow(UNNotificationRequest(identifier: "osin.weekly", content: content, trigger: nil))
    }

    /// An app stayed busy or kept growing. The caller has already checked the permission.
    /// Returns whether macOS accepted it.
    func watch(_ alert: WatchdogAlert) async -> Bool {
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .highCPU:
            content.title = String(localized: "\(alert.name) has been busy for 5 minutes")
            content.body = String(
                localized: "It is using \(Format.cpuShare(alert.value)) CPU. Quit it if it is stuck, or ignore it if the work is expected."
            )
        case .memoryGrowth:
            content.title = String(localized: "\(alert.name) keeps using more memory")
            content.body = String(
                localized: "It grew by \(Format.memory(UInt64(alert.value))) in 30 minutes, which can mean a leak. Quitting and reopening it frees that memory."
            )
        }
        content.categoryIdentifier = Category.watch
        content.userInfo = [Self.bundlePathKey: alert.bundlePath]
        let identifier = "osin.watch.\(alert.kind.rawValue).\(alert.bundlePath)"
        return await Self.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

extension AppControl {
    /// Quits every running copy of the app at `bundlePath` (from a Watch notification).
    static func quit(bundlePath: String) {
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        for app in NSWorkspace.shared.runningApplications
            where app.bundleURL?.standardizedFileURL == url && app.activationPolicy == .regular
        {
            app.terminate()
        }
    }
}
