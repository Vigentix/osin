import Observation
import OsinCore
import SwiftUI

/// Drives Smart Scan: scan → report → clean → result, plus undo and history.
@MainActor
@Observable
final class ScanCoordinator {
    enum Phase: Equatable {
        case idle
        case scanning
        case report
        case cleaning
        case done
    }

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

        /// Cannot be undone and is not regenerable: built-ins.
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

    static let simulatorsID = "builtin.simulators"
    static let emptyTrashID = "builtin.empty-trash"

    private(set) var phase: Phase = .idle
    private(set) var groups: [Group] = []
    private(set) var progress: Double = 0
    private(set) var currentStep = ""
    /// Names of the scan steps and the index of the one running, for the progress list.
    private(set) var stepNames: [String] = []
    private(set) var currentStepIndex = 0
    /// Debug hook: limit which rules run (used by the snapshot renderer to avoid permission prompts).
    @ObservationIgnored var ruleFilter: (CleanupRule) -> Bool = { _ in true }
    private(set) var lastScanDate: Date?
    private(set) var outcome: CleanupOutcome?
    private(set) var restored = false
    private(set) var errorMessage: String?
    var selectedGroups: Set<String> = []
    var excludedItems: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log: CleanupLog? = (try? CleanupLog.defaultURL()).map(CleanupLog.init(url:))
    @ObservationIgnored private lazy var cleaner: Cleaner? = log.map { Cleaner(log: $0) }

    // MARK: Derived

    var safeGroups: [Group] {
        groups.filter { $0.tier == .safe && ($0.bytes > 0 || $0.needsAccess) }
    }

    var reviewGroups: [Group] {
        groups.filter { $0.tier == .review && ($0.bytes > 0 || $0.needsAccess) }
    }

    /// Size of the pre-selected safe groups from the last scan, for the popover.
    var safeReclaimableBytes: UInt64? {
        lastScanDate == nil ? nil : safeGroups.reduce(0) { $0 + $1.bytes }
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

    // MARK: Actions

    func start() {
        task?.cancel()
        phase = .scanning
        progress = 0
        currentStep = ""
        groups = []
        outcome = nil
        restored = false
        errorMessage = nil
        task = Task { await runScan() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = groups.isEmpty ? .idle : .report
    }

    func reset() {
        phase = lastScanDate == nil ? .idle : .report
        outcome = nil
        if lastScanDate != nil {
            start()
        }
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

    func clean() {
        guard let cleaner, phase == .report else { return }
        let chosen = groups.filter { selectedGroups.contains($0.id) }
        let excluded = excludedItems
        phase = .cleaning
        task = Task {
            var result = CleanupOutcome()
            // Empty the Trash first, so items trashed in this run stay restorable.
            for group in chosen {
                switch group.kind {
                case .emptyTrash:
                    do {
                        try await EmptyTrash.perform()
                        result.freedBytes += group.bytes
                        await cleaner.record(builtin: "empty-trash", bytes: group.bytes)
                    } catch {
                        result.failures.append(CleanupFailure(url: URL(fileURLWithPath: "~/.Trash"), reason: error.localizedDescription))
                    }
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
            phase = .done
        }
    }

    func undo() {
        guard let cleaner, let trashed = outcome?.trashed, !trashed.isEmpty else { return }
        Task {
            let failures = await cleaner.undo(trashed)
            restored = failures.isEmpty
            if !failures.isEmpty {
                errorMessage = String(localized: "\(failures.count) items could not be restored.")
            }
        }
    }

    func historyEntries() -> [CleanupLog.Entry] {
        ((try? log?.entries()) ?? []).reversed()
    }

    func restore(_ entry: CleanupLog.Entry) async -> Bool {
        guard let cleaner, let trashPath = entry.trashPath else { return false }
        let item = TrashedItem(
            originalURL: URL(fileURLWithPath: entry.path),
            trashURL: URL(fileURLWithPath: trashPath),
            bytes: entry.bytes,
            ruleID: entry.ruleID
        )
        return await cleaner.undo([item]).isEmpty
    }

    // MARK: Scan

    private func runScan() async {
        do {
            let rules = try CleanupRule.bundled().filter { (try? $0.validate()) != nil && ruleFilter($0) }
            let steps = Double(rules.count + 2)
            stepNames = rules.map { String(localized: String.LocalizationValue($0.name)) } + [
                String(localized: "Simulators"),
                String(localized: "Trash")
            ]
            currentStepIndex = 0
            let names = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, String(localized: String.LocalizationValue($0.name))) })
            let results = try await Scanner().scan(rules) { event in
                Task { @MainActor in
                    self.progress = Double(event.index) / steps
                    self.currentStep = names[event.ruleID] ?? event.ruleID
                    self.currentStepIndex = event.index
                }
            }
            var found = results.map { result in
                Group(
                    id: result.rule.id,
                    name: String(localized: String.LocalizationValue(result.rule.name)),
                    detail: String(localized: String.LocalizationValue(result.rule.detail)),
                    tier: result.rule.tier,
                    bytes: result.totalBytes, kind: .rule(result), needsAccess: result.needsAccess
                )
            }

            currentStep = String(localized: "Simulators")
            currentStepIndex = rules.count
            progress = Double(rules.count) / steps
            if let simulators = await SimulatorInventory.measure(), simulators.bytes > 0 || simulators.count >= 1 {
                found.append(Group(
                    id: Self.simulatorsID,
                    name: String(localized: "Unavailable simulators"),
                    detail: String(localized: "\(simulators.count) simulators whose runtime is no longer installed."),
                    tier: .review, bytes: simulators.bytes, kind: .simulators(count: simulators.count), needsAccess: false
                ))
            }

            currentStep = String(localized: "Trash")
            currentStepIndex = rules.count + 1
            progress = Double(rules.count + 1) / steps
            if let trashBytes = try? await EmptyTrash.measure(), trashBytes > 0 {
                found.append(Group(
                    id: Self.emptyTrashID,
                    name: String(localized: "Empty Trash"),
                    detail: String(localized: "Permanently removes what is already in your Trash."),
                    tier: .review, bytes: trashBytes, kind: .emptyTrash, needsAccess: false
                ))
            }

            try Task.checkCancellation()
            groups = found
            selectedGroups = Set(found.filter { $0.tier == .safe }.map(\.id))
            excludedItems = []
            lastScanDate = Date()
            progress = 1
            phase = .report
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }
}
