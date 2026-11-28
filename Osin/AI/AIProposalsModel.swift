import Foundation
import Observation
import OsinCore

/// The AI's latest proposal and the user's choices in it. Moving to the Trash goes through Smart Scan's
/// coordinator, with the same checks as Space Lens (protected places refused, same item, logged).
@MainActor
@Observable
final class AIProposalsModel {
    private(set) var proposal: CleanupProposal?
    var excluded: Set<String> = []
    private(set) var isTrashing = false
    private(set) var movedBytes: UInt64?
    private(set) var failures: [CleanupFailure] = []
    /// Items whose app is open (path → app name): moving them waits until the app is quit.
    private(set) var blockedBy: [String: String] = [:]

    /// Moves items to the Trash (set by the app delegate: `ScanCoordinator.trashSelectedItems`).
    @ObservationIgnored var trasher: (([ScanItem]) async -> CleanupOutcome)?
    @ObservationIgnored private let store = ProposalStore.defaultFolder().map(ProposalStore.init(folder:))
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// A proposal that arrived while items were being moved; shown once that is done.
    @ObservationIgnored private var pending: CleanupProposal?

    var selectedItems: [CleanupProposal.Item] {
        proposal?.items.filter { !excluded.contains($0.id) } ?? []
    }

    var selectedBytes: UInt64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    /// Items by category, largest group first.
    var groups: [(name: String, items: [CleanupProposal.Item])] {
        let items = proposal?.items ?? []
        let grouped = Dictionary(grouping: items) { $0.category ?? String(localized: "Other") }
        return grouped.map { ($0.key, $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }

    /// Listens for proposals written by the MCP server (also from the user's own Claude Code or Codex).
    func startListening(onExternal: @escaping @MainActor (CleanupProposal) -> Void) {
        loadLatest()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ProposalStore.changedNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let id, let proposal = try? self.store?.load(id: id) else { return }
                self.show(proposal)
                if proposal.source == "external" {
                    onExternal(proposal)
                }
            }
        }
    }

    func loadLatest() {
        if let latest = store?.latest() {
            show(latest)
        }
    }

    func load(id: String) {
        if let proposal = try? store?.load(id: id) {
            show(proposal)
        }
    }

    private func show(_ proposal: CleanupProposal) {
        guard !isTrashing else {
            pending = proposal
            return
        }
        if self.proposal?.id != proposal.id {
            excluded = []
            movedBytes = nil
            failures = []
        }
        self.proposal = proposal
        refreshBlocked()
    }

    func refreshBlocked() {
        let running = AppActivity.runningAppNames()
        let home = FileManager.default.homeDirectoryForCurrentUser
        blockedBy = (proposal?.items ?? []).reduce(into: [:]) { result, item in
            if let app = CleanupRule.runningAppToQuit(for: URL(fileURLWithPath: item.path), home: home, running: running) {
                result[item.path] = app
            }
        }
    }

    #if DEBUG
        func loadDemo(_ demo: CleanupProposal) {
            proposal = demo
            excluded = []
            blockedBy = [demo.items[3].path: "Slack"]
        }
    #endif

    func toggle(_ id: String) {
        guard !isTrashing else { return }
        if excluded.contains(id) {
            excluded.remove(id)
        } else {
            excluded.insert(id)
        }
    }

    /// Moves the chosen items to the Trash. What did not go (failed, or waiting for an app to quit)
    /// stays in the proposal so it can be tried again.
    func moveSelectedToTrash() async {
        guard let proposal, let trasher, !isTrashing else { return }
        let chosen = selectedItems
        let items = chosen.map { item in
            ScanItem(url: URL(fileURLWithPath: item.path), bytes: item.bytes, modified: nil, identity: item.identity)
        }
        guard !items.isEmpty else { return }
        isTrashing = true
        let outcome = await trasher(items)
        isTrashing = false
        let moved = Set(outcome.trashed.map(\.originalURL.standardizedFileURL.path))
        failures = outcome.failures
        movedBytes = (movedBytes ?? 0) + chosen.filter { moved.contains($0.path) }.reduce(0) { $0 + $1.bytes }
        var remaining = proposal
        remaining.items.removeAll { moved.contains($0.path) }
        self.proposal = remaining
        if remaining.items.isEmpty {
            store?.delete(id: remaining.id)
        } else if !moved.isEmpty {
            try? store?.save(remaining)
        }
        refreshBlocked()
        if let next = pending {
            pending = nil
            show(next)
        }
    }

    /// Throws the proposal away without moving anything.
    func discard() {
        guard !isTrashing else { return }
        if let proposal {
            store?.delete(id: proposal.id)
        }
        proposal = nil
        excluded = []
        movedBytes = nil
        failures = []
    }
}
