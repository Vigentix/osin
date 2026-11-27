import AppKit
import OsinCore
import SwiftUI

/// Menu bar popover: score and reason, quick actions, four metrics, network, heaviest apps.
struct PopoverView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(ScanCoordinator.self) private var scan
    @Environment(Navigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showingKeepAwake = false

    /// `MenuBarExtra` sizes its panel once, when it opens. Content that grows afterwards (live data
    /// arriving) would spill past the panel, where it is visible but not clickable. A fixed height
    /// keeps every control inside the panel.
    static let height: CGFloat = 644

    var body: some View {
        ZStack(alignment: .top) {
            // Keep Awake options push in from the right, like a navigation step; Back pops them.
            if showingKeepAwake {
                KeepAwakeOptionsView { Motion.animate { showingKeepAwake = false } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                    KeepAwakeRow { Motion.animate { showingKeepAwake = true } }
                    tiles
                    network
                    apps
                    Spacer(minLength: 0)
                    footer
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(width: 376, height: Self.height, alignment: .top)
        .clipped()
        .background(Theme.surface)
        .osinFocusStyle()
        .onAppear { monitor.setVisible(.popover, true) }
        .onWindowVisibilityChange { monitor.setVisible(.popover, $0) }
        .onDisappear { monitor.setVisible(.popover, false) }
    }

    private func openDashboard(_ section: DashboardSection) {
        let panel = NSApp.keyWindow
        navigator.section = section
        openWindow(id: WindowID.dashboard)
        NSApp.activate()
        closePanel(panel)
        WindowFront.bringDashboardToFront()
    }

    /// `MenuBarExtra` has no API to close its panel, so hide the panel we were clicked in.
    private func closePanel(_ panel: NSWindow?) {
        guard let panel, panel.identifier?.rawValue != WindowID.dashboard else { return }
        panel.orderOut(nil)
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
                    Text("Clean \(Format.storage(bytes))").rollingNumber(Double(bytes)).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scan.isBusy)
            } else {
                Button {
                    openDashboard(.cleanup)
                    navigator.cleanupTab = .smartScan
                    scan.start()
                } label: {
                    Text("Smart Scan").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!scan.canStartScan)
            }
            iconButton("waveform.path.ecg", label: "Open Activity") { openDashboard(.activity) }
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
                tile("CPU", value: snapshot.map { Format.percent($0.cpu.total) } ?? "–", number: snapshot?.cpu.total) {
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
                    number: snapshot?.disk.usedFraction,
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
        number: Double? = nil,
        color: Color = Theme.text,
        highlight: Color? = nil,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        let detailView = detail()
        return HoverRowButton(radius: 12, restingFill: Theme.raised) {
            openDashboard(.system)
        } label: { hovering in
            tileContent(title, value: (value, number), color: color, hovering: hovering, detail: detailView)
        }
        .overlay {
            if let highlight {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(highlight.opacity(0.4), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens System"))
    }

    /// `value` is the text shown and, for key figures, the number its digits roll to.
    private func tileContent(
        _ title: LocalizedStringKey, value: (text: String, number: Double?), color: Color, hovering: Bool, detail: some View
    ) -> some View {
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
            Text(value.text)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .rollingNumber(value.number ?? 0)
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
                            if AppControl.canQuit(group) {
                                Button("Quit") { AppControl.quit(group) }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .opacity(hovering ? 1 : 0)
                                    .accessibilityLabel(Text("Quit \(group.name)"))
                            } else {
                                // Keeps the memory column aligned with rows that have a Quit button.
                                Button("Quit") {}.buttonStyle(SecondaryButtonStyle()).hidden()
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
        HStack(spacing: 6) {
            LogoMark(size: 14, dot: monitor.snapshot?.health.level.color)
            Text(verbatim: "Osin").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            Text(verbatim: Self.version).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer(minLength: 8)
            Button {
                openDashboard(.overview)
            } label: {
                Label("Open Dashboard", systemImage: "square.grid.2x2")
            }
            .buttonStyle(GhostButtonStyle())
            Button {
                let panel = NSApp.keyWindow
                openSettings()
                NSApp.activate()
                closePanel(panel)
                WindowFront.bringSettingsToFront()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(GhostButtonStyle())
            .help(Text("Settings"))
            .accessibilityLabel(Text("Settings"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(GhostButtonStyle())
            .help(Text("Quit Osin"))
            .accessibilityLabel(Text("Quit Osin"))
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

/// Brings app windows forward from the menu bar. Since macOS 14 activation is cooperative, so a
/// window opened from a menu bar panel can stay behind the frontmost app unless ordered front.
@MainActor
enum WindowFront {
    static func bringSettingsToFront() {
        bring { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
    }

    static func bringDashboardToFront() {
        bring { $0.identifier?.rawValue == WindowID.dashboard }
    }

    /// The window is created asynchronously, so retry for up to half a second.
    private static func bring(attempt: Int = 0, matching match: @escaping (NSWindow) -> Bool) {
        if let window = NSApp.windows.first(where: match), window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            bring(attempt: attempt + 1, matching: match)
        }
    }
}
