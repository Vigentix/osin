import Darwin
import Foundation

/// Where trashed items go. The live implementation uses the Finder Trash; tests use a fixture folder.
public protocol TrashMover: Sendable {
    /// Moves `url` to the Trash and returns its new location.
    func moveToTrash(_ url: URL) throws -> URL
}

public struct SystemTrash: TrashMover {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result as URL
    }
}

public struct CleanupSelection: Sendable {
    public let rule: CleanupRule
    public let items: [ScanItem]

    public init(rule: CleanupRule, items: [ScanItem]) {
        self.rule = rule
        self.items = items
    }
}

public struct TrashedItem: Sendable, Codable, Hashable {
    public let originalURL: URL
    public let trashURL: URL
    public let bytes: UInt64
    public let ruleID: String
    /// The item as it sits in the Trash. Restore refuses anything else at `trashURL`.
    public let identity: FileIdentity?

    public init(originalURL: URL, trashURL: URL, bytes: UInt64, ruleID: String, identity: FileIdentity? = nil) {
        self.originalURL = originalURL
        self.trashURL = trashURL
        self.bytes = bytes
        self.ruleID = ruleID
        self.identity = identity
    }
}

public struct CleanupFailure: Sendable, Identifiable {
    /// Why an item was not cleaned or restored. The app shows a localized sentence per kind.
    public enum Kind: Sendable, Equatable {
        case deleteNotAllowed
        case symbolicLink
        case throughSymbolicLink
        case outsideHome
        case protectedLocation
        /// Something else now has the scanned path (replaced or recreated since the scan).
        case changedSinceScan
        /// The item no longer meets the rule's minimum age.
        case usedRecently
        /// Part of the item could not be read, so its age could not be confirmed.
        case couldNotCheckAge
        /// The cleanup log cannot be written, so nothing is removed.
        case logUnavailable
        /// Restore: something already exists at the original location.
        case originalExists
        /// Restore: the item in the Trash is not the one Osin put there (or was never recorded).
        case notTheTrashedItem
        /// An error from the system, with its message.
        case system(String)
    }

    public var id: String {
        url.path
    }

    public let url: URL
    public let kind: Kind

    /// English description, for logs and tests.
    public var reason: String {
        switch kind {
        case .deleteNotAllowed: "Rule is not allowed to delete permanently."
        case .symbolicLink: "Item is a symbolic link."
        case .throughSymbolicLink: "Path goes through a symbolic link."
        case .outsideHome: "Item is outside your home folder."
        case .protectedLocation: "Item is in a protected location."
        case .changedSinceScan: "Item changed since the scan."
        case .usedRecently: "Item was used recently."
        case .couldNotCheckAge: "Part of the item could not be read, so its age could not be confirmed."
        case .logUnavailable: "The cleanup log cannot be written, so nothing was removed."
        case .originalExists: "Something already exists at the original location."
        case .notTheTrashedItem: "The item in the Trash is not the one Osin moved there."
        case let .system(message): message
        }
    }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    public init(url: URL, reason: String) {
        self.init(url: url, kind: .system(reason))
    }
}

public struct CleanupOutcome: Sendable {
    /// Space reclaimed immediately (deleted items and built-in actions).
    public var freedBytes: UInt64 = 0
    /// Space moved to the Trash: restorable, reclaimed only when the Trash is emptied.
    public var trashedBytes: UInt64 = 0
    public var trashed: [TrashedItem] = []
    public var failures: [CleanupFailure] = []
    /// `proceed` said no: this item and the ones after it were left untouched.
    public var stopped = false

    public init() {}
}

/// Performs cleanups chosen from a scan report.
///
/// Every item is re-checked at the moment of action, so anything that changed since the scan
/// (became a symlink, moved outside home, entered a protected folder) is refused. `delete` is only
/// honoured for safe, regenerable rules; everything else goes to the Trash (ADR 0003).
public actor Cleaner {
    private let home: URL
    private let protected: ProtectedPaths
    private let trash: TrashMover
    private let log: CleanupLog

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, trash: TrashMover = SystemTrash(), log: CleanupLog) {
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = resolved
        protected = ProtectedPaths(home: resolved)
        self.trash = trash
        self.log = log
    }

    /// `proceed` is asked right before each removal, after the item's checks (which can take a while
    /// for large folders); when it returns false, cleaning stops and `stopped` is set.
    public func clean(_ selections: [CleanupSelection], proceed: @Sendable () -> Bool = { true }) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard log.isWritable() else {
            outcome.failures = selections.flatMap { $0.items.map { CleanupFailure(url: $0.url, kind: .logUnavailable) } }
            return outcome
        }
        for selection in selections {
            let rule = selection.rule
            let cutoff = rule.minAgeDays.map { Date().addingTimeInterval(-Double($0) * 86400) }
            for item in selection.items {
                if rule.action == .delete, rule.tier != .safe || !rule.regenerable {
                    outcome.failures.append(CleanupFailure(url: item.url, kind: .deleteNotAllowed))
                    continue
                }
                switch check(item, cutoff: cutoff) {
                case .missing:
                    continue
                case let .refused(kind):
                    outcome.failures.append(CleanupFailure(url: item.url, kind: kind))
                    continue
                case .ok:
                    break
                }
                guard proceed() else {
                    outcome.stopped = true
                    return outcome
                }
                do {
                    switch rule.action {
                    case .delete:
                        try FileManager.default.removeItem(at: item.url)
                        outcome.freedBytes += item.bytes
                        try? log.append(.init(ruleID: rule.id, action: "delete", path: item.url.path, bytes: item.bytes))
                    case .trash:
                        let destination = try trash.moveToTrash(item.url)
                        let identity = FileIdentity(path: destination.path)
                        outcome.trashedBytes += item.bytes
                        outcome.trashed.append(TrashedItem(
                            originalURL: item.url,
                            trashURL: destination,
                            bytes: item.bytes,
                            ruleID: rule.id,
                            identity: identity
                        ))
                        try? log.append(.init(
                            ruleID: rule.id,
                            action: "trash",
                            path: item.url.path,
                            bytes: item.bytes,
                            trashPath: destination.path,
                            identity: identity
                        ))
                    }
                } catch {
                    outcome.failures.append(CleanupFailure(url: item.url, kind: .system(error.localizedDescription)))
                }
            }
        }
        return outcome
    }

    /// Moves trashed items back. Never overwrites something that now exists at the original path, and
    /// only moves the exact item Osin trashed: the Trash reuses names once earlier items are gone.
    public func undo(_ items: [TrashedItem]) -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        for item in items {
            guard let identity = item.identity, FileIdentity(path: item.trashURL.path) == identity else {
                failures.append(CleanupFailure(url: item.originalURL, kind: .notTheTrashedItem))
                continue
            }
            if let problem = destinationProblem(item.originalURL) {
                failures.append(CleanupFailure(url: item.originalURL, kind: problem))
                continue
            }
            var info = stat()
            if lstat(item.originalURL.path, &info) == 0 {
                failures.append(CleanupFailure(url: item.originalURL, kind: .originalExists))
                continue
            }
            do {
                try FileManager.default.createDirectory(at: item.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.trashURL, to: item.originalURL)
                try? log.append(.init(
                    ruleID: item.ruleID,
                    action: "restore",
                    path: item.originalURL.path,
                    bytes: item.bytes,
                    trashPath: item.trashURL.path,
                    identity: identity
                ))
            } catch {
                failures.append(CleanupFailure(url: item.originalURL, kind: .system(error.localizedDescription)))
            }
        }
        return failures
    }

    /// Permanently removes everything in `~/.Trash`, one item at a time. An item that cannot be
    /// removed (locked, owned by root) is reported and the rest still go; each removal is logged
    /// with the size measured right before it.
    public func emptyTrash() -> (freedBytes: UInt64, failures: [CleanupFailure]) {
        let trashURL = EmptyTrash.trashURL(home: home)
        var freed: UInt64 = 0
        var failures: [CleanupFailure] = []
        guard log.isWritable() else {
            return (0, [CleanupFailure(url: trashURL, kind: .logUnavailable)])
        }
        // The Trash must be a real folder: listing a linked one would delete another folder's contents.
        var info = stat()
        guard lstat(trashURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return (0, [CleanupFailure(url: trashURL, kind: .symbolicLink)])
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
        } catch {
            return (0, [CleanupFailure(url: trashURL, kind: .system(error.localizedDescription))])
        }
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let bytes = (try? DiskUsage.allocatedSize(of: item)) ?? 0
            do {
                try FileManager.default.removeItem(at: item)
                freed += bytes
                try? log.append(.init(ruleID: "builtin.empty-trash", action: "builtin:empty-trash", path: item.path, bytes: bytes))
            } catch {
                failures.append(CleanupFailure(url: item, kind: .system(error.localizedDescription)))
            }
        }
        return (freed, failures)
    }

    /// Records a built-in action that the caller performed.
    public func record(builtin kind: String, bytes: UInt64) {
        try? log.append(.init(ruleID: "builtin.\(kind)", action: "builtin:\(kind)", path: "", bytes: bytes))
    }

    // MARK: - Time-of-use checks

    /// Where a restore would write must be inside home, outside protected locations, and reached
    /// without links: a parent swapped for a symlink would redirect the restore elsewhere.
    private func destinationProblem(_ url: URL) -> CleanupFailure.Kind? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/") else { return .outsideHome }
        guard !protected.denies(URL(fileURLWithPath: path)) else { return .protectedLocation }
        var current = home
        for component in path.dropFirst(home.path.count + 1).split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            var info = stat()
            guard lstat(current.path, &info) == 0 else { break } // missing parents are created as real folders
            if info.st_mode & S_IFMT == S_IFLNK {
                return .throughSymbolicLink
            }
        }
        return nil
    }

    private enum Check {
        case ok
        case missing
        case refused(CleanupFailure.Kind)
    }

    private func check(_ item: ScanItem, cutoff: Date?) -> Check {
        let url = item.url
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        if info.st_mode & S_IFMT == S_IFLNK {
            return .refused(.symbolicLink)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == path else { return .refused(.throughSymbolicLink) }
        guard path.hasPrefix(home.path + "/") else { return .refused(.outsideHome) }
        guard !protected.denies(URL(fileURLWithPath: path)) else { return .refused(.protectedLocation) }
        // Items must come from a scan, which records what each path referred to.
        guard let identity = item.identity, FileIdentity(path: path) == identity else {
            return .refused(.changedSinceScan)
        }
        if let cutoff {
            guard let usage = try? DiskUsage.measure(url), usage.isComplete else {
                return .refused(.couldNotCheckAge)
            }
            if let newest = usage.newestModification, newest > cutoff {
                return .refused(.usedRecently)
            }
            // Walking a large folder takes time: make sure it is still the same item afterwards.
            guard FileIdentity(path: path) == identity else {
                return .refused(.changedSinceScan)
            }
        }
        return .ok
    }
}
