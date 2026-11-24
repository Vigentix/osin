import OsinCore
import SwiftUI

struct OverviewView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var range: SystemMonitor.HistoryRange = .hour
    @State private var points: [HistoryPoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                    scoreCard
                    cpuCard
                    memoryCard
                }
                storageCard
                checksCard
            }
            .padding(24)
        }
        .navigationTitle(Text("Overview"))
        .navigationSubtitle(Text(MachineInfo.computerName))
        .toolbar {
            Picker(selection: $range) {
                ForEach(SystemMonitor.HistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            } label: {
                Text("Range")
            }
            .pickerStyle(.segmented)
        }
        .task(id: HistoryReloadKey(range: range, stamp: monitor.snapshot?.date)) {
            points = await monitor.historyPoints(range)
        }
    }

    private var scoreCard: some View {
        let report = monitor.snapshot?.health
        return Card {
            HStack(alignment: .center, spacing: 18) {
                HealthRing(score: report?.score, level: report?.level, diameter: 128, lineWidth: 11)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What lowers the score")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(HealthComponent.allCases, id: \.self) { component in
                            if let points = report?.deductions[component] {
                                GridRow {
                                    Text(component.title)
                                    Text(points == 0 ? "0" : "−\(points)")
                                        .monospacedDigit()
                                        .foregroundStyle(points >= 5 ? (report?.level.color ?? .secondary) : .secondary)
                                        .gridColumnAlignment(.trailing)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    private var cpuCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.headline)
                Spacer()
                Text(monitor.snapshot.map { Format.percent($0.cpu.total) } ?? "–")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            HistoryChart(points: points, series: .cpu, color: Brand.accent)
        }
    }

    private var memoryCard: some View {
        let memory = monitor.snapshot?.memory
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory pressure").font(.headline)
                Spacer()
                if let memory {
                    Text(memory.pressure.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(memory.pressure.color)
                }
            }
            HistoryChart(points: points, series: .memory, color: memory?.pressure.color ?? .green)
            if let memory {
                Text("Used \(Format.memory(memory.usedBytes)) · Swap \(Format.memory(memory.swapUsedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var storageCard: some View {
        if let disk = monitor.snapshot?.disk {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Storage").font(.headline)
                    Text(verbatim: Format.storage(disk.totalBytes))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Format.storage(disk.availableBytes)) free")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(DiskLevel(disk).color)
                }
                UsageBar(fraction: disk.usedFraction, color: DiskLevel(disk).color, height: 10)
                Text("Disk read \(Format.rate(disk.readBytesPerSecond)) · write \(Format.rate(disk.writeBytesPerSecond))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checksCard: some View {
        Card(title: "Health checks") {
            ForEach(HealthCheck.all(for: monitor.snapshot)) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(check.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(check.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Plain-language findings shown on the Overview.
struct HealthCheck: Identifiable {
    let id: String
    let color: Color
    let message: String

    static func all(for snapshot: SystemSnapshot?) -> [HealthCheck] {
        guard let snapshot else { return [] }
        var checks: [HealthCheck] = []

        let disk = snapshot.disk
        let level = DiskLevel(disk)
        let free = Format.storage(disk.availableBytes)
        let used = Format.percent(disk.usedFraction)
        let diskMessage = switch level {
        case .critical: String(localized: "Disk is \(used) full. macOS slows down and updates can fail with this little space.")
        case .low: String(localized: "Disk is \(used) full. Consider freeing space soon.")
        case .ok: String(localized: "Disk has \(free) free.")
        }
        checks.append(HealthCheck(id: "disk", color: level.color, message: diskMessage))

        let memory = snapshot.memory
        let swap = Format.memory(memory.swapUsedBytes)
        let memoryMessage = switch memory.pressure {
        case .normal: String(localized: "Memory pressure is normal. Swap in use: \(swap).")
        case .warning: String(localized: "Memory pressure is elevated. Quitting heavy apps will help. Swap in use: \(swap).")
        case .critical: String(localized: "Memory pressure is critical. Quit apps you are not using. Swap in use: \(swap).")
        }
        checks.append(HealthCheck(id: "memory", color: memory.pressure.color, message: memoryMessage))

        if let deduction = snapshot.health.deductions[.cpu], deduction >= 5 {
            checks.append(HealthCheck(id: "cpu", color: .orange, message: String(localized: "CPU has been busy for several minutes.")))
        }

        if snapshot.thermal >= .serious {
            checks.append(HealthCheck(
                id: "thermal",
                color: .red,
                message: String(localized: "Your Mac is running hot and may be slowing itself down.")
            ))
        }

        if let battery = snapshot.battery, let health = battery.health {
            let percent = Format.percent(health)
            checks.append(HealthCheck(
                id: "battery",
                color: health < 0.8 ? .orange : .green,
                message: health < 0.8
                    ? String(localized: "Battery holds \(percent) of its original charge. Consider a service check.")
                    : String(localized: "Battery holds \(percent) of its original charge.")
            ))
        }
        return checks
    }
}

/// Disk fullness bands shared by the popover and dashboard.
enum DiskLevel {
    case ok
    case low
    case critical

    init(_ disk: DiskSnapshot) {
        let free = 1 - disk.usedFraction
        self = free < 0.05 ? .critical : (free < 0.20 ? .low : .ok)
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .low: .orange
        case .critical: .red
        }
    }
}

extension HealthComponent {
    var title: LocalizedStringResource {
        switch self {
        case .disk: "Disk free space"
        case .memory: "Memory & swap"
        case .cpu: "CPU load"
        case .thermal: "Thermal"
        case .battery: "Battery health"
        }
    }
}
