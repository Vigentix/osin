import AppKit
import OsinCore
import SwiftUI
import UserNotifications

struct OsinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appDelegate.monitor)
                .environment(appDelegate.scan)
                .environment(appDelegate.navigator)
                .environment(appDelegate.keepAwake)
                .environment(appDelegate.housekeeper)
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
                .environment(appDelegate.housekeeper)
                .environment(appDelegate.spaceLens)
                .environment(appDelegate.agent)
                .environment(appDelegate.aiProposals)
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
                .environment(appDelegate.housekeeper)
                .environment(appDelegate.agent)
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
    let spaceLens = SpaceLensModel()
    let agent = AgentRunner()
    let aiProposals = AIProposalsModel()
    let updater: Updater
    let housekeeper: Housekeeper
    private let notifier: Notifier
    private let onboarding = OnboardingWindowController()

    override init() {
        // Defaults first: the updater and notifier read preferences when they are created.
        Preferences.registerDefaults()
        updater = Updater()
        notifier = Notifier()
        housekeeper = Housekeeper(monitor: monitor, scan: scan, keepAwake: keepAwake, notifier: notifier)
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        Preferences.applyDockIcon()
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        var measuredStorage = false
        monitor.onSnapshot = { [notifier, housekeeper, weak self] snapshot in
            notifier.handle(snapshot)
            housekeeper.handle(snapshot)
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
        scan.onFreed = { [housekeeper] bytes in housekeeper.recordFreed(bytes) }
        spaceLens.trasher = { [scan] item in await scan.trashSelected(item) }
        aiProposals.trasher = { [scan] items in await scan.trashSelectedItems(items) }
        aiProposals.startListening { [notifier] proposal in notifier.aiProposal(proposal) }
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
            // `--open-dashboard`: open the dashboard at launch (performance measurements).
            if arguments.contains("--open-dashboard") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    NotificationCenter.default.post(name: .osinOpenDashboard, object: nil)
                }
            }
            if let directory = SnapshotRenderer.outputDirectory {
                Task {
                    await SnapshotRenderer.run(
                        monitor: monitor,
                        scan: scan,
                        keepAwake: keepAwake,
                        housekeeper: housekeeper,
                        spaceLens: spaceLens,
                        agent: agent,
                        aiProposals: aiProposals,
                        into: directory
                    )
                }
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

    func applicationWillTerminate(_: Notification) {
        housekeeper.saveUsage()
        agent.stopNow()
    }

    /// Clicking an alert opens the page that helps with it; Watch buttons quit or ignore the app.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let bundlePath = response.notification.request.content.userInfo[Notifier.bundlePathKey] as? String
        await MainActor.run {
            switch action {
            case Notifier.Action.quit:
                if let bundlePath {
                    AppControl.quit(bundlePath: bundlePath)
                }
                return
            case Notifier.Action.ignore:
                if let bundlePath {
                    housekeeper.ignore(appAt: bundlePath)
                }
                return
            case UNNotificationDismissActionIdentifier:
                return
            default:
                break
            }
            let destination = Notifier.destination(forNotification: identifier)
            navigator.section = destination.section
            navigator.cleanupTab = destination.cleanupTab
            navigator.showsWeeklyReport = destination.showsWeeklyReport
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
    /// Opens the weekly report sheet on the Overview (from the Monday notification).
    var showsWeeklyReport = false
}

extension Notification.Name {
    static let osinShowOnboarding = Notification.Name("OsinShowOnboarding")
    /// Opens the dashboard on `Navigator.section` (from places without `openWindow`, like notifications).
    static let osinOpenDashboard = Notification.Name("OsinOpenDashboard")
}

enum WindowID {
    static let dashboard = "dashboard"
}
