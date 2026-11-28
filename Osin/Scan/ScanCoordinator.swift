import Observation
import OsinCore
import SwiftUI

/// Drives Smart Scan: scan → report → clean → result, plus undo and history.
@MainActor
@Observable
final class ScanCoordinator {
    typealias Phase = ScanPhase

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
    /// The last clean ran Docker commands (the result screen then offers to trim Colima's disk).
    private(set) var cleanedDocker = false
    /// A scheduled cleanup is running in the background (see `ScanCoordinator+Chores`).
    var isRunningChore = false
    /// The quiet launch scan is running (it leaves `phase` alone, so `isBusy` does not show it).
    private(set) var isScanningInBackground = false

    /// Space Lens is moving something to the Trash (see `trashSelected`).
    var isTrashingSelection = false

    /// Undoing, running a chore or trashing from Space Lens: scans, cleans and undos wait.
    var isOccupied: Bool {
        isUndoing || isRunningChore || isTrashingSelection
    }

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
    /// Called with the space a cleanup freed immediately (deleted or emptied), for the weekly report.
    @ObservationIgnored var onFreed: ((UInt64) -> Void)?
    /// Bumped whenever the cleanup log gains entries, so an open History reloads.
    var historyRevision = 0
    /// Called when any scan (background or user-started) completes.
    @ObservationIgnored var onScanFinished: (() -> Void)?
    /// Debug hook: limit which rules run (the snapshot renderer avoids permission prompts).
    @ObservationIgnored var ruleFilter: (CleanupRule) -> Bool = { _ in true }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped for every scan; a cancelled scan that is still finishing its last await checks it and
    /// stops instead of writing into the newer scan's state.
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored let log: CleanupLog? = (try? CleanupLog.defaultURL()).map { CleanupLog(url: $0) }
    @ObservationIgnored lazy var cleaner: Cleaner? = log.map { Cleaner(log: $0, projectRoots: { Preferences.projectRoots }) }

    // MARK: Derived

    var safeGroups: [Group] {
        groups.filter { $0.tier == .safe && ($0.bytes > 0 || $0.needsAccess) }
    }

    var reviewGroups: [Group] {
        groups.filter { $0.tier == .review && ($0.bytes > 0 || $0.needsAccess) }
    }

    /// Safe-tier total from the last scan, `nil` before any scan.
    var safeReclaimableBytes: UInt64? {
        // Not what waits for an app to be closed: Clean could not remove it now.
        lastScanDate == nil ? nil : safeGroups.reduce(0) { $0 + $1.cleanableBytes }
    }

    var reviewBytes: UInt64 {
        reviewGroups.reduce(0) { $0 + $1.bytes }
    }

    var focusedGroup: Group? {
        groups.first { $0.id == focusedGroupID } ?? safeGroups.first ?? reviewGroups.first
    }

    func selectedBytes(of group: Group) -> UInt64 {
        switch group.kind {
        case .rule:
            group.items.filter { !excludedItems.contains($0.id) && $0.blockedBy == nil }.reduce(0) { $0 + $1.bytes }
        case let .dockerVolumes(_, volumes):
            volumes.filter { !excludedItems.contains(Self.volumeItemID($0.name)) }.reduce(0) { $0 + $1.bytes }
        default:
            group.bytes
        }
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
        phase.canStartScan && !isOccupied
    }

    /// Scanning, cleaning or undoing: actions that would replace the current outcome must wait.
    var isBusy: Bool {
        phase.isBusy || isOccupied
    }

    /// Full, user-started scan.
    func start() {
        guard phase.canStartScan, !isOccupied else { return }
        runScan(silent: false, filter: ruleFilter)
    }

    /// Quiet scan at launch so the Overview can show what is reclaimable. Skips Downloads, which would
    /// trigger a macOS permission prompt without context, and never interrupts what the user is doing.
    func backgroundScan() {
        guard phase.canStartBackgroundScan, !isOccupied else { return }
        let filter = ruleFilter
        // Also skips unused toolchains: finding version pins reads every project folder (seconds).
        runScan(silent: true) { rule in
            filter(rule) && !rule.paths.contains { $0.hasPrefix("~/Downloads") } && rule.special != .unusedToolchains
        }
    }

    func cancel() {
        guard phase.canCancel else { return }
        task?.cancel()
        task = nil
        isScanningInBackground = false
        phase = groups.isEmpty ? .idle : .report
    }

    func showReport() {
        guard phase.canShowReport, !isOccupied else { return }
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
        guard phase.canCleanSafeNow, !isOccupied, !safeGroups.isEmpty else { return }
        selectedGroups = Set(safeGroups.map(\.id))
        excludedItems = []
        phase = .report
        clean(score: score, free: free)
    }

    func clean(score: Int?, free: UInt64?) {
        guard let cleaner, phase == .report, !isOccupied else { return }
        let chosen = groups.filter { selectedGroups.contains($0.id) }
        let excluded = excludedItems
        scoreBefore = score
        freeBefore = free
        restoredBytes = 0
        pendingRestore = []
        undoFailures = []
        phase = .cleaning
        cleanedDocker = chosen.contains { [Self.dockerBuildCacheID, Self.dockerImagesID, Self.dockerVolumesID].contains($0.id) }
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
                case .dockerBuildCache, .dockerImages, .dockerVolumes:
                    let docker = await cleanDocker(group, excluded: excluded, cleaner: cleaner)
                    result.freedBytes += docker.freed
                    result.failures += docker.failures
                case .rule:
                    continue
                }
            }
            let selections = chosen.compactMap { group -> CleanupSelection? in
                guard case let .rule(rule) = group.kind else { return nil }
                // Items whose app is open are left for later (the cleaner would refuse them anyway).
                return CleanupSelection(rule: rule.rule, items: rule.items.filter { !excluded.contains($0.id) && $0.blockedBy == nil })
            }
            onFreed?(result.freedBytes)
            // One rule at a time, so the weekly total is credited as each finishes (even if Osin quits).
            for selection in selections {
                let ruleOutcome = await cleaner.clean([selection])
                onFreed?(ruleOutcome.freedBytes)
                result.freedBytes += ruleOutcome.freedBytes
                result.trashedBytes += ruleOutcome.trashedBytes
                result.trashed += ruleOutcome.trashed
                result.failures += ruleOutcome.failures
            }
            outcome = result
            pendingRestore = result.trashed
            removeCleaned(chosen.map(\.id))
            phase = .done
            historyRevision += 1
            onCleaned?()
        }
    }

    func undo() {
        guard let cleaner, !isOccupied, !pendingRestore.isEmpty else { return }
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
            historyRevision += 1
            onCleaned?()
        }
    }

    /// The newest 300 History entries and the total freed, read off the main thread.
    func history() async -> (entries: [CleanupLog.Entry], totalFreed: UInt64) {
        guard let log else { return ([], 0) }
        return await Task.detached(priority: .userInitiated) {
            let all = (try? log.entries()) ?? []
            let freed = (try? log.freedBytesTotal()) ?? 0
            return (Array(all.suffix(300).reversed()), freed)
        }.value
    }

    /// Restores one History entry. Returns why it failed, or `nil` on success.
    func restore(_ entry: CleanupLog.Entry) async -> CleanupFailure? {
        let original = URL(fileURLWithPath: entry.path)
        guard let cleaner, let trashPath = entry.trashPath else { return CleanupFailure(url: original, kind: .notTheTrashedItem) }
        // Not while anything scans or cleans: a scan could list it as missing, a chore could clean it again.
        guard !isBusy, !isScanningInBackground else {
            return CleanupFailure(url: original, reason: String(localized: "Osin is busy cleaning. Try again in a moment."))
        }
        isUndoing = true
        defer { isUndoing = false }
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
        historyRevision += 1
        onCleaned?()
        return failure
    }

    // MARK: Scan

    private func runScan(silent: Bool, filter: @escaping (CleanupRule) -> Bool) {
        task?.cancel()
        isScanningInBackground = silent
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
        // The quiet launch scan yields to whatever the user is doing.
        task = Task(priority: silent ? .utility : nil) {
            await scan(silent: silent, filter: filter, generation: generation)
            if generation == scanGeneration {
                isScanningInBackground = false
            }
        }
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
            steps = (names + [String(localized: "Simulators"), String(localized: "Trash"), "Docker"]).enumerated().map { Step(
                id: $0.offset,
                name: $0.element
            ) }
            let paths = rules.map { $0.paths.first ?? $0.find?.roots.first ?? "" }

            let results = try await Scanner(projectRoots: Preferences.projectRoots).scan(rules) { event in
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

            guard let builtins = await builtinGroups(from: rules.count, generation: generation) else { return }
            found += builtins

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

    /// Replaces the groups of these rules with newer results (after a chore), keeping their selection.
    func replaceGroups(with results: [RuleScanResult]) {
        // No scan yet: the first Smart Scan measures everything anyway.
        guard lastScanDate != nil else { return }
        let ids = Set(results.map(\.rule.id))
        groups.removeAll { ids.contains($0.id) }
        groups += results.filter { $0.totalBytes > 0 || $0.needsAccess }.map(Self.group(for:))
        selectedGroups = selectedGroups.filter { id in !ids.contains(id) || groups.contains { $0.id == id } }
    }

    /// Simulators, Trash and Docker, measured after the rules (steps `index` onward). `nil` if superseded.
    private func builtinGroups(from index: Int, generation: Int) async -> [Group]? {
        var found: [Group] = []
        currentStepIndex = index
        currentPath = "xcrun simctl"
        let simulators = await SimulatorInventory.measure()
        guard isCurrent(generation) else { return nil }
        steps[index].bytes = simulators?.bytes ?? 0
        if let simulators, simulators.bytes > 0 {
            foundBytes += simulators.bytes
            found.append(Group(
                id: Self.simulatorsID,
                name: String(localized: "Unavailable simulators"),
                detail: String(localized: "\(simulators.count) simulators whose runtime is no longer installed."),
                tier: .review, bytes: simulators.bytes, kind: .simulators(count: simulators.count), needsAccess: false
            ))
        }

        currentStepIndex = index + 1
        currentPath = "~/.Trash"
        let trashBytes = await (try? EmptyTrash.measure()) ?? 0
        guard isCurrent(generation) else { return nil }
        steps[index + 1].bytes = trashBytes
        if trashBytes > 0 {
            foundBytes += trashBytes
            found.append(Group(
                id: Self.emptyTrashID,
                name: String(localized: "Empty Trash"),
                detail: String(localized: "Permanently removes what is already in your Trash."),
                tier: .review, bytes: trashBytes, kind: .emptyTrash, needsAccess: false
            ))
        }

        currentStepIndex = index + 2
        currentPath = "docker system df"
        let docker = await DockerInventory.measure()
        guard isCurrent(generation) else { return nil }
        let dockerGroups = docker.map(Self.dockerGroups) ?? []
        let dockerBytes = dockerGroups.reduce(UInt64(0)) { $0 + $1.bytes }
        steps[index + 2].bytes = dockerBytes
        foundBytes += dockerBytes
        found += dockerGroups

        return found
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
            found += Self.dockerGroups(DemoData.docker)
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
