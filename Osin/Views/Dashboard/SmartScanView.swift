import AppKit
import OsinCore
import SwiftUI

struct SmartScanView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmIrreversible = false

    var body: some View {
        Group {
            switch scan.phase {
            case .idle: idle
            case .scanning: scanning
            case .report: report
            case .cleaning: cleaning
            case .done: done
            }
        }
        .navigationTitle(Text("Smart Scan"))
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: scan.phase)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Brand.accent)
                .frame(width: 96, height: 96)
                .background(Brand.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityHidden(true)
            Text("Smart Scan").font(.largeTitle.bold())
            Text("Checks caches, developer leftovers, downloads and the Trash. Nothing is removed until you review the report.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Start scan") { scan.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Brand.accent)
                .keyboardShortcut(.defaultAction)
            if let message = scan.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            accessNote
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var accessNote: some View {
        if FullDiskAccess.isGranted() {
            Label("Full Disk Access granted", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Label("Without Full Disk Access some folders are skipped.", systemImage: "lock")
                Button("Open Settings") {
                    if let url = FullDiskAccess.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scanning…").font(.title2.bold())
                    Text(scan.currentStep)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { scan.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            UsageBar(fraction: scan.progress, color: Brand.accent, height: 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: scan.progress)
            Card {
                ForEach(Array(scan.stepNames.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 12) {
                        Group {
                            if index < scan.currentStepIndex {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            } else if index == scan.currentStepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 18)
                        .accessibilityHidden(true)
                        Text(name)
                            .foregroundStyle(index > scan.currentStepIndex ? .secondary : .primary)
                        Spacer()
                    }
                    .frame(minHeight: 26)
                    .transition(.opacity)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    // MARK: Report

    private var report: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    reportHeader
                    if scan.needsFullDiskAccess {
                        Card {
                            HStack {
                                Label("Some locations need Full Disk Access to be measured.", systemImage: "lock")
                                Spacer()
                                Button("Open Settings") {
                                    if let url = FullDiskAccess.settingsURL {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    section(
                        title: "Safe to clean",
                        caption: "Regenerable. Apps and tools rebuild these when needed.",
                        color: .green,
                        groups: scan.safeGroups
                    )
                    section(title: "Needs your review", caption: "Not selected by default.", color: .orange, groups: scan.reviewGroups)
                    memorySuggestions
                }
                .padding(24)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    private var reportHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected to clean").foregroundStyle(.secondary)
                Text(Format.storage(scan.selectedTotal))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(
                    // swiftlint:disable:next line_length
                    "\(Format.storage(scan.selectedFreedNow)) freed immediately · \(Format.storage(scan.selectedToTrash)) moved to Trash (restorable)"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan") { scan.start() }
        }
    }

    @ViewBuilder
    private func section(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        color: Color,
        groups: [ScanCoordinator.Group]
    ) -> some View {
        if !groups.isEmpty {
            Card {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(title).font(.headline)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    GroupRow(group: group)
                    if group.id != groups.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private var memorySuggestions: some View {
        let apps = (monitor.snapshot?.processes ?? []).filter { AppControl.runningApp(for: $0) != nil }.prefix(3)
        if !apps.isEmpty, let pressure = monitor.snapshot?.memory.pressure {
            Card {
                HStack(spacing: 8) {
                    Circle().fill(pressure.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Memory").font(.headline)
                    Text(pressure == .normal ? "Pressure is normal. Quitting is optional." :
                        "Quitting heavy apps will relieve memory pressure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { group in
                    ProcessRow(group: group)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if scan.selectionIncludesIrreversible {
                Label("Some selected items are removed permanently and can't be undone.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text("Every action is logged in History.").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if scan.selectionIncludesIrreversible {
                    confirmIrreversible = true
                } else {
                    scan.clean()
                }
            } label: {
                Text("Clean \(Format.storage(scan.selectedTotal))").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Brand.accent)
            .disabled(scan.selectedTotal == 0)
            .keyboardShortcut(.defaultAction)
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .confirmationDialog(Text("Remove permanently?"), isPresented: $confirmIrreversible) {
            Button("Clean", role: .destructive) { scan.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Empty Trash and simulator removal cannot be undone.")
        }
    }

    // MARK: Cleaning / done

    private var cleaning: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Cleaning…").font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var done: some View {
        DoneView()
    }
}

/// One group in the report, with an expandable list of items.
private struct GroupRow: View {
    @Environment(ScanCoordinator.self) private var scan
    let group: ScanCoordinator.Group
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { scan.selectedGroups.contains(group.id) }, set: { _ in scan.toggleGroup(group.id) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.body.weight(.medium))
                        Text(group.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(group.bytes == 0)
                Spacer()
                badge
                Text(Format.storage(scan.selectedBytes(of: group)))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 72, alignment: .trailing)
                if !group.items.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(expanded ? "Hide items" : "Show items"))
                }
            }
            if group.needsAccess {
                Label("Some locations could not be read.", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.items.sorted { $0.bytes > $1.bytes }.prefix(200)) { item in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { !scan.excludedItems.contains(item.id) }, set: { _ in scan.toggleItem(item.id) })) {
                                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(Format.storage(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Show in Finder"))
                        }
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var badge: some View {
        if group.isIrreversible {
            BadgeLabel(text: "Can't undo", color: .red)
        } else if group.freesImmediately {
            BadgeLabel(text: "Deletes", color: .secondary)
        } else {
            BadgeLabel(text: "To Trash", color: .blue)
        }
    }
}

struct BadgeLabel: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Result screen with the freed-space counter and Undo.
private struct DoneView: View {
    @Environment(ScanCoordinator.self) private var scan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownBytes: UInt64 = 0

    var body: some View {
        let outcome = scan.outcome ?? CleanupOutcome()
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Freed").foregroundStyle(.secondary)
            Text(Format.storage(shownBytes))
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(shownBytes)))
                .accessibilityLabel(Text("Freed \(Format.storage(outcome.freedBytes))"))
            if outcome.trashedBytes > 0 {
                HStack(spacing: 10) {
                    Text(scan.restored
                        ? "\(Format.storage(outcome.trashedBytes)) restored from Trash"
                        : "\(Format.storage(outcome.trashedBytes)) moved to Trash · restorable until you empty it")
                    Button("Undo") { scan.undo() }
                        .disabled(scan.restored)
                    Button("Show in Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                    }
                }
                .padding(12)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12))
            }
            if !outcome.failures.isEmpty {
                DisclosureGroup("\(outcome.failures.count) items were skipped") {
                    ForEach(outcome.failures) { failure in
                        Text("\(failure.url.lastPathComponent): \(failure.reason)").font(.caption)
                    }
                }
                .frame(maxWidth: 520)
            }
            if let message = scan.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            Button("Done") { scan.reset() }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if reduceMotion {
                shownBytes = outcome.freedBytes
            } else {
                withAnimation(.easeOut(duration: 0.9)) { shownBytes = outcome.freedBytes }
            }
        }
    }
}
