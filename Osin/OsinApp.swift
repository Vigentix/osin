import SwiftUI

@main
struct OsinApp: App {
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(monitor)
        } label: {
            MenuBarLabel(level: monitor.snapshot?.health.level)
                .task { monitor.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .environment(monitor)
                .onAppear { monitor.setVisible(.dashboard, true) }
                .onDisappear { monitor.setVisible(.dashboard, false) }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
        }
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}
