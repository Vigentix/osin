import AppKit
import OsinCore
import SwiftUI

/// Disk usage plus large files in the home folder, listed for manual review only (PRD §6.4).
struct StorageView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State private var largeFiles: [LargeFile] = []
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let disk = monitor.snapshot?.disk {
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Macintosh HD").font(.headline)
                            Spacer()
                            Text("\(Format.storage(disk.availableBytes)) free of \(Format.storage(disk.totalBytes))")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .foregroundStyle(DiskLevel(disk).color)
                        }
                        UsageBar(fraction: disk.usedFraction, color: DiskLevel(disk).color, height: 12)
                        Text("Available space includes purgeable data macOS can free on its own.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Card {
                    HStack {
                        Text("Large files").font(.headline)
                        Text("Over 1 GB in your home folder").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await load() } }.disabled(loading)
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if largeFiles.isEmpty {
                        Text("No files over 1 GB found by Spotlight.").foregroundStyle(.secondary)
                    } else {
                        ForEach(largeFiles) { file in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                    .resizable()
                                    .frame(width: 22, height: 22)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.url.lastPathComponent).lineLimit(1)
                                    Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(Format.storage(file.bytes)).monospacedDigit()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            }
                        }
                        Text("Osin never removes these for you. Review them in Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(Text("Storage"))
        .task { await load() }
    }

    private func load() async {
        loading = true
        largeFiles = await (try? LargeFileFinder.find()) ?? []
        loading = false
    }
}

/// The cleanup log with per-item restore for trashed items.
struct CleanupHistoryView: View {
    @Environment(ScanCoordinator.self) private var scan
    @State private var entries: [CleanupLog.Entry] = []
    @State private var restoredIDs: Set<String> = []

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No cleanups yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Everything Osin removes is listed here.")
                )
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: entry.action))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path.isEmpty ? entry.ruleID : entry.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(label(for: entry.action)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.storage(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        if entry.action == "trash", canRestore(entry) {
                            Button("Restore") {
                                Task {
                                    if await scan.restore(entry) {
                                        restoredIDs.insert(entry.id)
                                        entries = scan.historyEntries()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("History"))
        .navigationSubtitle(Text("Freed \(Format.storage(totalFreed)) in total"))
        .task { entries = scan.historyEntries() }
    }

    private var totalFreed: UInt64 {
        entries.filter { $0.action == "delete" || $0.action.hasPrefix("builtin:") }.reduce(0) { $0 + $1.bytes }
    }

    private func canRestore(_ entry: CleanupLog.Entry) -> Bool {
        guard !restoredIDs.contains(entry.id), let trashPath = entry.trashPath else { return false }
        return FileManager.default.fileExists(atPath: trashPath) && !FileManager.default.fileExists(atPath: entry.path)
    }

    private func icon(for action: String) -> String {
        switch action {
        case "delete": "trash.slash"
        case "trash": "trash"
        case "restore": "arrow.uturn.backward"
        default: "gearshape.2"
        }
    }

    private func label(for action: String) -> String {
        switch action {
        case "delete": String(localized: "Deleted")
        case "trash": String(localized: "Moved to Trash")
        case "restore": String(localized: "Restored")
        default: String(localized: "Built-in cleanup")
        }
    }
}
