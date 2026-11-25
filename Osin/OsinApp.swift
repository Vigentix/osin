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
            }
        }

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
        // Read-only scan so the Overview and popover can offer one-click cleaning right away.
        Task {
            try? await Task.sleep(for: .seconds(5))
            scan.backgroundScan()
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
}

enum WindowID {
    static let dashboard = "dashboard"
}
