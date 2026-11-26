import OsinCore
import SwiftUI

/// System: CPU, memory, disk, network and battery in detail over 1 h / 24 h / 7 d.
struct SystemView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var range: SystemMonitor.HistoryRange = .hour
    @State private var points: [HistoryPoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "System", subtitle: MachineInfo.summary) {
                    SegmentedPicker(options: SystemMonitor.HistoryRange.allCases.map { ($0, $0.title) }, selection: $range)
                }
                if let snapshot = monitor.snapshot {
                    cpu(snapshot)
                    memory(snapshot)
                    HStack(alignment: .top, spacing: 18) {
                        disk(snapshot)
                        network(snapshot)
                    }
                    if let battery = snapshot.battery {
                        self.battery(battery)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("System"))
        .task(id: HistoryReloadKey(range: range, stamp: monitor.snapshot?.date)) {
            points = await monitor.historyPoints(range)
        }
    }

    private func headline(_ title: LocalizedStringKey, value: String, color: Color = Theme.text, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Text(value)
                .font(.system(size: 40, weight: .bold))
                .tracking(-1)
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 180, alignment: .leading)
    }

    private func cpu(_ snapshot: SystemSnapshot) -> some View {
        Card(radius: 16) {
            HStack(alignment: .top, spacing: 24) {
                headline(
                    "CPU",
                    value: Format.percent(snapshot.cpu.total),
                    detail: String(localized: "Load \(snapshot.cpu.loadAverage.formatted(.number.precision(.fractionLength(2))))")
                )
                TimeSeriesChart(points: points, series: [.init(name: "CPU", color: Theme.accent) { $0.cpu }])
                    .frame(maxWidth: .infinity)
                perCore(snapshot.cpu)
            }
        }
    }

    private func perCore(_ cpu: CPUSnapshot) -> some View {
        let topology = CoreTopology.current()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Per core").font(.system(size: 12)).foregroundStyle(Theme.text2)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { index, usage in
                    let efficiency = topology?.efficiency.contains(index) ?? false
                    RoundedRectangle(cornerRadius: 3)
                        .fill(efficiency ? Theme.teal : Theme.accent)
                        .frame(height: max(4, 110 * usage))
                        .frame(maxWidth: .infinity, maxHeight: 110, alignment: .bottom)
                        .animation(.spring(duration: 0.5), value: usage)
                }
            }
            .frame(height: 110)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Per core usage"))
            if let performance = cpu.performance, let efficiency = cpu.efficiency {
                HStack {
                    Text("E \(Format.percent(efficiency))").foregroundStyle(Theme.teal)
                    Spacer()
                    Text("P \(Format.percent(performance))").foregroundStyle(Theme.accentText)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
        .frame(width: 200)
    }

    private func memory(_ snapshot: SystemSnapshot) -> some View {
        let memory = snapshot.memory
        return Card(radius: 16) {
            HStack(alignment: .top, spacing: 24) {
                headline(
                    "Memory pressure",
                    value: String(localized: memory.pressure.title),
                    color: memory.pressure.textColor,
                    detail: String(localized: memory.pressure == .normal
                        ? "macOS is managing memory well. Free RAM is not the goal."
                        : "Quitting apps you are not using will help.")
                )
                TimeSeriesChart(
                    points: points,
                    series: [.init(name: "Memory", color: memory.pressure.color) { $0.memoryUsed }],
                    bands: [(0.8 ... 1, Theme.poor), (0.65 ... 0.8, Theme.fair)]
                )
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    StackedBar(segments: [
                        .init(id: "app", value: Double(memory.appBytes), color: Theme.accent),
                        .init(id: "wired", value: Double(memory.wiredBytes), color: Theme.blue),
                        .init(id: "compressed", value: Double(memory.compressedBytes), color: Theme.teal),
                        .init(id: "cached", value: Double(memory.cachedBytes), color: Theme.neutralSeries)
                    ], height: 10)
                    LegendRow(color: Theme.accent, label: "App", value: Format.memory(memory.appBytes))
                    LegendRow(color: Theme.blue, label: "Wired", value: Format.memory(memory.wiredBytes))
                    LegendRow(color: Theme.teal, label: "Compressed", value: Format.memory(memory.compressedBytes))
                    LegendRow(color: Theme.neutralSeries, label: "Cached files", value: Format.memory(memory.cachedBytes))
                    LegendRow(
                        color: .clear, label: "Swap used", value: Format.memory(memory.swapUsedBytes),
                        valueColor: memory.swapUsedBytes > memory.physicalBytes / 4 ? Theme.fairText : Theme.text
                    )
                }
                .frame(width: 200)
            }
        }
    }

    private func disk(_ snapshot: SystemSnapshot) -> some View {
        let disk = snapshot.disk
        let level = DiskLevel(disk)
        return Card(radius: 16, borderColor: level == .ok ? Theme.border : level.color.opacity(0.3)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk · \(MachineInfo.bootVolumeName)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
                Text("\(Format.storage(disk.availableBytes)) free").font(.system(size: 22, weight: .bold)).monospacedDigit()
                    .foregroundStyle(level.textColor)
            }
            UsageBar(fraction: disk.usedFraction, color: level.color, height: 10)
            TimeSeriesChart(
                points: points,
                series: [
                    .init(name: "Read", color: Theme.blue) { $0.diskRead },
                    .init(name: "Write", color: Theme.fair) { $0.diskWrite }
                ],
                domain: nil,
                format: { Format.rate($0) },
                height: 110,
                filled: false
            )
            HStack(spacing: 16) {
                LegendRow(color: Theme.blue, label: "Read", value: Format.rate(disk.readBytesPerSecond))
                LegendRow(color: Theme.fair, label: "Write", value: Format.rate(disk.writeBytesPerSecond))
            }
        }
    }

    private func network(_ snapshot: SystemSnapshot) -> some View {
        Card(radius: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Network").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
                Text(Format.rate(snapshot.network.receiveBytesPerSecond + snapshot.network.sendBytesPerSecond))
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
            }
            TimeSeriesChart(
                points: points,
                series: [
                    .init(name: "Download", color: Theme.accent) { $0.networkReceive },
                    .init(name: "Upload", color: Theme.teal) { $0.networkSend }
                ],
                domain: nil,
                format: { Format.rate($0) },
                height: 136
            )
            HStack(spacing: 16) {
                LegendRow(color: Theme.accent, label: "Download", value: Format.rate(snapshot.network.receiveBytesPerSecond))
                LegendRow(color: Theme.teal, label: "Upload", value: Format.rate(snapshot.network.sendBytesPerSecond))
            }
        }
    }

    private func battery(_ battery: BatterySnapshot) -> some View {
        Card(radius: 16) {
            HStack(alignment: .center, spacing: 24) {
                headline(
                    "Battery",
                    value: Format.percent(battery.chargeFraction),
                    detail: String(localized: battery.isCharging ? "Charging" : (battery.isOnACPower ? "On power adapter" : "On battery"))
                )
                TimeSeriesChart(points: points, series: [.init(name: "Charge", color: Theme.good) { $0.batteryCharge }], height: 110)
                    .frame(maxWidth: .infinity)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Health").foregroundStyle(Theme.text2)
                        Text(battery.health.map { Format.percent($0) } ?? "–")
                            .fontWeight(.semibold)
                            .foregroundStyle((battery.health ?? 1) < 0.85 ? Theme.fairText : Theme.text)
                    }
                    GridRow {
                        Text("Cycles").foregroundStyle(Theme.text2)
                        Text(battery.cycleCount.map { "\($0)" } ?? "–")
                    }
                    GridRow {
                        Text("Estimated; System Settings may differ by a few points. Service is advised below 80%.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(2)
                    }
                }
                .monospacedDigit()
                .frame(width: 220)
            }
        }
    }
}
