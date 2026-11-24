import OsinCore
import SwiftUI

struct BatteryView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var points: [HistoryPoint] = []

    var body: some View {
        Group {
            if let battery = monitor.snapshot?.battery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)], spacing: 14) {
                            chargeCard(battery)
                            healthCard(battery)
                            cyclesCard(battery)
                        }
                        Card(title: "Charge, last 24 hours") {
                            HistoryChart(points: points, series: .battery, color: .green, height: 180)
                        }
                    }
                    .padding(24)
                }
            } else if monitor.snapshot != nil {
                ContentUnavailableView("No battery", systemImage: "powerplug", description: Text("This Mac runs on mains power."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("Battery"))
        .task(id: HistoryReloadKey(range: .day, stamp: monitor.snapshot?.date)) {
            points = await monitor.historyPoints(.day)
        }
    }

    private func chargeCard(_ battery: BatterySnapshot) -> some View {
        Card(title: "Charge") {
            Text(Format.percent(battery.chargeFraction))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            UsageBar(fraction: battery.chargeFraction, color: battery.chargeFraction < 0.2 ? .orange : .green, height: 8)
            Label(
                battery.isCharging ? "Charging" : (battery.isOnACPower ? "On power adapter" : "On battery"),
                systemImage: battery.isOnACPower ? "powerplug" : "battery.50percent"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func healthCard(_ battery: BatterySnapshot) -> some View {
        Card(title: "Health") {
            if let health = battery.health {
                Text(Format.percent(health))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(health < 0.8 ? .orange : .primary)
                    .monospacedDigit()
                UsageBar(fraction: health, color: health < 0.8 ? .orange : .green, height: 8)
            } else {
                Text("Unknown").font(.title2)
            }
            Text(
                // swiftlint:disable:next line_length
                "Full-charge capacity compared with when new. Below 80%, consider a service check. Estimated; System Settings may differ by a few points."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cyclesCard(_ battery: BatterySnapshot) -> some View {
        Card(title: "Cycle count") {
            Text(battery.cycleCount.map { $0.formatted() } ?? "–")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("One cycle is using 100% of the battery's capacity, not necessarily in one go.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
