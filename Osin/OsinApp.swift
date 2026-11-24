import SwiftUI

@main
struct OsinApp: App {
    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .accessibilityLabel(Text("Osin"))
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
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
