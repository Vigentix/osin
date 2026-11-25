import Darwin
import Foundation

/// Something a rule matched: a file or folder that can be cleaned as a unit.
public struct ScanItem: Sendable, Identifiable, Hashable {
    public var id: String {
        url.path
    }

    public let url: URL
    public let bytes: UInt64
    public let modified: Date?

    public init(
        url: URL,
        bytes: UInt64,
        modified: Date?
    ) {
        self.url = url
        self.bytes = bytes
        self.modified = modified
    }
}

public struct RuleScanResult: Sendable, Identifiable {
    public var id: String {
        rule.id
    }

    public let rule: CleanupRule
    public let items: [ScanItem]
    /// Part of the rule could not be read (usually missing Full Disk Access).
    public let needsAccess: Bool

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public init(
        rule: CleanupRule,
        items: [ScanItem],
        needsAccess: Bool
    ) {
        self.rule = rule
        self.items = items
        self.needsAccess = needsAccess
    }
}

/// Sent when a rule starts (`completed == nil`) and again when it finishes, with its result.
public struct ScanProgress: Sendable {
    public let ruleID: String
    public let index: Int
    public let count: Int
    public let completed: RuleScanResult?
}

/// Read-only evaluation of cleanup rules. Never modifies anything.
///
/// Safety guarantees (covered by `ScannerTests`):
/// - only `~/`-relative paths are expanded, without shell or environment expansion;
/// - symlinks are never followed: symlinked candidates are skipped and measuring does not traverse them;
/// - every candidate, resolved, must stay inside its rule's resolved root and pass `ProtectedPaths`;
/// - an item is claimed by at most one rule.
public struct Scanner: Sendable {
    public let home: URL
    private let protected: ProtectedPaths

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = resolved
        protected = ProtectedPaths(home: resolved)
    }

    public func scan(_ rules: [CleanupRule], progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [RuleScanResult] {
        var claimed: [String] = []
        var results: [RuleScanResult] = []
        for (index, rule) in rules.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(ruleID: rule.id, index: index, count: rules.count, completed: nil))
            var collector = Collector()
            if let find = rule.find {
                try collectFind(find, into: &collector)
            }
            for pattern in rule.paths {
                try collectPattern(pattern, into: &collector)
            }
            let cutoff = rule.minAgeDays.map { Date().addingTimeInterval(-Double($0) * 86400) }
            var items: [ScanItem] = []
            for candidate in collector.candidates {
                try Task.checkCancellation()
                let path = candidate.url.path
                let name = candidate.url.lastPathComponent
                guard !rule.excludes.contains(where: { Self.matches($0, name) }), !Self.overlaps(path, claimed) else { continue }
                if let cutoff, let modified = candidate.modified, modified > cutoff {
                    continue
                }
                let bytes = try DiskUsage.allocatedSize(of: candidate.url)
                items.append(ScanItem(url: candidate.url, bytes: bytes, modified: candidate.modified))
                claimed.append(path)
            }
            let result = RuleScanResult(rule: rule, items: items, needsAccess: collector.needsAccess)
            results.append(result)
            progress(ScanProgress(ruleID: rule.id, index: index, count: rules.count, completed: result))
        }
        return results
    }

    // MARK: - Matching

    private struct Candidate {
        let url: URL
        let modified: Date?
    }

    private struct Collector {
        var candidates: [Candidate] = []
        var seen: Set<String> = []
        var needsAccess = false

        mutating func add(_ url: URL, modified: Date?) {
            if seen.insert(url.path).inserted {
                candidates.append(Candidate(url: url, modified: modified))
            }
        }
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    private func collectPattern(_ pattern: String, into collector: inout Collector) throws {
        guard pattern.hasPrefix("~/") else { return }
        let components = pattern.dropFirst(2).split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { return }

        let fixed = components.prefix { !$0.contains("*") }
        let rootURL = fixed.reduce(home) { $0.appendingPathComponent($1) }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path.hasPrefix(home.path + "/"), !protected.denies(resolvedRoot),
              fixed.count < components.count else { return } // validation requires a glob; refuse otherwise

        var level = [resolvedRoot]
        for component in components.dropFirst(fixed.count) {
            var next: [URL] = []
            for directory in level {
                let entries: [URL]
                do {
                    entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Self.keys)
                } catch {
                    if Self.isPermissionError(error) {
                        collector.needsAccess = true
                    }
                    continue
                }
                for entry in entries where Self.matches(component, entry.lastPathComponent) {
                    next.append(entry)
                }
            }
            level = next
        }
        for url in level {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), values.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedRoot.path + "/"), !protected.denies(resolved) else { continue }
            collector.add(resolved, modified: values.contentModificationDate)
        }
    }

    private func collectFind(_ find: CleanupRule.Find, into collector: inout Collector) throws {
        for root in find.roots where root.hasPrefix("~/") {
            let components = root.dropFirst(2).split(separator: "/").map(String.init)
            guard !components.contains(".."), !components.contains(".") else { continue }
            let rootURL = components.reduce(home) { $0.appendingPathComponent($1) }
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedRoot.path.hasPrefix(home.path + "/"), !protected.denies(resolvedRoot) else { continue }
            try walk(resolvedRoot, depth: 1, find: find, root: resolvedRoot, into: &collector)
        }
    }

    private func walk(_ directory: URL, depth: Int, find: CleanupRule.Find, root: URL, into collector: inout Collector) throws {
        try Task.checkCancellation()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Self.keys)
        } catch {
            if Self.isPermissionError(error) {
                collector.needsAccess = true
            }
            return
        }
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(Self.keys)),
                  values.isSymbolicLink != true, values.isDirectory == true
            else { continue }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"), !protected.denies(resolved) else { continue }
            if entry.lastPathComponent == find.directoryName {
                collector.add(resolved, modified: values.contentModificationDate)
            } else if depth < find.maxDepth {
                try walk(resolved, depth: depth + 1, find: find, root: root, into: &collector)
            }
        }
    }

    // MARK: - Helpers

    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// True when `path` equals, contains or sits inside an already claimed path.
    static func overlaps(_ path: String, _ claimed: [String]) -> Bool {
        claimed.contains { other in
            path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES))
    }
}

/// Disk usage measurement shared by the scanner and built-in cleanups.
enum DiskUsage {
    /// Allocated size on disk. Symlinks inside folders are counted as links, never followed.
    static func allocatedSize(of url: URL) throws -> UInt64 {
        let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if values.isDirectory != true || values.isSymbolicLink == true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            errorHandler: { _, _ in true }
        )
        else { return 0 }
        var total: UInt64 = 0
        var counter = 0
        for case let child as URL in enumerator {
            counter += 1
            if counter % 2000 == 0 {
                try Task.checkCancellation()
            }
            guard let childValues = try? child.resourceValues(forKeys: sizeKeys) else { continue }
            if childValues.isSymbolicLink == true {
                enumerator.skipDescendants()
            }
            if childValues.isDirectory != true || childValues.isSymbolicLink == true {
                total += UInt64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
