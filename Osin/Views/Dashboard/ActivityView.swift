import AppKit
import OsinCore
import SwiftUI

/// Activity: apps grouped with their helpers, sortable, with an inspector for the selected one.
struct ActivityView: View {
    enum Sort: Hashable {
        case memory
        case cpu
    }

    @Environment(SystemMonitor.self) private var monitor
    @State private var sort: Sort = .memory
    @State private var search = ""
    @State private var selection: String?
    @State private var pendingForceQuit: ProcessGroup?
    @FocusState private var searchFocused: Bool

    private var rows: [ProcessGroup] {
        let all = monitor.snapshot?.processes ?? []
        let filtered = search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return switch sort {
        case .memory: filtered.sorted { $0.footprintBytes > $1.footprintBytes }
        case .cpu: filtered.sorted { $0.cpuFraction > $1.cpuFraction }
        }
    }

    var body: some View {
        let rows = rows
        let current = rows.first { $0.id == selection } ?? rows.first
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Activity", subtitle: summary) {
                SegmentedPicker(options: [(Sort.memory, "Memory"), (Sort.cpu, "CPU")], selection: $sort)
                searchField
            }
            HStack(alignment: .top, spacing: 16) {
                table(rows, current: current)
                    // Rows glide to their new places when you change the sort; ranking changes from
                    // the 2 s samples just update in place.
                    .motion(Motion.standard, value: sort)
                if let current {
                    ActivityInspector(group: current, history: monitor.groupMemoryHistory[current.id]?.values ?? []) {
                        pendingForceQuit = current
                    }
                    .id(current.id)
                    .transition(.opacity.combined(with: .offset(x: 6)))
                    .frame(width: 300)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .motion(Motion.standard, value: selection)
        .navigationTitle(Text("Activity"))
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
        .confirmationDialog(
            Text("Force quit \(pendingForceQuit?.name ?? "")?"),
            isPresented: Binding(get: { pendingForceQuit != nil }, set: {
                if !$0 {
                    pendingForceQuit = nil
                }
            }),
            presenting: pendingForceQuit
        ) { group in
            Button("Force Quit", role: .destructive) { AppControl.forceQuit(group) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unsaved changes in this app will be lost.")
        }
    }

    private var summary: String? {
        guard let snapshot = monitor.snapshot else { return nil }
        let count = snapshot.processes.reduce(0) { $0 + $1.pids.count }
        let memory = snapshot.memory
        return String(
            localized: "\(count) processes · CPU \(Format.percent(snapshot.cpu.total)) · memory \(Format.memory(memory.usedBytes)) of \(Format.memory(memory.physicalBytes)) · swap \(Format.memory(memory.swapUsedBytes))"
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3).accessibilityHidden(true)
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(width: 160)
            KeyHint(keys: "⌘F")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func table(_ rows: [ProcessGroup], current: ProcessGroup?) -> some View {
        let largest = Double(max(rows.map(\.footprintBytes).max() ?? 1, 1))
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("APP").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 110, alignment: .trailing)
                Text("MEMORY").frame(width: 150, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { group in
                        row(group, selected: group.id == current?.id, largest: largest)
                    }
                }
            }
            Text("Apps are grouped with their helpers. Only processes running as you are listed. CPU 100% = one full core.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func row(_ group: ProcessGroup, selected: Bool, largest: Double) -> some View {
        HoverRowButton(selected: selected) {
            selection = group.id
        } label: { _ in
            HStack(spacing: 12) {
                AppAvatar(name: group.name, bundlePath: group.bundlePath, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).fontWeight(.semibold).lineLimit(1)
                    Text(group.pids.count == 1 ? String(localized: "1 process") : String(localized: "\(group.pids.count) processes"))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    UsageBar(fraction: min(1, group.cpuFraction / 2), color: Theme.teal, height: 4).frame(width: 44)
                    Text(Format.cpuShare(group.cpuFraction))
                        .monospacedDigit()
                        .foregroundStyle(group.cpuFraction >= 1 ? Theme.fairText : Theme.text)
                        .frame(width: 54, alignment: .trailing)
                }
                .frame(width: 110, alignment: .trailing)
                HStack(spacing: 8) {
                    UsageBar(fraction: Double(group.footprintBytes) / largest, color: Theme.accent, height: 4).frame(width: 70)
                    Text(Format.memory(group.footprintBytes)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .contextMenu {
            if AppControl.canQuit(group) {
                Button("Quit") { AppControl.quit(group) }
                Button("Force Quit…") { pendingForceQuit = group }
            }
            if let path = group.bundlePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}

private struct ActivityInspector: View {
    let group: ProcessGroup
    let history: [Double]
    let forceQuit: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppAvatar(name: group.name, bundlePath: group.bundlePath, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Text(AppControl
                        .canQuit(group) ? String(localized: "\(group.pids.count) processes · app") :
                        String(localized: "\(group.pids.count) processes · system"))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            HStack(spacing: 10) {
                stat("Memory", Format.memory(group.footprintBytes))
                stat("CPU", Format.cpuShare(group.cpuFraction))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory, recent").font(.system(size: 11)).foregroundStyle(Theme.text2)
                SparkChart(values: history, color: Theme.accent, range: nil).frame(height: 56)
            }
            if !group.members.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Largest processes").font(.system(size: 11)).foregroundStyle(Theme.text2)
                    ForEach(group.members.prefix(4), id: \.pid) { member in
                        HStack {
                            Text(member.name).font(.system(size: 12)).lineLimit(1).foregroundStyle(Theme.text)
                            Spacer()
                            Text(Format.memory(member.footprintBytes)).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
            if AppControl.canQuit(group) {
                HStack(spacing: 8) {
                    Button("Quit") { AppControl.quit(group) }
                        .buttonStyle(SecondaryButtonStyle(large: true))
                        .frame(maxWidth: .infinity)
                    Button("Force Quit…", action: forceQuit)
                        .buttonStyle(SecondaryButtonStyle(large: true, tint: Theme.poorText))
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("System or background process: Osin shows it but does not offer to quit it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2)
            Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }
}
