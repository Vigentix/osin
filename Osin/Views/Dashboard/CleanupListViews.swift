import AppKit
import OsinCore
import SwiftUI

// MARK: - Large files

struct LargeFilesView: View {
    let reload: Int
    @Binding var loading: Bool
    @State private var files: [LargeFile] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Over 1 GB in your home folder, found with Spotlight. Osin never removes these for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if files.isEmpty {
                    Card { Text("No files over 1 GB found by Spotlight.").foregroundStyle(Theme.text2) }
                } else {
                    let largest = Double(files.first?.bytes ?? 1)
                    Card(padding: 8) {
                        VStack(spacing: 0) {
                            ForEach(files) { file in
                                HoverRow { hovering in
                                    HStack(spacing: 12) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                            .resizable().frame(width: 26, height: 26).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.url.lastPathComponent).lineLimit(1)
                                            Text(file.url.deletingLastPathComponent().path.replacingOccurrences(
                                                of: NSHomeDirectory(),
                                                with: "~"
                                            ))
                                            .font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        UsageBar(fraction: Double(file.bytes) / largest, color: Theme.accent, height: 4).frame(width: 90)
                                        Text(Format.storage(file.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .opacity(hovering ? 1 : 0.55)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 48)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: reload) { await load() }
    }

    private func load() async {
        loading = true
        let found = await (try? LargeFileFinder.find()) ?? []
        // A newer load (Refresh, or coming back to the tab) owns the results and the spinner.
        guard !Task.isCancelled else { return }
        Motion.animate { files = found }
        loading = false
    }
}

// MARK: - History

struct CleanupHistoryView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Binding var totalFreed: UInt64
    @State private var entries: [CleanupLog.Entry] = []
    @State private var restoredIDs: Set<String> = []
    /// Why a Restore from History did not work, per entry.
    @State private var restoreErrors: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Everything Osin removes is listed here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                if entries.isEmpty {
                    Card { Text("No cleanups yet").foregroundStyle(Theme.text2) }
                } else {
                    Card(padding: 8) {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in row(entry) }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: scan.historyRevision) { await reload() }
    }

    private func reload() async {
        let history = await scan.history()
        entries = history.entries
        totalFreed = history.totalFreed
    }

    private func row(_ entry: CleanupLog.Entry) -> some View {
        HoverRow { _ in
            HStack(spacing: 12) {
                Image(systemName: icon(for: entry.action)).foregroundStyle(Theme.text2).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.path.isEmpty ? entry.ruleID : entry.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text("\(label(for: entry.action)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    if let error = restoreErrors[entry.id] {
                        Text(verbatim: error).font(.system(size: 11)).foregroundStyle(Theme.fairText)
                    }
                }
                Spacer()
                Text(Format.storage(entry.bytes)).monospacedDigit().foregroundStyle(Theme.text2)
                if entry.action == "trash", canRestore(entry) {
                    Button("Restore") {
                        Task {
                            if let failure = await scan.restore(entry) {
                                restoreErrors[entry.id] = failure.localizedReason
                            } else {
                                restoredIDs.insert(entry.id)
                                restoreErrors[entry.id] = nil
                                await reload()
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
        }
    }

    private func canRestore(_ entry: CleanupLog.Entry) -> Bool {
        // Only offered while the exact trashed item is still in the Trash. Entries without a recorded
        // identity (before v0.1.1) cannot be verified, so they are not offered.
        guard !restoredIDs.contains(entry.id), let identity = entry.identity, let trashPath = entry.trashPath else { return false }
        return FileIdentity(path: trashPath) == identity && !FileManager.default.fileExists(atPath: entry.path)
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

// One file or folder in the report, with Show in Finder revealed on hover.
