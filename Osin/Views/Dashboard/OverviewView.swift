import Charts
import OsinCore
import SwiftUI

/// Overview, direction B: one clear message, what to do about it, then the live picture.
struct OverviewView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(ScanCoordinator.self) private var scan
    @Environment(Navigator.self) private var navigator
    @Environment(KeepAwakeController.self) private var keepAwake
    @Environment(Housekeeper.self) private var housekeeper
    @AppStorage(Preferences.Key.weeklyReportEnabled) private var weeklyReportEnabled = true

    /// The health ring draws in once per session; later visits show it settled.
    @MainActor private static var heroAnimated = false
    /// Updated only when it flips, so scrolling does not rebuild the page on every frame.
    @State private var showsCompactBar = false
    /// Latest scroll offset and hero bottom (in content coordinates). Kept outside observed state,
    /// so scrolling only touches SwiftUI when the compact bar actually needs to flip.
    @State private var scrollGeometry = ScrollGeometry()
    private let space = "overview-content"

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                content
                    .coordinateSpace(name: space)
                    .onPreferenceChange(HeroBottomKey.self) { bottom in
                        scrollGeometry.heroBottom = bottom
                        updateCompactBar()
                    }
                    .onScrollOffsetChange { offset in
                        scrollGeometry.offset = offset
                        updateCompactBar()
                    }
            }
            if showsCompactBar {
                compactBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .motion(Motion.standard, value: showsCompactBar)
        .motion(Motion.standard, value: keepAwake.isActive)
        .sheet(isPresented: Binding(get: { navigator.showsWeeklyReport }, set: { navigator.showsWeeklyReport = $0 })) {
            WeeklyReportSheet()
        }
        .navigationTitle(Text("Overview"))
    }

    /// The compact bar appears once the hero card has scrolled out of view, whether the page
    /// scrolled or the hero moved (a banner disappearing, a resize re-wrapping its text).
    private func updateCompactBar() {
        let shows = scrollGeometry.offset > scrollGeometry.heroBottom - 8
        if shows != showsCompactBar {
            showsCompactBar = shows
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            KeepAwakeBanner()
            hero
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeroBottomKey.self, value: proxy.frame(in: .named(space)).maxY)
                    }
                }
            if weeklyReportEnabled, let summary = housekeeper.reportToShow() {
                WeeklyReportCard(summary: summary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            recommended
            rightNow
            HStack(alignment: .top, spacing: 14) {
                heaviestApps
                storage
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
    }

    // MARK: Hero

    private var recommendations: [Recommendation] {
        guard let snapshot = monitor.snapshot else { return [] }
        let heaviest = snapshot.processes.first { AppControl.canQuit($0) }
        return Recommendations.make(RecommendationContext(
            safeReclaimableBytes: scan.safeReclaimableBytes,
            reviewBytes: scan.reviewBytes,
            memoryPressure: snapshot.memory.pressure,
            swapUsedBytes: snapshot.memory.swapUsedBytes,
            physicalMemoryBytes: snapshot.memory.physicalBytes,
            heaviestApp: heaviest,
            batteryHealth: snapshot.battery?.health
        ))
    }

    @ViewBuilder private var hero: some View {
        let snapshot = monitor.snapshot
        let report = snapshot?.health
        let message = HeroMessage(snapshot: snapshot, safeBytes: scan.safeReclaimableBytes)
        HStack(alignment: .center, spacing: 28) {
            HealthRing(score: report?.score, level: report?.level, diameter: 120, lineWidth: 10, animatesIn: !Self.heroAnimated)
                .onAppear { Self.heroAnimated = true }
            VStack(alignment: .leading, spacing: 8) {
                Text(greeting)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                (Text(message.title).foregroundStyle(Theme.text) + Text(verbatim: "\n") + Text(message.subtitle)
                    .foregroundStyle(Theme.text2))
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.7)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let report {
                    deductions(report)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                primaryAction(large: true)
                Button("Review what's included") {
                    navigator.section = .cleanup
                    navigator.cleanupTab = .smartScan
                    if scan.lastScanDate == nil {
                        scan.start()
                    } else {
                        scan.showReport()
                    }
                }
                .buttonStyle(SecondaryButtonStyle(large: true))
                if let date = scan.lastScanDate {
                    Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
            }
            .fixedSize()
        }
        .padding(28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
                .strokeBorder(report.map { $0.level == .good ? Theme.border : $0.level.color.opacity(0.3) } ?? Theme.border, lineWidth: 1)
        )
    }

    private func deductions(_ report: HealthReport) -> some View {
        HStack(spacing: 14) {
            ForEach(HealthComponent.allCases.filter { (report.deductions[$0] ?? 0) > 0 }, id: \.self) { component in
                let points = report.deductions[component] ?? 0
                HStack(spacing: 4) {
                    Text(verbatim: "−\(points)")
                        .fontWeight(.semibold)
                        .foregroundStyle(points >= 10 ? Theme.poorText : (points >= 5 ? Theme.fairText : Theme.text))
                    Text(component.title).foregroundStyle(Theme.text2)
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour < 12 ? String(localized: "Good morning") :
            (hour < 18 ? String(localized: "Good afternoon") : String(localized: "Good evening"))
        let count = recommendations.filter {
            if case .scan = $0.kind {
                false
            } else {
                true
            }
        }.count
        let state = switch count {
        case 0: String(localized: "everything looks fine")
        case 1: String(localized: "your Mac needs one thing")
        default: String(localized: "your Mac needs \(count) things")
        }
        return "\(hello) · \(state)"
    }

    // MARK: Recommended

    private var recommended: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Recommended for you")
            if recommendations.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        IconTile(systemName: "checkmark", tint: Theme.good)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nothing needs your attention").font(.system(size: 15, weight: .semibold))
                            Text("Osin keeps watching and will tell you when something changes.").foregroundStyle(Theme.text2)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(recommendations) { item in
                        RecommendationCard(item: item, cleanSafe: cleanSafe)
                    }
                }
            }
        }
    }

    // MARK: Right now

    private var rightNow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(text: "Right now")
                LiveDot()
                Text("updates every 2 s").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            HStack(spacing: 0) {
                if let snapshot = monitor.snapshot {
                    metricCell(
                        title: "CPU",
                        value: Format.percent(snapshot.cpu.total),
                        number: snapshot.cpu.total,
                        detail: cpuDetail(snapshot.cpu)
                    ) {
                        SparkChart(values: monitor.cpuHistory.values, color: Theme.accent)
                    }
                    divider
                    metricCell(
                        title: "Memory",
                        value: String(localized: snapshot.memory.pressure.title),
                        valueColor: snapshot.memory.pressure.textColor,
                        detail: "\(Format.memory(snapshot.memory.usedBytes)) / \(Format.memory(snapshot.memory.physicalBytes)) · swap \(Format.memory(snapshot.memory.swapUsedBytes))"
                    ) {
                        SparkChart(values: monitor.memoryHistory.values, color: snapshot.memory.pressure.color)
                    }
                    divider
                    let level = DiskLevel(snapshot.disk)
                    metricCell(
                        title: "Disk",
                        value: Format.storage(snapshot.disk.availableBytes),
                        number: Double(snapshot.disk.availableBytes),
                        valueColor: level.textColor,
                        detail: String(localized: "free · \(Format.percent(snapshot.disk.usedFraction)) used")
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Spacer(minLength: 0)
                            UsageBar(fraction: snapshot.disk.usedFraction, color: level.color, height: 8)
                            Text(
                                "Read \(Format.rate(snapshot.disk.readBytesPerSecond)) · write \(Format.rate(snapshot.disk.writeBytesPerSecond))"
                            )
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                        }
                    }
                    divider
                    metricCell(
                        title: "Network",
                        value: Format.rate(snapshot.network.receiveBytesPerSecond),
                        number: snapshot.network.receiveBytesPerSecond,
                        detail: "↓ \(Format.rate(snapshot.network.receiveBytesPerSecond)) · ↑ \(Format.rate(snapshot.network.sendBytesPerSecond))"
                    ) {
                        SparkChart(values: monitor.networkHistory.values, color: Theme.teal, range: nil)
                    }
                    if let battery = snapshot.battery {
                        divider
                        metricCell(
                            title: "Battery",
                            value: Format.percent(battery.chargeFraction),
                            detail: battery.cycleCount
                                .map {
                                    String(
                                        localized: "\(battery.isOnACPower ? String(localized: "On power") : String(localized: "On battery")) · \($0) cycles"
                                    )
                                }
                                ?? String(localized: battery.isOnACPower ? "On power" : "On battery")
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Spacer(minLength: 0)
                                UsageBar(
                                    fraction: battery.health ?? battery.chargeFraction,
                                    color: (battery.health ?? 1) < 0.85 ? Theme.fair : Theme.good,
                                    height: 8
                                )
                                if let health = battery.health {
                                    Text("Health \(Format.percent(health))").font(.system(size: 11)).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
    }

    private func metricCell(
        title: LocalizedStringKey,
        value: String,
        number _: Double? = nil,
        valueColor: Color = Theme.text,
        detail: String,
        @ViewBuilder chart: () -> some View
    ) -> some View {
        let chartView = chart()
        return HoverRowButton(radius: 0) {
            navigator.section = .system
        } label: { hovering in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(hovering ? Theme.text : Theme.text2)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .opacity(hovering ? 1 : 0)
                        .offset(x: hovering ? 0 : -3, y: hovering ? 0 : 3)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                chartView.frame(height: 52).padding(.top, 6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens System"))
    }

    private func cpuDetail(_ cpu: CPUSnapshot) -> String {
        if let performance = cpu.performance, let efficiency = cpu.efficiency {
            return String(localized: "P \(Format.percent(performance)) · E \(Format.percent(efficiency))")
        }
        return String(localized: "Load \(cpu.loadAverage.formatted(.number.precision(.fractionLength(2))))")
    }

    // MARK: Bottom row

    private var heaviestApps: some View {
        Card {
            Text("Heaviest apps").font(.system(size: 15, weight: .semibold))
            let apps = Array((monitor.snapshot?.processes ?? []).prefix(5))
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, group in
                HoverRowButton {
                    navigator.section = .activity
                } label: { hovering in
                    HStack(spacing: 12) {
                        AppAvatar(name: group.name, bundlePath: group.bundlePath, size: 26)
                        Text(group.name).lineLimit(1)
                        Spacer()
                        Text(Format.memory(group.footprintBytes)).monospacedDigit().foregroundStyle(Theme.text2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .opacity(hovering ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                if index < apps.count - 1 {
                    Divider().overlay(Theme.border)
                }
            }
            Button("All processes in Activity") { navigator.section = .activity }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private var storage: some View {
        Card {
            Text("Storage").font(.system(size: 15, weight: .semibold))
            if let storage = monitor.storage {
                HStack(spacing: 20) {
                    StorageDonut(storage: storage).frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 7) {
                        LegendRow(color: Theme.accent, label: "Apps", value: Format.storage(storage.apps))
                        LegendRow(color: Theme.blue, label: "Developer", value: Format.storage(storage.developer))
                        LegendRow(color: Theme.teal, label: "Caches", value: Format.storage(storage.caches))
                        LegendRow(
                            color: Theme.fair,
                            label: "Safe to clean",
                            value: Format.storage(storage.reclaimable),
                            valueColor: Theme.fairText
                        )
                        LegendRow(color: Theme.neutralSeries, label: "Other & system", value: Format.storage(storage.other))
                    }
                }
                Text("Measured \(storage.measuredAt.formatted(.relative(presentation: .named))) · protected folders count as Other")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring storage…").foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Donut of disk categories with free space in the middle.
struct StorageDonut: View {
    let storage: StorageBreakdown

    private var slices: [(String, Double, Color)] {
        [
            ("apps", Double(storage.apps), Theme.accent),
            ("developer", Double(storage.developer), Theme.blue),
            ("caches", Double(storage.caches), Theme.teal),
            ("other", Double(storage.other), Theme.neutralSeries),
            ("free", Double(storage.free), Theme.track)
        ]
    }

    var body: some View {
        let level = DiskLevel(freeFraction: Double(storage.free) / Double(max(storage.total, 1)))
        Chart(slices, id: \.0) { slice in
            SectorMark(angle: .value("Size", slice.1), innerRadius: .ratio(0.72), angularInset: 1)
                .foregroundStyle(slice.2)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 0) {
                Text(Format.storage(storage.free))
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(level.textColor)
                Text("free").font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Storage: \(Format.storage(storage.free)) free of \(Format.storage(storage.total))"))
    }
}

/// The sentence at the top of the Overview, from the biggest problem.
struct HeroMessage {
    let title: String
    let subtitle: String

    init(snapshot: SystemSnapshot?, safeBytes: UInt64?) {
        guard let snapshot else {
            title = String(localized: "Checking your Mac…")
            subtitle = String(localized: "This takes a couple of seconds.")
            return
        }
        let cleanable = safeBytes.map { String(localized: "\(Format.storage($0)) can go safely.") }
            ?? String(localized: "Run Smart Scan to see what can go.")
        switch snapshot.health.primaryConcern {
        case .disk:
            title = String(localized: "Disk is \(Format.percent(snapshot.disk.usedFraction)) full.")
            subtitle = cleanable
        case .memory:
            title = String(localized: "Memory is under pressure.")
            subtitle = snapshot.processes.first.map { String(localized: "\($0.name) is using \(Format.memory($0.footprintBytes)).") }
                ?? String(localized: "Quit apps you are not using.")
        case .cpu:
            title = String(localized: "CPU has been busy for a while.")
            subtitle = String(localized: "Check Activity for what is using it.")
        case .thermal:
            title = String(localized: "Your Mac is running hot.")
            subtitle = String(localized: "It may slow itself down to cool off.")
        case .battery:
            title = String(localized: "Battery is wearing out.")
            subtitle = String(localized: "It holds less charge than when new.")
        case nil:
            title = String(localized: "Your Mac is in good shape.")
            subtitle = safeBytes
                .map {
                    $0 >= Recommendations
                        .minimumCleanBytes ? String(localized: "\(Format.storage($0)) of caches can go if you like.") :
                        String(localized: "Nothing needs your attention.")
                }
                ?? String(localized: "Nothing needs your attention.")
        }
    }
}

/// One "Recommended for you" card.
private struct RecommendationCard: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Navigator.self) private var navigator
    let item: Recommendation
    let cleanSafe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(systemName: icon, tint: tint)
            Text(title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .foregroundStyle(Theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
            action
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var icon: String {
        switch item.kind {
        case .scan: "magnifyingglass"
        case .cleanSafe: "sparkles"
        case .quitApp: "memorychip"
        case .review: "tray.and.arrow.down"
        case .battery: "battery.50percent"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .scan, .cleanSafe: Theme.accent
        case .quitApp, .battery: Theme.fair
        case .review: Theme.text2
        }
    }

    private var title: String {
        switch item.kind {
        case .scan: String(localized: "Find space you can reclaim")
        case .cleanSafe: String(localized: "Clear caches and logs")
        case let .quitApp(group): String(localized: "\(group.name) is using \(Format.memory(group.footprintBytes))")
        case let .review(bytes): String(localized: "\(Format.storage(bytes)) more to review")
        case let .battery(health): String(localized: "Battery holds \(Format.percent(health))")
        }
    }

    private var detail: String {
        switch item.kind {
        case .scan:
            return String(localized: "Smart Scan checks caches and leftovers in about a minute. Nothing is removed without your review.")
        case .cleanSafe:
            let parts = scan.safeGroups.prefix(3).map { "\($0.name) \(Format.storage($0.bytes))" }
            return parts.joined(separator: ", ") + ". " + String(localized: "Tools rebuild them when needed.")
        case let .quitApp(group):
            let swap = Format.memory(monitor.snapshot?.memory.swapUsedBytes ?? 0)
            return String(localized: "\(group.pids.count) processes. Your Mac swapped \(swap) to disk; quitting gives memory back.")
        case .review:
            let names = scan.reviewGroups.prefix(3).map(\.name).joined(separator: ", ")
            return String(localized: "\(names). Not selected unless you choose.")
        case .battery:
            let cycles = monitor.snapshot?.battery?.cycleCount ?? 0
            return String(localized: "\(cycles) cycles. Service is advised below 80%.")
        }
    }

    @ViewBuilder private var action: some View {
        switch item.kind {
        case .scan:
            Button("Scan now") {
                navigator.section = .cleanup
                navigator.cleanupTab = .smartScan
                scan.start()
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(!scan.canStartScan)
        case let .cleanSafe(bytes):
            Button("Clean \(Format.storage(bytes))", action: cleanSafe)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scan.isBusy)
        case let .quitApp(group):
            Button("Quit \(group.name)") { AppControl.quit(group) }
                .buttonStyle(SecondaryButtonStyle(large: true))
        case .review:
            Button("Review") {
                navigator.section = .cleanup
                navigator.cleanupTab = .smartScan
                scan.showReport()
            }
            .buttonStyle(SecondaryButtonStyle(large: true))
        case .battery:
            Button("Details") { navigator.section = .system }
                .buttonStyle(SecondaryButtonStyle(large: true))
        }
    }
}

// MARK: - Hero actions and the compact bar

extension OverviewView {
    /// Pinned summary while the hero is out of view: the score, the main concern, the main action.
    private var compactBar: some View {
        let report = monitor.snapshot?.health
        let message = HeroMessage(snapshot: monitor.snapshot, safeBytes: scan.safeReclaimableBytes)
        return HStack(spacing: 12) {
            HealthRing(score: report?.score, level: report?.level, diameter: 30, lineWidth: 3.5, showsLabel: false, animatesIn: false)
            Text(message.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            primaryAction(large: false)
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.regularMaterial)
                Theme.background.opacity(0.92)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }

    @ViewBuilder private func primaryAction(large: Bool) -> some View {
        if let bytes = scan.safeReclaimableBytes, bytes >= Recommendations.minimumCleanBytes {
            // No Return shortcut: Overview is the first page, and Return must not delete anything.
            Button {
                cleanSafe()
            } label: {
                Text("Clean \(Format.storage(bytes))").rollingNumber(Double(bytes))
            }
            .buttonStyle(PrimaryButtonStyle(large: large))
            .disabled(scan.isBusy)
        } else {
            Button("Run Smart Scan") {
                navigator.section = .cleanup
                navigator.cleanupTab = .smartScan
                scan.start()
            }
            .buttonStyle(PrimaryButtonStyle(large: large))
            .disabled(!scan.canStartScan)
        }
    }

    private func cleanSafe() {
        navigator.section = .cleanup
        navigator.cleanupTab = .smartScan
        scan.cleanSafeNow(score: monitor.snapshot?.health.score, free: monitor.snapshot?.disk.availableBytes)
    }
}

/// Bottom edge of the hero card in the scroll view's coordinates (below 0 once scrolled away).
private struct HeroBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Plain storage for scroll geometry: changing it does not invalidate the view.
private final class ScrollGeometry {
    var offset: CGFloat = 0
    var heroBottom: CGFloat = .infinity
}
