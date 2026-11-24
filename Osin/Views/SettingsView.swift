import AppKit
import OsinCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AlertSettingsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.showDockIcon) private var showDockIcon = false
    @AppStorage(Preferences.Key.menuBarCPU) private var menuBarCPU = false
    @AppStorage(Preferences.Key.menuBarMemory) private var menuBarMemory = false
    @AppStorage(Preferences.Key.menuBarNetwork) private var menuBarNetwork = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Osin at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show icon in the Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in Preferences.applyDockIcon() }
            }
            Section("Menu bar") {
                Toggle("Show CPU usage", isOn: $menuBarCPU)
                Toggle("Show memory pressure", isOn: $menuBarMemory)
                Toggle("Show network speed", isOn: $menuBarNetwork)
                Text("The coloured dot always shows overall health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettingsView: View {
    @AppStorage(Preferences.Key.alertsEnabled) private var enabled = true
    @AppStorage(Preferences.Key.alertDiskThreshold) private var diskThreshold = 0.10
    @AppStorage(Preferences.Key.alertMemory) private var memory = true
    @AppStorage(Preferences.Key.alertBattery) private var battery = true

    var body: some View {
        Form {
            Section {
                Toggle("Send notifications", isOn: $enabled)
                    .onChange(of: enabled) { _, isOn in
                        if isOn {
                            Task { _ = await Notifier.requestAuthorization() }
                        }
                    }
            } footer: {
                Text("Osin never cleans automatically. It only tells you when something needs attention.")
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Disk free below \(Format.percent(diskThreshold))")
                    Slider(value: $diskThreshold, in: 0.05 ... 0.25, step: 0.01) {
                        Text("Disk free threshold")
                    }
                    .labelsHidden()
                }
                Toggle("Memory pressure critical for over a minute", isOn: $memory)
                Toggle("Battery health below 80%", isOn: $battery)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @AppStorage(Preferences.Key.automaticUpdateChecks) private var automaticUpdateChecks = true
    @State private var purgeResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $automaticUpdateChecks)
            } footer: {
                Text("The update check is the only network request Osin makes.")
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purge disk cache")
                        Text(
                            // swiftlint:disable:next line_length
                            "Frees inactive memory using macOS's purge tool. The effect is temporary: macOS refills the cache because unused RAM is wasted RAM. Requires an administrator password."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Purge…") {
                        purgeResult = Purge.run() ? String(localized: "Done.") : String(localized: "Cancelled or failed.")
                    }
                }
                if let purgeResult {
                    Text(purgeResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Memory")
            }
            Section {
                Button("Show welcome screens again") {
                    NotificationCenter.default.post(name: .osinShowOnboarding, object: nil)
                }
                Button("Open data folder in Finder") {
                    if let url = try? CleanupLog.defaultURL().deletingLastPathComponent() {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Cleanup history and metrics stay on this Mac.")
            }
        }
        .formStyle(.grouped)
    }
}
