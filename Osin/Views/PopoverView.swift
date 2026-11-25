import AppKit
import OsinCore
import SwiftUI

/// Menu bar popover: score and reason, quick actions, four metrics, network, heaviest apps.
struct PopoverView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(ScanCoordinator.self) private var scan
    @Environment(Navigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actions
            tiles
            network
            apps
            footer
        }
        .padding(16)
        .frame(width: 376)
        .background(Theme.surface)
        .onAppear { monitor.setVisible(.popover, true) }
        .onDisappear { monitor.setVisible(.popover, false) }
    }

    private func openDashboard(_ section: DashboardSection) {
        navigator.section = section
        openWindow(id: WindowID.dashboard)
        NSApp.activate()
    }

    // MARK: Sections

    private var header: some View {
        let snapshot = monitor.snapshot
        let report = snapshot?.health
        return HStack(spacing: 14) {
            HealthRing(score: report?.score, level: report?.level, diameter: 74, lineWidth: 7, showsLabel: false)
            VStack(alignment: .leading, spacing: 2) {
                if let report {
                    Text(report.level.eyebrow).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(report.level.textColor)
                    Text(report.primaryConcern.map { String(localized: $0.concernTitle) } ?? String(localized: "All good"))
                        .font(.system(size: 16, weight: .bold))
                }
                if let disk = snapshot?.disk {
                    Text("\(Format.storage(disk.availableBytes)) free of \(Format.storage(disk.totalBytes))")
                        .monospacedDigit()
                        .foregroundStyle(Theme.text2)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let bytes = scan.safeReclaimableBytes, bytes >= Recommendations.minimumCleanBytes {
                Button {
                    openDashboard(.cleanup)
                    navigator.cleanupTab = .smartScan
                    scan.cleanSafeNow(score: monitor.snapshot?.health.score, free: monitor.snapshot?.disk.availableBytes)
                } label: {
                    Text("Clean \(Format.storage(bytes))").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    openDashboard(.cleanup)
                    navigator.cleanupTab = .smartScan
                    scan.start()
                } label: {
                    Text("Smart Scan").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            iconButton("waveform.path.ecg", label: "Open Activity") { openDashboard(.activity) }
            iconButton("square.grid.2x2", label: "Open Dashboard") { openDashboard(.overview) }
        }
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }

    private var tiles: some View {
        let snapshot = monitor.snapshot
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("CPU", value: snapshot.map { Format.percent($0.cpu.total) } ?? "–") {
                    SparkChart(values: monitor.cpuHistory.values, color: Theme.accent, filled: false)
                }
                tile(
                    "Memory",
                    value: snapshot.map { String(localized: $0.memory.pressure.title) } ?? "–",
                    color: snapshot?.memory.pressure.textColor ?? Theme.text
                ) {
                    Text(snapshot
                        .map {
                            "\(Format.memory($0.memory.usedBytes)) / \(Format.memory($0.memory.physicalBytes)) · swap \(Format.memory($0.memory.swapUsedBytes))"
                        } ?? "")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            GridRow {
                let level = snapshot.map { DiskLevel($0.disk) }
                tile(
                    "Disk",
                    value: snapshot.map { Format.percent($0.disk.usedFraction) } ?? "–",
                    color: level?.textColor ?? Theme.text,
                    highlight: level.flatMap { $0 == .ok ? nil : $0.color }
                ) {
                    UsageBar(fraction: snapshot?.disk.usedFraction ?? 0, color: level?.color ?? Theme.text3)
                }
                if let battery = snapshot?.battery {
                    tile("Battery", value: Format.percent(battery.chargeFraction)) {
                        Text(battery.health
                            .map {
                                String(
                                    localized: "\(battery.isOnACPower ? String(localized: "On power") : String(localized: "On battery")) · health \(Format.percent($0))"
                                )
                            } ?? "")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1).minimumScaleFactor(0.8)
                    }
                } else {
                    tile("Load", value: snapshot.map { $0.cpu.loadAverage.formatted(.number.precision(.fractionLength(2))) } ?? "–") {
                        Text("1-minute load average").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
    }

    private func tile(
        _ title: LocalizedStringKey,
        value: String,
        color: Color = Theme.text,
        highlight: Color? = nil,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        let detailView = detail()
        return HoverRowButton(radius: 12, restingFill: Theme.raised) {
            openDashboard(.system)
        } label: { hovering in
            tileContent(title, value: value, color: color, hovering: hovering, detail: detailView)
        }
        .overlay {
            if let highlight {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(highlight.opacity(0.4), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens System"))
    }

    private func tileContent(_ title: LocalizedStringKey, value: String, color: Color, hovering: Bool, detail: some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(hovering ? Theme.text : Theme.text2)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            detail.frame(height: 22, alignment: .bottom)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var network: some View {
        if let network = monitor.snapshot?.network {
            HStack(spacing: 10) {
                Text("Network").foregroundStyle(Theme.text2)
                Spacer()
                Text(verbatim: "↓").foregroundStyle(Theme.accentText)
                Text(Format.rate(network.receiveBytesPerSecond)).monospacedDigit()
                Text(verbatim: "↑").foregroundStyle(Theme.teal)
                Text(Format.rate(network.sendBytesPerSecond)).monospacedDigit()
            }
            .font(.system(size: 12))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var apps: some View {
        let top = (monitor.snapshot?.processes ?? []).prefix(3)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("HEAVIEST APPS").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.text3).padding(.bottom, 4)
                ForEach(Array(top)) { group in
                    HoverRow { hovering in
                        HStack(spacing: 10) {
                            AppAvatar(name: group.name, bundlePath: group.bundlePath, size: 22)
                            Text(group.name).lineLimit(1)
                            Spacer()
                            Text(Format.memory(group.footprintBytes)).monospacedDigit().foregroundStyle(Theme.text2)
                            if AppControl.runningApp(for: group) != nil {
                                Button("Quit") { AppControl.quit(group) }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .opacity(hovering ? 1 : 0)
                                    .accessibilityLabel(Text("Quit \(group.name)"))
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: 32)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Open Dashboard") { openDashboard(.overview) }
            Spacer()
            SettingsLink { Text("Settings") }
            Button("Quit Osin") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(Theme.text2)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
