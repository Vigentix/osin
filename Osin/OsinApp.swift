import AppKit
import OsinCore
import SwiftUI
import UserNotifications

@main
struct OsinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appDelegate.monitor)
                .environment(appDelegate.scan)
                .environment(appDelegate.navigator)
                .environment(appDelegate.keepAwake)
        } label: {
            MenuBarLabel(monitor: appDelegate.monitor, keepAwake: appDelegate.keepAwake)
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .environment(appDelegate.monitor)
                .environment(appDelegate.scan)
                .environment(appDelegate.navigator)
                .environment(appDelegate.keepAwake)
                .onWindowVisibilityChange { appDelegate.monitor.setVisible(.dashboard, $0) }
                .onDisappear { appDelegate.monitor.setVisible(.dashboard, false) }
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Go") {
                ForEach(DashboardSection.allCases) { section in
                    Button {
                        appDelegate.navigator.section = section
                    } label: {
                        Text(section.title)
                    }
                    .keyboardShortcut(section.key, modifiers: .command)
                }
                Divider()
                Button("Rescan") {
                    appDelegate.navigator.section = .cleanup
                    appDelegate.navigator.cleanupTab = .smartScan
                    appDelegate.scan.start()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!appDelegate.scan.canStartScan)
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.updater)
                .environment(appDelegate.keepAwake)
        }
    }
}

/// Owns app-wide services so they start at launch, independent of any view appearing
/// (the menu bar label is not rendered while the screen is locked).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let monitor = SystemMonitor()
    let scan = ScanCoordinator()
    let navigator = Navigator()
    let keepAwake = KeepAwakeController()
    let updater: Updater
    private let notifier: Notifier
    private let onboarding = OnboardingWindowController()

    override init() {
        // Defaults first: the updater and notifier read preferences when they are created.
        Preferences.registerDefaults()
        updater = Updater()
        notifier = Notifier()
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        Preferences.applyDockIcon()
        UNUserNotificationCenter.current().delegate = self
        var measuredStorage = false
        monitor.onSnapshot = { [notifier, weak self] snapshot in
            notifier.handle(snapshot)
            guard let self, !measuredStorage else { return }
            measuredStorage = true
            monitor.refreshStorage(reclaimable: scan.safeReclaimableBytes ?? 0)
        }
        scan.onCleaned = { [weak self] in
            guard let self else { return }
            monitor.refreshNow()
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.monitor.refreshStorage(reclaimable: self.scan.safeReclaimableBytes ?? 0, force: true)
            }
        }
        scan.onScanFinished = { [weak self] in
            guard let self else { return }
            monitor.refreshStorage(reclaimable: scan.safeReclaimableBytes ?? 0)
        }
        keepAwake.isUIVisible = { [monitor] in monitor.isForeground }
        keepAwake.onEnded = { [notifier] reason, session, end in
            notifier.keepAwakeEnded(reason, session: session, at: end)
        }
        keepAwake.onSleptDuringSession = { [notifier] in notifier.keepAwakeInterrupted() }
        let shortcut = KeepAwakeShortcut(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.keepAwakeShortcut) ?? "") ?? .none
        GlobalHotKey.shared.register(shortcut) { [keepAwake] in keepAwake.toggle() }
        monitor.start()
        NotificationCenter.default.addObserver(forName: .osinShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
        #if DEBUG
            // `--keep-awake-seconds N`: start a short Keep Awake session (manual testing).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--keep-awake-seconds"), arguments.indices.contains(index + 1),
               let seconds = Double(arguments[index + 1])
            {
                keepAwake.start(KeepAwakeOptions(duration: .until(Date().addingTimeInterval(seconds))))
            }
            // `--keep-awake-pid N`: keep awake until that process ends (manual testing).
            if let index = arguments.firstIndex(of: "--keep-awake-pid"), arguments.indices.contains(index + 1),
               let pid = Int32(arguments[index + 1]), let watched = RunningProcesses.watched(pid: pid)
            {
                keepAwake.start(KeepAwakeOptions(mode: .awake, keepDisplayOn: false, duration: .process(watched)))
            }
            if let directory = SnapshotRenderer.outputDirectory {
                Task { await SnapshotRenderer.run(monitor: monitor, scan: scan, keepAwake: keepAwake, into: directory) }
                return
            }
        #endif
        if !UserDefaults.standard.bool(forKey: Preferences.Key.onboardingCompleted) {
            showOnboarding()
        }
        // Read-only scan so the Overview and popover can offer one-click cleaning right away.
        Task {
            try? await Task.sleep(for: .seconds(5))
            scan.backgroundScan()
        }
    }

    // MARK: Notifications

    /// Show alerts as banners even while Osin is the active app (dashboard or popover open).
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Clicking an alert opens the page that helps with it.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            navigator.section = Notifier.section(forNotification: identifier)
            navigator.cleanupTab = .smartScan
            NotificationCenter.default.post(name: .osinOpenDashboard, object: nil)
        }
    }

    private func showOnboarding() {
        onboarding.show {
            UserDefaults.standard.set(true, forKey: Preferences.Key.onboardingCompleted)
        }
    }
}

/// Which dashboard section is showing; lets the popover jump straight to Smart Scan.
@MainActor
@Observable
final class Navigator {
    var section: DashboardSection = .overview
    var cleanupTab: CleanupTab = .smartScan
}

extension Notification.Name {
    static let osinShowOnboarding = Notification.Name("OsinShowOnboarding")
    /// Opens the dashboard on `Navigator.section` (from places without `openWindow`, like notifications).
    static let osinOpenDashboard = Notification.Name("OsinOpenDashboard")
}

enum WindowID {
    static let dashboard = "dashboard"
}
