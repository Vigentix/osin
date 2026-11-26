import Observation
import OsinCore
import SwiftUI

/// Drives Smart Scan: scan → report → clean → result, plus undo and history.
@MainActor
@Observable
final class ScanCoordinator {
    typealias Phase = ScanPhase

    /// A report row: a rule result or a built-in action.
    struct Group: Identifiable {
        enum Kind {
            case rule(RuleScanResult)
            case simulators(count: Int)
            case emptyTrash
        }

        let id: String
        let name: String
        let detail: String
        let tier: CleanupTier
        let bytes: UInt64
        let kind: Kind
        let needsAccess: Bool

        /// Removed immediately (deleted or built-in) rather than moved to the Trash.
        var freesImmediately: Bool {
            if case let .rule(result) = kind {
                return result.rule.action == .delete
            }
            return true
        }

        /// Built-ins cannot be undone and are not regenerable.
        var isIrreversible: Bool {
            if case .rule = kind {
                return false
            }
            return true
        }

        var items: [ScanItem] {
            if case let .rule(result) = kind {
                return result.items
            }
            return []
        }
    }

    struct Step: Identifiable {
        let id: Int
        let name: String
        var bytes: UInt64?
    }

    static let simulatorsID = "builtin.simulators"
    static let emptyTrashID = "builtin.empty-trash"

    private(set) var phase: Phase = .idle
    private(set) var groups: [Group] = []
    private(set) var steps: [Step] = []
    private(set) var currentStepIndex = 0
    private(set) var foundBytes: UInt64 = 0
    private(set) var currentPath = ""
    private(set) var lastScanDate: Date?
    private(set) var lastScanWasPartial = false
    private(set) var outcome: CleanupOutcome?
    private(set) var scoreBefore: Int?
    private(set) var freeBefore: UInt64?
    /// Bytes put back from the Trash by Undo for the current outcome.
    private(set) var restoredBytes: UInt64 = 0
    private(set) var isUndoing = false
    /// Items Undo could not put back yet; Undo retries exactly these.
    private(set) var pendingRestore: [TrashedItem] = []
    /// Why the last Undo left items behind, shown on the result screen.
    private(set) var undoFailures: [CleanupFailure] = []

    /// Everything trashed by the last clean is back in place.
    var restored: Bool {
        restoredBytes > 0 && pendingRestore.isEmpty
    }

    private(set) var errorMessage: String?
    var selectedGroups: Set<String> = []
    var excludedItems: Set<String> = []
    var focusedGroupID: String?

    /// Called after a cleanup so metrics refresh right away.
    @ObservationIgnored var onCleaned: (() -> Void)?
    /// Called when any scan (background or user-started) completes.
    @ObservationIgnored var onScanFinished: (() -> Void)?
    /// Debug hook: limit which rules run (the snapshot renderer avoids permission prompts).
    @ObservationIgnored var ruleFilter: (CleanupRule) -> Bool = { _ in true }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped for every scan; a cancelled scan that is still finishing its last await checks it and
    /// stops instead of writing into the newer scan's state.
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let log: CleanupLog? = (try? CleanupLog.defaultURL()).map(CleanupLog.init(url:))
    @ObservationIgnored private lazy var cleaner: Cleaner? = log.map { Cleaner(log: $0) }

    // MARK: Derived

    var safeGroups: [Group] {
        groups.filter { $0.tier == .safe && ($0.bytes > 0 || $0.needsAccess) }
    }

    var reviewGroups: [Group] {
        groups.filter { $0.tier == .review && ($0.bytes > 0 || $0.needsAccess) }
    }

    /// Safe-tier total from the last scan, `nil` before any scan.
    var safeReclaimableBytes: UInt64? {
        lastScanDate == nil ? nil : safeGroups.reduce(0) { $0 + $1.bytes }
    }

    var reviewBytes: UInt64 {
        reviewGroups.reduce(0) { $0 + $1.bytes }
    }

    var focusedGroup: Group? {
        groups.first { $0.id == focusedGroupID } ?? safeGroups.first ?? reviewGroups.first
    }

    func selectedBytes(of group: Group) -> UInt64 {
        guard case .rule = group.kind else { return group.bytes }
        return group.items.filter { !excludedItems.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedFreedNow: UInt64 {
        groups.filter { selectedGroups.contains($0.id) && $0.freesImmediately }.reduce(0) { $0 + selectedBytes(of: $1) }
    }

    var selectedToTrash: UInt64 {
        groups.filter { selectedGroups.contains($0.id) && !$0.freesImmediately }.reduce(0) { $0 + selectedBytes(of: $1) }
    }

    var selectedTotal: UInt64 {
        selectedFreedNow + selectedToTrash
    }

    var selectionIncludesIrreversible: Bool {
        groups.contains { selectedGroups.contains($0.id) && $0.isIrreversible }
    }

    var needsFullDiskAccess: Bool {
        groups.contains(where: \.needsAccess)
    }

    var progress: Double {
        steps.isEmpty ? 0 : Double(min(currentStepIndex, steps.count)) / Double(steps.count)
    }

    // MARK: Actions

    /// A user-started scan is allowed now.
    var canStartScan: Bool {
        phase.canStartScan && !isUndoing
    }

    /// Scanning, cleaning or undoing: actions that would replace the current outcome must wait.
    var isBusy: Bool {
        phase.isBusy || isUndoing
    }

    /// Full, user-started scan.
    func start() {
        guard phase.canStartScan, !isUndoing else { return }
        runScan(silent: false, filter: ruleFilter)
    }

    /// Quiet scan at launch so the Overview can show what is reclaimable. Skips Downloads, which would
    /// trigger a macOS permission prompt without context, and never interrupts what the user is doing.
    func backgroundScan() {
        guard phase.canStartBackgroundScan, !isUndoing else { return }
        let filter = ruleFilter
        runScan(silent: true) { rule in filter(rule) && !rule.paths.contains { $0.hasPrefix("~/Downloads") } }
    }

    func cancel() {
        guard phase.canCancel else { return }
        task?.cancel()
        task = nil
        phase = groups.isEmpty ? .idle : .report
    }

    func showReport() {
        guard phase.canShowReport, !isUndoing else { return }
        phase = groups.isEmpty ? .idle : .report
        outcome = nil
    }

    func toggleGroup(_ id: String) {
        if selectedGroups.contains(id) {
            selectedGroups.remove(id)
        } else {
            selectedGroups.insert(id)
        }
    }

    func toggleItem(_ id: String) {
        if excludedItems.contains(id) {
            excludedItems.remove(id)
        } else {
            excludedItems.insert(id)
        }
    }

    /// One click from the Overview or popover: clean only the safe, regenerable groups from the last scan.
    func cleanSafeNow(score: Int?, free: UInt64?) {
        guard phase.canCleanSafeNow, !isUndoing, !safeGroups.isEmpty else { return }
        selectedGroups = Set(safeGroups.map(\.id))
        excludedItems = []
        phase = .report
        clean(score: score, free: free)
    }

    func clean(score: Int?, free: UInt64?) {
        guard let cleaner, phase == .report, !isUndoing else { return }
        let chosen = groups.filter { selectedGroups.contains($0.id) }
        let excluded = excludedItems
        scoreBefore = score
        freeBefore = free
        restoredBytes = 0
        pendingRestore = []
        undoFailures = []
        phase = .cleaning
        task = Task {
            var result = CleanupOutcome()
            // Empty the Trash first, so items trashed in this run stay restorable.
            for group in chosen {
                switch group.kind {
                case .emptyTrash:
                    let emptied = await cleaner.emptyTrash()
                    result.freedBytes += emptied.freedBytes
                    result.failures += emptied.failures
                case .simulators:
                    do {
                        try await SimulatorInventory.deleteUnavailable()
                        result.freedBytes += group.bytes
                        await cleaner.record(builtin: "simulators", bytes: group.bytes)
                    } catch {
                        result.failures.append(CleanupFailure(url: URL(fileURLWithPath: "simctl"), reason: error.localizedDescription))
                    }
                case .rule:
                    continue
                }
            }
            let selections = chosen.compactMap { group -> CleanupSelection? in
                guard case let .rule(rule) = group.kind else { return nil }
                return CleanupSelection(rule: rule.rule, items: rule.items.filter { !excluded.contains($0.id) })
            }
            let ruleOutcome = await cleaner.clean(selections)
            result.freedBytes += ruleOutcome.freedBytes
            result.trashedBytes += ruleOutcome.trashedBytes
            result.trashed += ruleOutcome.trashed
            result.failures += ruleOutcome.failures
            outcome = result
            pendingRestore = result.trashed
            removeCleaned(chosen.map(\.id))
            phase = .done
            onCleaned?()
        }
    }

    func undo() {
        guard let cleaner, !isUndoing, !pendingRestore.isEmpty else { return }
        let items = pendingRestore
        isUndoing = true
        Task {
            let failures = await cleaner.undo(items)
            let failed = Set(failures.map(\.url))
            let stillPending = items.filter { failed.contains($0.originalURL) }
            restoredBytes += items.filter { !failed.contains($0.originalURL) }.reduce(0) { $0 + $1.bytes }
            pendingRestore = stillPending
            undoFailures = failures
            isUndoing = false
            onCleaned?()
        }
    }

    func historyEntries() -> [CleanupLog.Entry] {
        ((try? log?.entries()) ?? []).reversed()
    }

    /// Restores one History entry. Returns why it failed, or `nil` on success.
    func restore(_ entry: CleanupLog.Entry) async -> CleanupFailure? {
        let original = URL(fileURLWithPath: entry.path)
        guard let cleaner, let trashPath = entry.trashPath else { return CleanupFailure(url: original, kind: .notTheTrashedItem) }
        let item = TrashedItem(
            originalURL: URL(fileURLWithPath: entry.path),
            trashURL: URL(fileURLWithPath: trashPath),
            bytes: entry.bytes,
            ruleID: entry.ruleID,
            identity: entry.identity
        )
        let failure = await cleaner.undo([item]).first
        if failure == nil, let index = pendingRestore.firstIndex(where: { $0.trashURL.path == trashPath }) {
            // Keep the result screen's Undo in step with restores made from History.
            restoredBytes += pendingRestore.remove(at: index).bytes
            undoFailures.removeAll { $0.url.path == entry.path }
        }
        onCleaned?()
        return failure
    }

    // MARK: Scan

    private func runScan(silent: Bool, filter: @escaping (CleanupRule) -> Bool) {
        task?.cancel()
        if !silent {
            phase = .scanning
            outcome = nil
            restoredBytes = 0
            pendingRestore = []
            undoFailures = []
        }
        errorMessage = nil
        foundBytes = 0
        currentStepIndex = 0
        scanGeneration += 1
        let generation = scanGeneration
        task = Task { await scan(silent: silent, filter: filter, generation: generation) }
    }

    static func group(for result: RuleScanResult) -> Group {
        Group(
            id: result.rule.id,
            name: String(localized: String.LocalizationValue(result.rule.name)),
            detail: String(localized: String.LocalizationValue(result.rule.detail)),
            tier: result.rule.tier,
            bytes: result.totalBytes,
            kind: .rule(result),
            needsAccess: result.needsAccess
        )
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == scanGeneration && !Task.isCancelled
    }

    private func scan(silent: Bool, filter: @escaping (CleanupRule) -> Bool, generation: Int) async {
        do {
            let rules = try CleanupRule.bundled().filter { (try? $0.validate()) != nil && filter($0) }
            let names = rules.map { String(localized: String.LocalizationValue($0.name)) }
            steps = (names + [String(localized: "Simulators"), String(localized: "Trash")]).enumerated().map { Step(
                id: $0.offset,
                name: $0.element
            ) }
            let paths = rules.map { $0.paths.first ?? $0.find?.roots.first ?? "" }

            let results = try await Scanner().scan(rules) { event in
                Task { @MainActor in
                    guard self.scanGeneration == generation else { return }
                    if let result = event.completed {
                        self.steps[event.index].bytes = result.totalBytes
                        self.foundBytes += result.totalBytes
                        self.currentStepIndex = event.index + 1
                    } else {
                        self.currentStepIndex = event.index
                        self.currentPath = paths[event.index]
                    }
                }
            }
            guard isCurrent(generation) else { return }
            var found = results.map(Self.group(for:))

            currentStepIndex = rules.count
            currentPath = "xcrun simctl"
            let simulators = await SimulatorInventory.measure()
            guard isCurrent(generation) else { return }
            steps[rules.count].bytes = simulators?.bytes ?? 0
            if let simulators, simulators.bytes > 0 {
                foundBytes += simulators.bytes
                found.append(Group(
                    id: Self.simulatorsID,
                    name: String(localized: "Unavailable simulators"),
                    detail: String(localized: "\(simulators.count) simulators whose runtime is no longer installed."),
                    tier: .review, bytes: simulators.bytes, kind: .simulators(count: simulators.count), needsAccess: false
                ))
            }

            currentStepIndex = rules.count + 1
            currentPath = "~/.Trash"
            let trashBytes = await (try? EmptyTrash.measure()) ?? 0
            guard isCurrent(generation) else { return }
            steps[rules.count + 1].bytes = trashBytes
            if trashBytes > 0 {
                foundBytes += trashBytes
                found.append(Group(
                    id: Self.emptyTrashID,
                    name: String(localized: "Empty Trash"),
                    detail: String(localized: "Permanently removes what is already in your Trash."),
                    tier: .review, bytes: trashBytes, kind: .emptyTrash, needsAccess: false
                ))
            }

            try Task.checkCancellation()
            currentStepIndex = steps.count
            groups = found
            selectedGroups = Set(found.filter { $0.tier == .safe }.map(\.id))
            excludedItems = []
            focusedGroupID = (found.first { $0.tier == .safe && $0.bytes > 0 } ?? found.first)?.id
            lastScanDate = Date()
            lastScanWasPartial = silent
            if !silent {
                phase = .report
            }
            onScanFinished?()
        } catch is CancellationError {
            return
        } catch {
            guard generation == scanGeneration else { return }
            errorMessage = error.localizedDescription
            if !silent {
                phase = .idle
            }
        }
    }

    private func removeCleaned(_ ids: [String]) {
        let cleaned = Set(ids)
        groups.removeAll { cleaned.contains($0.id) }
        selectedGroups.subtract(cleaned)
    }
}

#if DEBUG
    extension ScanCoordinator {
        /// Shows a finished Smart Scan report built from `DemoData` (README screenshots).
        func loadDemo() {
            task?.cancel()
            var found = DemoData.scanResults().map(Self.group(for:))
            found.append(Group(
                id: Self.simulatorsID,
                name: String(localized: "Unavailable simulators"),
                detail: String(localized: "\(DemoData.simulators.count) simulators whose runtime is no longer installed."),
                tier: .review, bytes: DemoData.simulators.bytes, kind: .simulators(count: DemoData.simulators.count), needsAccess: false
            ))
            found.append(Group(
                id: Self.emptyTrashID,
                name: String(localized: "Empty Trash"),
                detail: String(localized: "Permanently removes what is already in your Trash."),
                tier: .review, bytes: DemoData.trashBytes, kind: .emptyTrash, needsAccess: false
            ))
            groups = found
            selectedGroups = Set(found.filter { $0.tier == .safe }.map(\.id))
            excludedItems = []
            focusedGroupID = found.filter { $0.tier == .safe }.max { $0.bytes < $1.bytes }?.id
            lastScanDate = Date().addingTimeInterval(-120)
            lastScanWasPartial = false
            phase = .report
        }
    }
#endif
