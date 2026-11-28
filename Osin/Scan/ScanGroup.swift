import Foundation
import OsinCore

extension ScanCoordinator {
    /// A report row: a rule result or a built-in action.
    struct Group: Identifiable {
        enum Kind {
            case rule(RuleScanResult)
            case simulators(count: Int)
            case emptyTrash
            /// Docker build cache, cleaned with `docker builder prune` on the daemon at `host`.
            case dockerBuildCache(host: String)
            case dockerImages(host: String, [DockerInventory.Image])
            /// Each volume can be left out on its own (they may hold databases).
            case dockerVolumes(host: String, [DockerInventory.Volume])
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

        /// Cannot be undone and is not regenerable (Docker's build cache is rebuilt, so it is not).
        var isIrreversible: Bool {
            switch kind {
            case .rule, .dockerBuildCache: false
            case .simulators, .emptyTrash, .dockerImages, .dockerVolumes: true
            }
        }

        var items: [ScanItem] {
            if case let .rule(result) = kind {
                return result.items
            }
            return []
        }

        /// Waiting for an app to be closed.
        var blockedBytes: UInt64 {
            if case let .rule(result) = kind {
                return result.blockedBytes
            }
            return 0
        }

        var blockingApps: [String] {
            if case let .rule(result) = kind {
                return result.blockingApps
            }
            return []
        }

        /// What Clean can remove right now.
        var cleanableBytes: UInt64 {
            bytes - min(bytes, blockedBytes)
        }
    }

    struct Step: Identifiable {
        let id: Int
        let name: String
        var bytes: UInt64?
    }

    static let dockerBuildCacheID = "builtin.docker-build-cache"
    static let dockerImagesID = "builtin.docker-images"
    static let dockerVolumesID = "builtin.docker-volumes"

    static func volumeItemID(_ name: String) -> String {
        "docker-volume:\(name)"
    }

    static func dockerGroups(_ usage: DockerInventory.Usage) -> [Group] {
        var groups: [Group] = []
        if usage.buildCacheBytes > 0 {
            groups.append(Group(
                id: dockerBuildCacheID, name: String(localized: "Docker build cache"),
                detail: String(
                    localized: "Layers kept from earlier image builds. Docker rebuilds them when needed; the next build may be slower."
                ),
                tier: .safe, bytes: usage.buildCacheBytes, kind: .dockerBuildCache(host: usage.host), needsAccess: false
            ))
        }
        let imageBytes = usage.danglingImages.reduce(UInt64(0)) { $0 + $1.bytes }
        if imageBytes > 0 {
            groups.append(Group(
                id: dockerImagesID, name: String(localized: "Unused Docker images"),
                detail: String(
                    localized: "\(usage.danglingImages.count) untagged images no container uses, usually left over from rebuilds."
                ),
                tier: .review, bytes: imageBytes, kind: .dockerImages(host: usage.host, usage.danglingImages), needsAccess: false
            ))
        }
        let volumeBytes = usage.unusedVolumes.reduce(UInt64(0)) { $0 + $1.bytes }
        if !usage.unusedVolumes.isEmpty {
            groups.append(Group(
                id: dockerVolumesID, name: String(localized: "Unused Docker volumes"),
                detail: String(localized: "Volumes no container uses. They can hold databases or uploads: untick any you still need."),
                tier: .review, bytes: volumeBytes, kind: .dockerVolumes(host: usage.host, usage.unusedVolumes), needsAccess: false
            ))
        }
        return groups
    }

    /// Runs a Docker group's command and logs it. Volumes the user unticked are kept.
    func cleanDocker(_ group: Group, excluded: Set<String>, cleaner: Cleaner) async -> (freed: UInt64, failures: [CleanupFailure]) {
        do {
            switch group.kind {
            case let .dockerBuildCache(host):
                try await DockerInventory.pruneBuildCache(host: host)
                await cleaner.record(builtin: "docker-build-cache", bytes: group.bytes)
                return (group.bytes, [])
            case let .dockerImages(host, images):
                try await DockerInventory.removeImages(images.map(\.id), host: host)
                await cleaner.record(builtin: "docker-images", bytes: group.bytes)
                return (group.bytes, [])
            case let .dockerVolumes(host, volumes):
                let chosen = volumes.filter { !excluded.contains(Self.volumeItemID($0.name)) }
                try await DockerInventory.removeVolumes(chosen, host: host)
                let bytes = chosen.reduce(UInt64(0)) { $0 + $1.bytes }
                await cleaner.record(builtin: "docker-volumes", bytes: bytes)
                return (bytes, [])
            default:
                return (0, [])
            }
        } catch {
            let reason = String(localized: "Docker did not finish the cleanup. Check that Docker is running and try again.")
            return (0, [CleanupFailure(url: URL(fileURLWithPath: "docker"), reason: reason)])
        }
    }
}

extension ScanCoordinator {
    /// Names of the selected groups that cannot be undone, for the confirmation ("Empty Trash and Unused Docker images").
    var irreversibleSelectionNames: String {
        ListFormatter.localizedString(byJoining: groups.filter { selectedGroups.contains($0.id) && $0.isIrreversible }.map(\.name))
    }

    /// Scans one rule group again (after the user quit the app that blocked it).
    func rescanGroup(_ id: String) {
        guard !isBusy, let group = groups.first(where: { $0.id == id }), case let .rule(result) = group.kind else { return }
        let rule = result.rule
        Task {
            guard let fresh = try? await Scanner(projectRoots: Preferences.projectRoots).scan([rule]) else { return }
            replaceGroups(with: fresh)
            onScanFinished?()
        }
    }
}

extension ScanCoordinator {
    /// Moves an item picked in Space Lens to the Trash, one cleanup at a time with everything else (an
    /// Empty Trash running meanwhile would otherwise remove it for good).
    func trashSelected(_ item: ScanItem) async -> CleanupFailure? {
        guard !isBusy, !isScanningInBackground, let cleaner else {
            return CleanupFailure(url: item.url, reason: String(localized: "Osin is busy cleaning. Try again in a moment."))
        }
        isTrashingSelection = true
        defer { isTrashingSelection = false }
        let outcome = await cleaner.clean([CleanupSelection(rule: SpaceLensModel.rule, items: [item])])
        historyRevision += 1
        onCleaned?()
        return outcome.failures.first
    }
}
