import OsinCore
import SwiftUI

/// Settings › Chores: scheduled cleanup of safe groups, and the weekly report.
struct ChoresSettings: View {
    @Environment(Housekeeper.self) private var housekeeper
    @AppStorage(Preferences.Key.choresEnabled) private var enabled = false
    @AppStorage(Preferences.Key.weeklyReportEnabled) private var weeklyReport = true
    @State private var schedule = Preferences.choreSchedule
    @State private var excluded = Preferences.choreExcludedRules
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    private let rules = ScanCoordinator.choreRules()

    var body: some View {
        Form {
            Section {
                Toggle("Clean up on a schedule", isOn: $enabled)
                    .onChange(of: enabled) { _, isOn in
                        if isOn {
                            housekeeper.armChores()
                            Task { _ = await Notifier.requestAuthorization() }
                        }
                    }
                Group {
                    Picker("Repeat", selection: $schedule.frequency) {
                        Text("Every day").tag(ChoreSchedule.Frequency.daily)
                        Text("Every week").tag(ChoreSchedule.Frequency.weekly)
                        Text("Every month").tag(ChoreSchedule.Frequency.monthly)
                    }
                    if schedule.frequency == .weekly {
                        Picker("On", selection: $schedule.weekday) {
                            ForEach(1 ... 7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                    }
                    if schedule.frequency == .monthly {
                        Picker("On day", selection: $schedule.dayOfMonth) {
                            ForEach(1 ... 28, id: \.self) { day in
                                Text(verbatim: "\(day)").tag(day)
                            }
                        }
                    }
                    DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                }
                .disabled(!enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Runs only while your Mac is plugged in and you have been away for 5 minutes. A missed run is caught up within a day."
                    )
                    if enabled, let next = housekeeper.nextChore {
                        Text("Next: \(next.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if enabled, !launchAtLogin {
                Section {
                    HStack {
                        Text("Chores only run while Osin is open. Open it at login so they still run after a restart.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open at Login") {
                            try? LaunchAtLogin.set(true)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            Section {
                ForEach(rules, id: \.id) { rule in
                    Toggle(isOn: included(rule.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: String.LocalizationValue(rule.name)))
                            Text(String(localized: String.LocalizationValue(rule.detail)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("What to clean")
            } footer: {
                Text(
                    "Only caches and logs that apps rebuild. Emptying the Trash, removing simulators and anything in Downloads always wait for you."
                )
            }
            .disabled(!enabled)
            if let last = housekeeper.choreRuns.last {
                Section("Last run") {
                    LabeledContent(last.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute())) {
                        Text(last.totalBytes > 0 ? Format.storage(last.totalBytes) : String(localized: "Nothing to clean"))
                    }
                }
            }
            Section {
                Toggle("Weekly report on Monday morning", isOn: $weeklyReport)
            } footer: {
                Text("A short summary of last week: average health, what was cleaned, the busiest apps and what to do next.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: schedule) { _, newValue in
            Preferences.choreSchedule = newValue
            housekeeper.armChores()
        }
        .onChange(of: excluded) { _, newValue in Preferences.choreExcludedRules = newValue }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.hour = parts.hour ?? schedule.hour
            schedule.minute = parts.minute ?? schedule.minute
        }
    }

    private func included(_ id: String) -> Binding<Bool> {
        Binding {
            !excluded.contains(id)
        } set: { isOn in
            if isOn {
                excluded.remove(id)
            } else {
                excluded.insert(id)
            }
        }
    }
}

/// Settings › Alerts › Watch apps.
struct WatchSettingsSection: View {
    @AppStorage(Preferences.Key.watchEnabled) private var enabled = true
    @State private var ignored = Preferences.watchIgnoredApps

    var body: some View {
        Section {
            Toggle("Tell me when an app stays busy or keeps growing", isOn: $enabled)
            ForEach(ignored.sorted(), id: \.self) { path in
                HStack(spacing: 8) {
                    AppAvatar(name: Self.name(of: path), bundlePath: path, size: 18)
                    Text(Self.name(of: path))
                    Spacer()
                    Button("Watch Again") {
                        // From the saved list: a notification may have ignored another app meanwhile.
                        var latest = Preferences.watchIgnoredApps
                        latest.remove(path)
                        Preferences.watchIgnoredApps = latest
                        ignored = latest
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        } header: {
            Text("Watch apps")
        } footer: {
            Text(
                // swiftlint:disable:next line_length
                "An app using over 80% CPU for 5 minutes, or growing by 2 GB in 30 minutes. At most once a day per app. Apps you ignore from a notification are listed here."
            )
        }
        .onAppear { ignored = Preferences.watchIgnoredApps }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let latest = Preferences.watchIgnoredApps
            if latest != ignored {
                ignored = latest
            }
        }
    }

    static func name(of bundlePath: String) -> String {
        URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
    }
}
