import OsinCore
import SwiftUI

struct MemoryView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var range: SystemMonitor.HistoryRange = .hour
    @State private var points: [HistoryPoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let memory = monitor.snapshot?.memory {
                    summary(memory)
                    Card(title: "Memory used") {
                        HistoryChart(points: points, series: .memory, color: memory.pressure.color, height: 180)
                    }
                    breakdown(memory)
                }
                topApps
            }
            .padding(24)
        }
        .navigationTitle(Text("Memory"))
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

    private func summary(_ memory: MemoryStats) -> some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory pressure")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(memory.pressure.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(memory.pressure.color)
                }
                Divider().frame(height: 48)
                Text(pressureExplanation(memory.pressure))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func breakdown(_ memory: MemoryStats) -> some View {
        Card(title: "Breakdown") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                row("App memory", memory.appBytes, "Memory apps are actively using.")
                row("Wired", memory.wiredBytes, "Reserved by macOS; cannot be compressed or swapped.")
                row("Compressed", memory.compressedBytes, "Squeezed in RAM to avoid swapping.")
                row("Cached files", memory.cachedBytes, "Recently used files; freed automatically when needed.")
                row("Swap used", memory.swapUsedBytes, "Moved to disk. A lot of swap slows things down.")
                Divider()
                GridRow {
                    Text("Physical memory").fontWeight(.semibold)
                    Text(Format.memory(memory.physicalBytes)).monospacedDigit().gridColumnAlignment(.trailing)
                    Text("")
                }
            }
            .font(.callout)
        }
    }

    private func row(_ title: LocalizedStringKey, _ bytes: UInt64, _ caption: LocalizedStringKey) -> some View {
        GridRow {
            Text(title)
            Text(Format.memory(bytes)).monospacedDigit().gridColumnAlignment(.trailing)
            Text(caption).foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder private var topApps: some View {
        let top = (monitor.snapshot?.processes ?? []).prefix(10)
        if !top.isEmpty {
            Card(title: "Using most memory") {
                ForEach(top) { group in
                    ProcessRow(group: group)
                }
            }
        }
    }

    private func pressureExplanation(_ pressure: MemoryPressure) -> LocalizedStringKey {
        switch pressure {
        case .normal: "macOS is using memory efficiently. Free RAM is not the goal: unused RAM is wasted RAM."
        case .warning: "macOS is compressing memory and using swap. Quitting apps you are not using will help."
        case .critical: "Your Mac is short on memory and may feel slow. Quit heavy apps to recover."
        }
    }
}
