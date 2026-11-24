import AppKit
import OsinCore
import SwiftUI

struct ProcessesView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var sortOrder = [KeyPathComparator(\ProcessGroup.footprintBytes, order: .reverse)]
    @State private var search = ""
    @State private var selection: ProcessGroup.ID?
    @State private var pendingForceQuit: ProcessGroup?

    private var rows: [ProcessGroup] {
        let all = monitor.snapshot?.processes ?? []
        let filtered = search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted(using: sortOrder)
    }

    private var selectedGroup: ProcessGroup? {
        rows.first { $0.id == selection }
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { group in
                HStack(spacing: 8) {
                    AppIcon(bundlePath: group.bundlePath)
                        .frame(width: 18, height: 18)
                    Text(group.name)
                        .lineLimit(1)
                }
            }
            TableColumn("Memory", value: \.footprintBytes) { group in
                Text(Format.memory(group.footprintBytes)).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("CPU", value: \.cpuFraction) { group in
                Text(Format.cpuShare(group.cpuFraction)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Processes", value: \.processCount) { group in
                Text(group.processCount, format: .number).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: ProcessGroup.ID.self) { ids in
            if let id = ids.first, let group = rows.first(where: { $0.id == id }), AppControl.runningApp(for: group) != nil {
                Button("Quit") { AppControl.quit(group) }
                Button("Force Quit…") { pendingForceQuit = group }
            }
        }
        .searchable(text: $search, prompt: Text("Search apps"))
        .navigationTitle(Text("Processes"))
        .navigationSubtitle(Text("\(rows.count) items"))
        .toolbar {
            Button("Quit") {
                if let group = selectedGroup {
                    AppControl.quit(group)
                }
            }
            .disabled(selectedGroup.flatMap(AppControl.runningApp(for:)) == nil)
            Button("Force Quit…") {
                pendingForceQuit = selectedGroup
            }
            .disabled(selectedGroup.flatMap(AppControl.runningApp(for:)) == nil)
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
        .overlay {
            if monitor.snapshot == nil {
                ProgressView()
            }
        }
        .footnote
    }
}

private extension View {
    var footnote: some View {
        safeAreaInset(edge: .bottom) {
            Text("Only processes running as you are listed. CPU 100% equals one full core.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }
}

extension ProcessGroup {
    var processCount: Int {
        pids.count
    }
}

/// Finds and quits the app behind a process group. Only regular apps are offered.
enum AppControl {
    static func runningApp(for group: ProcessGroup) -> NSRunningApplication? {
        guard let bundlePath = group.bundlePath else { return nil }
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
                && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func quit(_ group: ProcessGroup) {
        runningApp(for: group)?.terminate()
    }

    static func forceQuit(_ group: ProcessGroup) {
        runningApp(for: group)?.forceTerminate()
    }
}

struct AppIcon: View {
    let bundlePath: String?

    var body: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
