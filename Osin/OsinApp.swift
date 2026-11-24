import AppKit
import SwiftUI

@main
struct OsinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appDelegate.monitor)
        } label: {
            MenuBarLabel(level: appDelegate.monitor.snapshot?.health.level)
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .environment(appDelegate.monitor)
                .onAppear { appDelegate.monitor.setVisible(.dashboard, true) }
                .onDisappear { appDelegate.monitor.setVisible(.dashboard, false) }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
        }
    }
}

/// Owns app-wide services so they start at launch, independent of any view appearing
/// (the menu bar label is not rendered while the screen is locked).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_: Notification) {
        monitor.start()
        #if DEBUG
            if let directory = SnapshotRenderer.outputDirectory {
                Task { await SnapshotRenderer.run(monitor: monitor, into: directory) }
            }
        #endif
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}
