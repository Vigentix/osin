import AppKit
import SwiftUI

@main
struct OsinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appDelegate.monitor)
                .environment(appDelegate.scan)
                .environment(appDelegate.navigator)
        } label: {
            MenuBarLabel(snapshot: appDelegate.monitor.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .environment(appDelegate.monitor)
                .environment(appDelegate.scan)
                .environment(appDelegate.navigator)
                .onAppear { appDelegate.monitor.setVisible(.dashboard, true) }
                .onDisappear { appDelegate.monitor.setVisible(.dashboard, false) }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environment(appDelegate.updater)
        }
    }
}

/// Owns app-wide services so they start at launch, independent of any view appearing
/// (the menu bar label is not rendered while the screen is locked).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()
    let scan = ScanCoordinator()
    let navigator = Navigator()
    let updater = Updater()
    private let notifier = Notifier()
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_: Notification) {
        Preferences.registerDefaults()
        Preferences.applyDockIcon()
        monitor.onSnapshot = { [notifier] snapshot in notifier.handle(snapshot) }
        monitor.start()
        NotificationCenter.default.addObserver(forName: .osinShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
        #if DEBUG
            if let directory = SnapshotRenderer.outputDirectory {
                Task { await SnapshotRenderer.run(monitor: monitor, scan: scan, into: directory) }
                return
            }
        #endif
        if !UserDefaults.standard.bool(forKey: Preferences.Key.onboardingCompleted) {
            showOnboarding()
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
}

extension Notification.Name {
    static let osinShowOnboarding = Notification.Name("OsinShowOnboarding")
}

enum WindowID {
    static let dashboard = "dashboard"
}
