import OsinCore
import SwiftUI

/// "Last week on your Mac": shown on the Overview from Monday until the end of Wednesday.
struct WeeklyReportCard: View {
    @Environment(Housekeeper.self) private var housekeeper
    @Environment(Navigator.self) private var navigator
    let summary: WeeklySummary

    var body: some View {
        let change = summary.scoreChange(from: housekeeper.previous(of: summary))
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemName: "calendar", tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last week on your Mac").font(.system(size: 15, weight: .semibold))
                    Text(WeeklyReportSheet.range(of: summary)).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Button("Got it") {
                    withAnimation(Motion.standard) { housekeeper.dismiss(summary) }
                }
                .buttonStyle(GhostButtonStyle())
                Button("See report") { navigator.showsWeeklyReport = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 0) {
                stat(title: "Health", value: summary.averageScore.map { "\($0)" } ?? "—", change: change)
                divider
                stat(title: "Freed", value: Format.storage(summary.freedBytes))
                divider
                stat(
                    title: "Memory strained",
                    value: summary.pressureMinutes > 0 ? Format.duration(Double(summary.pressureMinutes) * 60) : "—"
                )
                divider
                stat(title: "Keep Awake", value: summary.keepAwakeHours > 0 ? Format.duration(summary.keepAwakeHours * 3600) : "—")
            }
            if let first = summary.suggestions(choresEnabled: UserDefaults.standard.bool(forKey: Preferences.Key.choresEnabled)).first {
                HStack(spacing: 8) {
                    Image(systemName: first.icon).foregroundStyle(first.tint)
                    Text(first.text).foregroundStyle(Theme.text2)
                }
                .font(.system(size: 12))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 34).padding(.horizontal, 18)
    }

    private func stat(title: LocalizedStringKey, value: String, change: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                if let change, change != 0 {
                    ScoreChange(change: change)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "+5" in green or "−3" in amber, next to an average score.
struct ScoreChange: View {
    let change: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: change > 0 ? "arrow.up" : "arrow.down")
            Text(verbatim: "\(abs(change))")
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(change > 0 ? Theme.goodText : Theme.fairText)
        .accessibilityLabel(change > 0 ? Text("up \(change) from the week before") : Text("down \(-change) from the week before"))
    }
}

/// The full weekly report: score trend, what Osin did, the busiest apps and what to do next.
struct WeeklyReportSheet: View {
    @Environment(Housekeeper.self) private var housekeeper
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Key.choresEnabled) private var choresEnabled = false

    static func range(of summary: WeeklySummary) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: summary.weekEnd()) ?? summary.weekStart
        return (summary.weekStart ..< last).formatted(.interval.month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = housekeeper.reportToShow() ?? housekeeper.summaries.last {
                ScrollView {
                    report(summary)
                        .padding(28)
                }
            } else {
                empty
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 760)
        .background(Theme.background)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            IconTile(systemName: "calendar", tint: Theme.accent, size: 44)
            Text("Your first report arrives on Monday").font(.system(size: 17, weight: .semibold))
            Text("Osin sums up each week: how healthy your Mac was, what it cleaned and which apps were busiest.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func report(_ summary: WeeklySummary) -> some View {
        let change = summary.scoreChange(from: housekeeper.previous(of: summary))
        let suggestions = summary.suggestions(choresEnabled: choresEnabled)
        return VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your week on this Mac").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                Text(Self.range(of: summary)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Average health").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(summary.averageScore.map { "\($0)" } ?? "—")
                            .font(.system(size: 44, weight: .bold).monospacedDigit())
                        if let change, change != 0 {
                            ScoreChange(change: change)
                        }
                    }
                }
                ScoreTrend(summaries: Array(housekeeper.summaries.filter { $0.weekStart <= summary.weekStart }.suffix(8)))
                    .frame(height: 64)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                tile("Freed", Format.storage(summary.freedBytes), icon: "sparkles")
                tile("Scheduled cleanups", "\(summary.choreRuns)", icon: "calendar.badge.clock")
                tile(
                    "Keep Awake",
                    summary.keepAwakeHours > 0 ? Format.duration(summary.keepAwakeHours * 3600) : "—",
                    icon: "cup.and.saucer"
                )
                tile(
                    "Memory strained",
                    summary.pressureMinutes > 0 ? Format.duration(Double(summary.pressureMinutes) * 60) : "—",
                    icon: "memorychip"
                )
                tile(
                    "Low on space",
                    summary.lowDiskDays > 0 ? String(localized: "\(summary.lowDiskDays) days") : "—",
                    icon: "internaldrive"
                )
                tile(
                    "Running hot",
                    summary.hotMinutes > 0 ? Format.duration(Double(summary.hotMinutes) * 60) : "—",
                    icon: "thermometer.medium"
                )
            }
            if !summary.topApps.isEmpty {
                topApps(summary.topApps)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Suggestions")
                if suggestions.isEmpty {
                    Text("Nothing to change. Your Mac had a good week.").foregroundStyle(Theme.text2)
                } else {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: suggestion.icon).foregroundStyle(suggestion.tint).frame(width: 18)
                            Text(suggestion.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.text3)
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func topApps(_ apps: [UsageTracker.AppShare]) -> some View {
        let most = apps.map(\.cpuHours).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Busiest apps")
            ForEach(apps, id: \.bundlePath) { app in
                HStack(spacing: 10) {
                    AppAvatar(name: app.name, bundlePath: app.bundlePath, size: 22)
                    Text(app.name).frame(width: 150, alignment: .leading).lineLimit(1)
                    UsageBar(fraction: most > 0 ? app.cpuHours / most : 0, color: Theme.accent, height: 6)
                    Text(String(localized: "\(app.cpuHours, format: .number.precision(.fractionLength(1))) h CPU"))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

/// Average health for recent weeks as bars, the newest highlighted.
private struct ScoreTrend: View {
    let summaries: [WeeklySummary]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(summaries.enumerated()), id: \.element.weekStart) { index, summary in
                let score = Double(summary.averageScore ?? 0)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(index == summaries.count - 1 ? Theme.accent : Theme.neutralSeries)
                    .frame(width: 14, height: max(4, 64 * (score - 40) / 60))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement()
        .accessibilityLabel(Text("Average health over the last \(summaries.count) weeks"))
    }
}

extension WeeklySummary.Suggestion {
    var text: String {
        switch self {
        case let .lowDisk(days):
            String(localized: "Free space ran low on \(days) days. Run Smart Scan or review large files.")
        case let .memoryStrain(minutes):
            String(localized: "Memory was strained for \(Format.duration(Double(minutes) * 60)). Quitting apps you are not using helps.")
        case .runningHot:
            String(localized: "Your Mac ran hot for over an hour. Activity shows which apps were busy.")
        case let .heavyApp(name, hours):
            String(localized: "\(name) used \(hours, format: .number.precision(.fractionLength(0))) hours of CPU time.")
        case .scheduleChores:
            String(localized: "Nothing was cleaned. Scheduled chores can clear caches for you (Settings › Chores).")
        }
    }

    var icon: String {
        switch self {
        case .lowDisk: "internaldrive"
        case .memoryStrain: "memorychip"
        case .runningHot: "thermometer.medium"
        case .heavyApp: "cpu"
        case .scheduleChores: "calendar.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .lowDisk, .memoryStrain, .runningHot: Theme.fair
        case .heavyApp, .scheduleChores: Theme.accent
        }
    }
}
