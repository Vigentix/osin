import AppKit
import OsinCore
import QuickLook
import SwiftUI

/// Cleanup: Smart Scan (idle → scanning → report → result), Large files, History.
struct CleanupView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ScanCoordinator.self) private var scan

    var body: some View {
        @Bindable var navigator = navigator
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SegmentedPicker(options: CleanupTab.allCases.map { ($0, $0.title) }, selection: $navigator.cleanupTab)
                Spacer()
                if navigator.cleanupTab == .smartScan, scan.phase != .scanning, scan.phase != .cleaning {
                    Button {
                        scan.start()
                    } label: {
                        HStack(spacing: 8) { Text("Rescan"); KeyHint(keys: "⌘R") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider().overlay(Theme.border)
            Group {
                switch navigator.cleanupTab {
                case .smartScan: smartScan
                case .largeFiles: LargeFilesView()
                case .history: CleanupHistoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Cleanup"))
    }

    @ViewBuilder private var smartScan: some View {
        switch scan.phase {
        case .scanning: ScanningView()
        case .cleaning: CleaningView()
        case .done: ScanResultView()
        case .idle, .report:
            if scan.groups.isEmpty {
                ScanIdleView()
            } else {
                ScanReportView()
            }
        }
    }
}

// MARK: - Idle

private struct ScanIdleView: View {
    @Environment(ScanCoordinator.self) private var scan

    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 72, dot: Theme.good)
            Text("Find space you can reclaim").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text("Smart Scan reads caches, developer leftovers, downloads and the Trash. Nothing is removed until you review the report.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: 460)
            Button("Start scan") { scan.start() }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            if let message = scan.errorMessage {
                Text(message).foregroundStyle(Theme.poorText).font(.callout)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        HStack(alignment: .center, spacing: 48) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 10).frame(width: 208, height: 208)
                Circle()
                    .trim(from: 0, to: scan.progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 208, height: 208)
                    .animation(reduceMotion ? nil : .spring(duration: 0.6), value: scan.progress)
                Circle()
                    .trim(from: 0, to: 0.16)
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 236, height: 236)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false), value: sweep)
                Circle().stroke(Theme.border, lineWidth: 1).frame(width: 236, height: 236)
                VStack(spacing: 2) {
                    Text("Scanning").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Text(Format.storage(scan.foundBytes))
                        .font(.system(size: 38, weight: .bold))
                        .tracking(-1)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(scan.foundBytes)))
                        .animation(.easeOut(duration: 0.4), value: scan.foundBytes)
                    Text("found so far").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            .frame(width: 260, height: 260)
            .onAppear { sweep = true }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Looking for space you can reclaim…").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    Text(scan.currentPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(scan.steps) { step in
                            HStack(spacing: 12) {
                                Group {
                                    if step.id < scan.currentStepIndex {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.bold)
                                    } else if step.id == scan.currentStepIndex {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Circle().strokeBorder(Theme.text3, lineWidth: 1.5).frame(width: 8, height: 8)
                                    }
                                }
                                .frame(width: 18)
                                Text(step.name).foregroundStyle(step.id > scan.currentStepIndex ? Theme.text3 : Theme.text)
                                Spacer()
                                if step.id < scan.currentStepIndex, let bytes = step.bytes {
                                    Text(bytes == 0 ? String(localized: "nothing") : Format.storage(bytes))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.text2)
                                }
                            }
                            .frame(height: 34)
                            .padding(.horizontal, 10)
                        }
                    }
                }
                Button {
                    scan.cancel()
                } label: {
                    HStack(spacing: 8) { Text("Cancel"); KeyHint(keys: "esc") }
                }
                .buttonStyle(SecondaryButtonStyle(large: true))
                .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CleaningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Cleaning…").font(.title3).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Report

private struct ScanReportView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor
    @State private var confirmIrreversible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if scan.lastScanWasPartial {
                            notice("Downloads was skipped in the background scan. Rescan to include it.", icon: "info.circle")
                        }
                        if scan.needsFullDiskAccess {
                            notice("Some locations need Full Disk Access to be measured.", icon: "lock")
                        }
                        groupSection("SAFE TO CLEAN", color: Theme.good, groups: scan.safeGroups)
                        groupSection("NEEDS YOUR REVIEW", color: Theme.fair, groups: scan.reviewGroups)
                    }
                    .padding(12)
                }
                .frame(width: 360)
                Divider().overlay(Theme.border)
                if let group = scan.focusedGroup {
                    GroupDetail(group: group)
                } else {
                    Spacer()
                }
            }
            Divider().overlay(Theme.border)
            footer
        }
    }

    private func notice(_ text: LocalizedStringKey, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func groupSection(_ title: LocalizedStringKey, color: Color, groups: [ScanCoordinator.Group]) -> some View {
        if !groups.isEmpty {
            let total = groups.reduce(UInt64(0)) { $0 + $1.bytes }
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.text2)
                Spacer()
                if total > 0 {
                    Text(Format.storage(total)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            let largest = max(groups.map(\.bytes).max() ?? 1, 1)
            ForEach(groups) { group in
                GroupRow(group: group, color: color, largest: largest)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.storage(scan.selectedTotal))
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("selected").foregroundStyle(Theme.text2)
                }
                Text("\(Format.storage(scan.selectedFreedNow)) freed now · \(Format.storage(scan.selectedToTrash)) to Trash (restorable)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text2)
            }
            Spacer()
            if scan.selectionIncludesIrreversible {
                Label("Includes items that can't be undone", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.poorText)
            }
            Button {
                if scan.selectionIncludesIrreversible {
                    confirmIrreversible = true
                } else {
                    clean()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Clean \(Format.storage(scan.selectedTotal))")
                    Text(verbatim: "⏎").opacity(0.7)
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(scan.selectedTotal == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .confirmationDialog(Text("Remove permanently?"), isPresented: $confirmIrreversible) {
            Button("Clean", role: .destructive) { clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Empty Trash and simulator removal cannot be undone.")
        }
    }

    private func clean() {
        scan.clean(score: monitor.snapshot?.health.score, free: monitor.snapshot?.disk.availableBytes)
    }
}

private struct GroupRow: View {
    @Environment(ScanCoordinator.self) private var scan
    let group: ScanCoordinator.Group
    let color: Color
    let largest: UInt64
    @State private var hovering = false

    var body: some View {
        let focused = scan.focusedGroup?.id == group.id
        let selected = scan.selectedGroups.contains(group.id)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in scan.toggleGroup(group.id) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(group.bytes == 0)
                .accessibilityLabel(Text(group.name))
            Button {
                scan.focusedGroupID = group.id
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.name).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        if group.bytes == 0, group.needsAccess {
                            Label("Needs access", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Theme.text3)
                        } else {
                            Text(Format.storage(scan.selectedBytes(of: group))).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                    UsageBar(fraction: Double(group.bytes) / Double(largest), color: color.opacity(selected ? 1 : 0.35), height: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
        .padding(8)
        .hoverSurface(radius: 10, selected: focused, hovering: $hovering)
    }
}

private struct GroupDetail: View {
    @Environment(ScanCoordinator.self) private var scan
    let group: ScanCoordinator.Group
    @State private var preview: URL?
    @State private var focusedItem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                        Text(group.detail).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(Format.storage(group.bytes)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    if group.isIrreversible {
                        Badge(text: "CAN'T UNDO", color: Theme.poorText)
                        Text("Removed permanently.").foregroundStyle(Theme.text2)
                    } else if group.freesImmediately {
                        Badge(text: "DELETES", color: Theme.text2, background: Theme.control)
                        Text("Removed permanently. Regenerable: apps and tools rebuild it when needed.").foregroundStyle(Theme.text2)
                    } else {
                        Badge(text: "TO TRASH", color: Theme.blue)
                        Text("Moved to the Trash. Undo from the result screen or History.").foregroundStyle(Theme.text2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))

                if !group.items.isEmpty {
                    HStack {
                        Text("Largest items").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                        Spacer()
                        Text("Space to Quick Look").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    VStack(spacing: 0) {
                        ForEach(group.items.sorted { $0.bytes > $1.bytes }.prefix(100)) { item in
                            itemRow(item)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
                    if group.items.count > 100 {
                        Text("and \(group.items.count - 100) more items").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .padding(24)
        }
        .quickLookPreview($preview)
        .focusable()
        .onKeyPress(.space) {
            guard let focusedItem else { return .ignored }
            preview = URL(fileURLWithPath: focusedItem)
            return .handled
        }
    }

    private func itemRow(_ item: ScanItem) -> some View {
        ItemRow(item: item, focused: focusedItem == item.id) { focusedItem = item.id }
    }
}

// MARK: - Result

private struct ScanResultView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Navigator.self) private var navigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownBytes: UInt64 = 0

    var body: some View {
        let outcome = scan.outcome ?? CleanupOutcome()
        ScrollView {
            VStack(spacing: 26) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.good)
                    .frame(width: 64, height: 64)
                    .background(Theme.good.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("Freed just now").foregroundStyle(Theme.text2)
                    Text(Format.storage(shownBytes))
                        .font(.system(size: 64, weight: .bold))
                        .tracking(-2)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(shownBytes)))
                        .accessibilityLabel(Text("Freed \(Format.storage(outcome.freedBytes))"))
                }
                HStack(alignment: .top, spacing: 14) {
                    freeSpaceCard(outcome)
                    scoreCard
                }
                .frame(maxWidth: 680)
                if outcome.trashedBytes > 0 {
                    trashCard(outcome)
                }
                if !scan.undoFailures.isEmpty {
                    DisclosureGroup("\(scan.undoFailures.count) items could not be restored") {
                        ForEach(scan.undoFailures) { failure in
                            Text(verbatim: "\(failure.url.lastPathComponent): \(failure.localizedReason)").font(.caption)
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    .foregroundStyle(Theme.fairText)
                    .frame(maxWidth: 680)
                }
                if !outcome.failures.isEmpty {
                    DisclosureGroup("\(outcome.failures.count) items were skipped") {
                        ForEach(outcome.failures) { failure in
                            Text(verbatim: "\(failure.url.lastPathComponent): \(failure.localizedReason)").font(.caption)
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    .frame(maxWidth: 680)
                }
                HStack(spacing: 10) {
                    Button("Done") { scan.showReport() }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .disabled(scan.isUndoing)
                        .keyboardShortcut(.defaultAction)
                    Button("View in History") { navigator.cleanupTab = .history }
                        .buttonStyle(SecondaryButtonStyle(large: true))
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if reduceMotion {
                shownBytes = outcome.freedBytes
            } else {
                withAnimation(.easeOut(duration: 1.1)) { shownBytes = outcome.freedBytes }
            }
        }
    }

    private func freeSpaceCard(_ outcome: CleanupOutcome) -> some View {
        let before = scan.freeBefore ?? 0
        let after = monitor.snapshot?.disk.availableBytes ?? (before + outcome.freedBytes)
        let scale = Double(max(after, before, 1))
        return Card {
            Text("Free space").font(.system(size: 12)).foregroundStyle(Theme.text2)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Before").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    UsageBar(fraction: Double(before) / scale, color: Theme.poor, height: 8)
                    Text(Format.storage(before)).monospacedDigit().foregroundStyle(Theme.poorText)
                }
                GridRow {
                    Text("After").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    UsageBar(fraction: Double(after) / scale, color: Theme.good, height: 8)
                    Text(Format.storage(after)).monospacedDigit().foregroundStyle(Theme.goodText)
                }
            }
        }
    }

    private var scoreCard: some View {
        let now = monitor.snapshot?.health
        return Card {
            HStack(spacing: 16) {
                HealthRing(score: now?.score, level: now?.level, diameter: 72, lineWidth: 7, showsLabel: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Health score").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    HStack(spacing: 6) {
                        if let before = scan.scoreBefore {
                            Text(verbatim: "\(before) →").foregroundStyle(Theme.text3)
                        }
                        Text(now.map { "\($0.score)" } ?? "–")
                    }
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    if let concern = now?.primaryConcern {
                        Text(concern.concernTitle).font(.system(size: 12)).foregroundStyle(now?.level.textColor ?? Theme.text2)
                    }
                }
            }
        }
    }

    private func trashCard(_ outcome: CleanupOutcome) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "trash").foregroundStyle(Theme.blue).accessibilityHidden(true)
            Group {
                if scan.restored {
                    Text("\(Format.storage(scan.restoredBytes)) restored from the Trash.")
                } else if scan.restoredBytes > 0 {
                    Text(
                        "\(Format.storage(scan.restoredBytes)) restored. \(Format.storage(outcome.trashedBytes > scan.restoredBytes ? outcome.trashedBytes - scan.restoredBytes : 0)) is still in the Trash."
                    )
                } else {
                    Text("\(Format.storage(outcome.trashedBytes)) moved to the Trash. Restorable until you empty it.")
                }
            }
            .foregroundStyle(Theme.text)
            Spacer()
            Button {
                scan.undo()
            } label: {
                HStack(spacing: 6) { Text("Undo"); KeyHint(keys: "⌘Z") }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(scan.pendingRestore.isEmpty || scan.isUndoing)
            .keyboardShortcut("z", modifiers: .command)
            Button("Show in Trash") {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: 680)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Large files

private struct LargeFilesView: View {
    @State private var files: [LargeFile] = []
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Large files",
                    subtitle: String(localized: "Over 1 GB in your home folder, found with Spotlight. Osin never removes these for you.")
                ) {
                    Button("Refresh") { Task { await load() } }.buttonStyle(SecondaryButtonStyle()).disabled(loading)
                }
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
        .task { await load() }
    }

    private func load() async {
        loading = true
        files = await (try? LargeFileFinder.find()) ?? []
        loading = false
    }
}

// MARK: - History

private struct CleanupHistoryView: View {
    @Environment(ScanCoordinator.self) private var scan
    @State private var entries: [CleanupLog.Entry] = []
    @State private var restoredIDs: Set<String> = []
    /// Why a Restore from History did not work, per entry.
    @State private var restoreErrors: [String: String] = [:]

    private var totalFreed: UInt64 {
        entries.filter { $0.action == "delete" || $0.action.hasPrefix("builtin:") }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "History",
                    subtitle: String(localized: "Freed \(Format.storage(totalFreed)) in total. Everything Osin removes is listed here.")
                )
                if entries.isEmpty {
                    Card { Text("No cleanups yet").foregroundStyle(Theme.text2) }
                } else {
                    Card(padding: 8) {
                        VStack(spacing: 0) {
                            ForEach(entries.prefix(300)) { entry in row(entry) }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task { entries = scan.historyEntries() }
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
                                entries = scan.historyEntries()
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

/// One file or folder in the report, with Show in Finder revealed on hover.
private struct ItemRow: View {
    @Environment(ScanCoordinator.self) private var scan
    let item: ScanItem
    let focused: Bool
    let focus: () -> Void
    @State private var hovering = false

    var body: some View {
        let included = !scan.excludedItems.contains(item.id)
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { included }, set: { _ in scan.toggleItem(item.id) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Button(action: focus) {
                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(included ? Theme.text : Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            Text(Format.storage(item.bytes)).monospacedDigit().foregroundStyle(Theme.text2)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass").frame(width: 22, height: 22)
            }
            .buttonStyle(SecondaryButtonStyle())
            .opacity(hovering || focused ? 1 : 0)
            .accessibilityLabel(Text("Show in Finder"))
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .hoverSurface(radius: 0, selected: focused, hovering: $hovering)
    }
}
