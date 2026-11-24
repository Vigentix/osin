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

    public init(originalURL: URL, trashURL: URL, bytes: UInt64, ruleID: String) {
        self.originalURL = originalURL
        self.trashURL = trashURL
        self.bytes = bytes
        self.ruleID = ruleID
    }
}

public struct CleanupFailure: Sendable, Identifiable {
    public var id: String {
        url.path
    }

    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct CleanupOutcome: Sendable {
    /// Space reclaimed immediately (deleted items and built-in actions).
    public var freedBytes: UInt64 = 0
    /// Space moved to the Trash: restorable, reclaimed only when the Trash is emptied.
    public var trashedBytes: UInt64 = 0
    public var trashed: [TrashedItem] = []
    public var failures: [CleanupFailure] = []

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

    public func clean(_ selections: [CleanupSelection]) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        for selection in selections {
            let rule = selection.rule
            for item in selection.items {
                if rule.action == .delete, rule.tier != .safe || !rule.regenerable {
                    outcome.failures.append(CleanupFailure(url: item.url, reason: "Rule is not allowed to delete permanently."))
                    continue
                }
                switch check(item.url) {
                case .missing:
                    continue
                case let .refused(reason):
                    outcome.failures.append(CleanupFailure(url: item.url, reason: reason))
                    continue
                case .ok:
                    break
                }
                do {
                    switch rule.action {
                    case .delete:
                        try FileManager.default.removeItem(at: item.url)
                        outcome.freedBytes += item.bytes
                        try? log.append(.init(ruleID: rule.id, action: "delete", path: item.url.path, bytes: item.bytes))
                    case .trash:
                        let destination = try trash.moveToTrash(item.url)
                        outcome.trashedBytes += item.bytes
                        outcome.trashed.append(TrashedItem(
                            originalURL: item.url,
                            trashURL: destination,
                            bytes: item.bytes,
                            ruleID: rule.id
                        ))
                        try? log.append(.init(
                            ruleID: rule.id,
                            action: "trash",
                            path: item.url.path,
                            bytes: item.bytes,
                            trashPath: destination.path
                        ))
                    }
                } catch {
                    outcome.failures.append(CleanupFailure(url: item.url, reason: error.localizedDescription))
                }
            }
        }
        return outcome
    }

    /// Moves trashed items back. Never overwrites something that now exists at the original path.
    public func undo(_ items: [TrashedItem]) -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        for item in items {
            var info = stat()
            if lstat(item.originalURL.path, &info) == 0 {
                failures.append(CleanupFailure(url: item.originalURL, reason: "Something already exists at the original location."))
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
                    trashPath: item.trashURL.path
                ))
            } catch {
                failures.append(CleanupFailure(url: item.originalURL, reason: error.localizedDescription))
            }
        }
        return failures
    }

    /// Records a built-in action that the caller performed.
    public func record(builtin kind: String, bytes: UInt64) {
        try? log.append(.init(ruleID: "builtin.\(kind)", action: "builtin:\(kind)", path: "", bytes: bytes))
    }

    // MARK: - Time-of-use checks

    private enum Check {
        case ok
        case missing
        case refused(String)
    }

    private func check(_ url: URL) -> Check {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        if info.st_mode & S_IFMT == S_IFLNK {
            return .refused("Item is a symbolic link.")
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == path else { return .refused("Path goes through a symbolic link.") }
        guard path.hasPrefix(home.path + "/") else { return .refused("Item is outside your home folder.") }
        guard !protected.denies(URL(fileURLWithPath: path)) else { return .refused("Item is in a protected location.") }
        return .ok
    }
}
