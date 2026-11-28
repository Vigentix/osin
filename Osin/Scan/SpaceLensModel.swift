import Foundation
import Observation
import OsinCore

/// Space Lens: measures the home folder on demand, keeps the last result on disk, and moves what the
/// user picks to the Trash through the same safety checks and log as Smart Scan.
@MainActor
@Observable
final class SpaceLensModel {
    private(set) var tree: SpaceNode?
    private(set) var scannedAt: Date?
    private(set) var isScanning = false
    /// Files and folders seen so far in the current scan.
    private(set) var seen = 0
    /// Paths of the folders opened, from home inward.
    var trail: [String] = []
    /// Why the last Move to Trash failed, if it did.
    private(set) var trashError: String?

    /// Called after something was moved to the Trash (History and storage refresh).
    @ObservationIgnored var onTrashed: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let cacheURL = (try? CleanupLog.defaultURL())?.deletingLastPathComponent()
        .appendingPathComponent("space-lens.json")
    @ObservationIgnored private lazy var cleaner: Cleaner? = (try? CleanupLog.defaultURL()).map { Cleaner(log: CleanupLog(url: $0)) }

    /// A rule only Space Lens uses: Trash, never delete; the cleaner still refuses protected places.
    static let rule = CleanupRule(
        id: "space-lens", name: "Space Lens", detail: "Moved to the Trash from Space Lens.",
        tier: .review, action: .trash, regenerable: false, paths: ["~/*"]
    )

    private struct Cache: Codable {
        let tree: SpaceNode
        let scannedAt: Date
    }

    /// The folder being shown.
    var current: SpaceNode? {
        guard var node = tree else { return nil }
        for path in trail.dropFirst() {
            guard let next = node.children.first(where: { $0.path == path }) else { break }
            node = next
        }
        return node
    }

    var breadcrumb: [SpaceNode] {
        guard var node = tree else { return [] }
        var nodes = [node]
        for path in trail.dropFirst() {
            guard let next = node.children.first(where: { $0.path == path }) else { break }
            nodes.append(next)
            node = next
        }
        return nodes
    }

    func open(_ node: SpaceNode) {
        guard node.isDirectory, !node.isSkipped, !node.children.isEmpty else { return }
        if trail.isEmpty, let tree {
            trail = [tree.path]
        }
        trail.append(node.path)
    }

    func go(to node: SpaceNode) {
        if let index = trail.firstIndex(of: node.path) {
            trail = Array(trail.prefix(index + 1))
        }
    }

    func loadCache() {
        guard tree == nil, let cacheURL else { return }
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
            await MainActor.run {
                guard self.tree == nil else { return }
                self.tree = cache.tree
                self.scannedAt = cache.scannedAt
                self.trail = [cache.tree.path]
            }
        }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        seen = 0
        trashError = nil
        let includePrivate = FullDiskAccess.isGranted()
        let cacheURL = cacheURL
        task = Task {
            let scanner = SpaceScanner(includePrivateAreas: includePrivate)
            let result = try? await Task.detached(priority: .utility) {
                try await scanner.scan { count in
                    Task { @MainActor in self.seen = count }
                }
            }.value
            isScanning = false
            guard let result else { return }
            tree = result
            scannedAt = Date()
            // Stay in the same folder if it still exists.
            let kept = trail.filter { path in path == result.path || Self.find(path, in: result) != nil }
            trail = kept.isEmpty ? [result.path] : kept
            if let cacheURL, let data = try? JSONEncoder().encode(Cache(tree: result, scannedAt: Date())) {
                Task.detached(priority: .utility) { try? data.write(to: cacheURL, options: .atomic) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    /// Moves a file or folder to the Trash. It must still be the item Space Lens measured.
    func trash(_ node: SpaceNode) async {
        guard node.canTrash, let cleaner else { return }
        let url = URL(fileURLWithPath: node.path)
        let item = ScanItem(url: url, bytes: node.bytes, modified: nil, identity: FileIdentity(path: node.path))
        let outcome = await cleaner.clean([CleanupSelection(rule: Self.rule, items: [item])])
        if let failure = outcome.failures.first {
            trashError = failure.localizedReason
            return
        }
        trashError = nil
        if let tree {
            self.tree = Self.removing(node.path, bytes: node.bytes, from: tree)
        }
        onTrashed?()
    }

    private static func find(_ path: String, in node: SpaceNode) -> SpaceNode? {
        if node.path == path {
            return node
        }
        guard path.hasPrefix(node.path + "/") else { return nil }
        for child in node.children {
            if let found = find(path, in: child) {
                return found
            }
        }
        return nil
    }

    /// The tree without `path`, with the sizes of its folders reduced.
    private static func removing(_ path: String, bytes: UInt64, from node: SpaceNode) -> SpaceNode {
        guard path.hasPrefix(node.path + "/") else { return node }
        let children = node.children.filter { $0.path != path }.map { removing(path, bytes: bytes, from: $0) }
        return SpaceNode(
            name: node.name, path: node.path, bytes: node.bytes - min(node.bytes, bytes), isDirectory: node.isDirectory,
            children: children, otherCount: node.otherCount, otherBytes: node.otherBytes, isSkipped: node.isSkipped,
            canTrash: node.canTrash
        )
    }
}

#if DEBUG
    extension SpaceLensModel {
        func loadDemo(_ demo: SpaceNode) {
            tree = demo
            scannedAt = Date().addingTimeInterval(-600)
            trail = [demo.path]
        }
    }
#endif
