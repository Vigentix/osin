import AppKit
import OsinCore
import SwiftUI

/// Menu bar popover: score, four metric tiles, network, top memory users.
struct PopoverView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tiles
            network
            smartScanCard
            topProcesses
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 368)
        .onAppear { monitor.setVisible(.popover, true) }
        .onDisappear { monitor.setVisible(.popover, false) }
    }

    // MARK: Sections

    private var header: some View {
        let report = monitor.snapshot?.health
        return HStack(spacing: 14) {
            HealthRing(score: report?.score, level: report?.level)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(report))
                    .font(.headline)
                if let disk = monitor.snapshot?.disk {
                    Text("\(Format.storage(disk.availableBytes)) free of \(Format.storage(disk.totalBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(MachineInfo.computerName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                cpuTile
                memoryTile
            }
            GridRow {
                diskTile
                batteryTile
            }
        }
    }

    @ViewBuilder private var cpuTile: some View {
        let cpu = monitor.snapshot?.cpu
        MetricTile(
            title: "CPU",
            systemImage: "cpu",
            detail: cpuDetail(cpu),
            trend: .sparkline(monitor.cpuHistory.values, Brand.accent)
        ) {
            Text(cpu.map { Format.percent($0.total) } ?? "–")
        }
    }

    @ViewBuilder private var memoryTile: some View {
        let memory = monitor.snapshot?.memory
        MetricTile(
            title: "Memory",
            systemImage: "memorychip",
            detail: memory.map(memoryDetail) ?? "",
            trend: .sparkline(monitor.memoryHistory.values, memory?.pressure.color ?? .secondary),
            highlight: memory.flatMap { $0.pressure == .normal ? nil : $0.pressure.color }
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let memory {
                    Text(memory.pressure.title)
                    Circle()
                        .fill(memory.pressure.color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                } else {
                    Text("–")
                }
            }
        }
    }

    @ViewBuilder private var diskTile: some View {
        let disk = monitor.snapshot?.disk
        let color = disk.map { DiskLevel($0).color } ?? .secondary
        MetricTile(
            title: "Disk",
            systemImage: "internaldrive",
            detail: disk.map { String(localized: "\(Format.storage($0.availableBytes)) free") } ?? "",
            trend: .bar(disk?.usedFraction ?? 0, color),
            highlight: color == .green ? nil : color
        ) {
            Text(disk.map { Format.percent($0.usedFraction) } ?? "–")
                .foregroundStyle(color == .green ? Color.primary : color)
        }
    }

    @ViewBuilder private var batteryTile: some View {
        if let battery = monitor.snapshot?.battery {
            MetricTile(
                title: "Battery",
                systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                detail: batteryDetail(battery),
                trend: .bar(battery.chargeFraction, battery.chargeFraction < 0.2 ? .orange : .green)
            ) {
                Text(Format.percent(battery.chargeFraction))
            }
        } else {
            MetricTile(
                title: "Load",
                systemImage: "gauge.medium",
                detail: String(localized: "1-minute load average"),
                trend: .none
            ) {
                Text(monitor.snapshot.map { $0.cpu.loadAverage.formatted(.number.precision(.fractionLength(2))) } ?? "–")
            }
        }
    }

    @ViewBuilder private var network: some View {
        if let network = monitor.snapshot?.network {
            HStack(spacing: 12) {
                Label("Network", systemImage: "network")
                    .foregroundStyle(.secondary)
                Spacer()
                Label(Format.rate(network.receiveBytesPerSecond), systemImage: "arrow.down")
                Label(Format.rate(network.sendBytesPerSecond), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .accessibilityElement(children: .combine)
        }
    }

    private var smartScanCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaim disk space")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text("Smart Scan arrives in an upcoming build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Smart Scan") {}
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .disabled(true)
        }
        .padding(12)
        .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.accent.opacity(0.3), lineWidth: 1)
        }
    }

    @ViewBuilder private var topProcesses: some View {
        let top = (monitor.snapshot?.topByMemory ?? []).prefix(3)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Using most memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(top) { group in
                    ProcessRow(group: group)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Dashboard") {
                openWindow(id: WindowID.dashboard)
                NSApp.activate()
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(Text("Settings"))
            Button("Quit Osin") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Text helpers

    private func headline(_ report: HealthReport?) -> String {
        guard let report else { return String(localized: "Measuring…") }
        let level = String(localized: report.level.title)
        guard let concern = report.primaryConcern else {
            return report.level == .good ? String(localized: "All good") : level
        }
        return String(localized: "\(level) — \(String(localized: concern.concernTitle))")
    }

    private func cpuDetail(_ cpu: CPUSnapshot?) -> String {
        guard let cpu else { return "" }
        if let performance = cpu.performance, let efficiency = cpu.efficiency {
            return String(localized: "P \(Format.percent(performance)) · E \(Format.percent(efficiency))")
        }
        return String(localized: "Load \(cpu.loadAverage.formatted(.number.precision(.fractionLength(2))))")
    }

    private func memoryDetail(_ memory: MemoryStats) -> String {
        let used = Format.memory(memory.usedBytes)
        let total = Format.memory(memory.physicalBytes)
        let swap = Format.memory(memory.swapUsedBytes)
        return String(localized: "\(used) / \(total) · swap \(swap)")
    }

    private func batteryDetail(_ battery: BatterySnapshot) -> String {
        switch (battery.health, battery.cycleCount) {
        case let (health?, cycles?):
            String(localized: "Health \(Format.percent(health)) · \(cycles) cycles")
        case let (health?, nil):
            String(localized: "Health \(Format.percent(health))")
        default:
            String(localized: battery.isOnACPower ? "On power adapter" : "On battery")
        }
    }
}
