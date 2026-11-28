import Darwin
import Foundation

/// Something a rule matched: a file or folder that can be cleaned as a unit.
public struct ScanItem: Sendable, Identifiable, Hashable {
    public var id: String {
        url.path
    }

    public let url: URL
    public let bytes: UInt64
    /// Newest modification date of the item or anything inside it.
    public let modified: Date?
    /// The scanned file or folder itself, checked again before cleaning.
    public let identity: FileIdentity?
    /// The app (display name) that must be closed before this item can be cleaned; it was running at scan time.
    public let blockedBy: String?

    public init(url: URL, bytes: UInt64, modified: Date?, identity: FileIdentity? = nil, blockedBy: String? = nil) {
        self.url = url
        self.bytes = bytes
        self.modified = modified
        self.identity = identity
        self.blockedBy = blockedBy
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

    /// Bytes waiting for an app to be closed.
    public var blockedBytes: UInt64 {
        items.filter { $0.blockedBy != nil }.reduce(0) { $0 + $1.bytes }
    }

    /// Apps to close to clean everything, in first-seen order.
    public var blockingApps: [String] {
        var seen: [String] = []
        for case let name? in items.map(\.blockedBy) where !seen.contains(name) {
            seen.append(name)
        }
        return seen
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
    /// Extra project folders from Settings, searched by rules with `includeProjectRoots`.
    public let projectRoots: [URL]
    private let protected: ProtectedPaths
    private let runningApps: @Sendable () -> Set<String>

    /// Project folders searched by default (cold projects, toolchain pins).
    public static let defaultProjectRoots = [
        "Projects", "Developer", "Code", "code", "src", "dev", "workspace", "repos", "git", "GitHub"
    ]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL] = [],
        runningApps: @escaping @Sendable () -> Set<String> = AppActivity.runningAppNames
    ) {
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = resolved
        protected = ProtectedPaths(home: resolved)
        self.runningApps = runningApps
        // Only folders inside home that are not protected.
        self.projectRoots = projectRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }.filter { root in
            root.path.hasPrefix(resolved.path + "/") && !ProtectedPaths(home: resolved).denies(root)
        }
    }

    /// Default and user project folders that exist.
    var allProjectRoots: [URL] {
        ProjectRoots.all(home: home, extra: projectRoots)
    }

    public func scan(_ rules: [CleanupRule], progress: @Sendable (ScanProgress) -> Void = { _ in }) async throws -> [RuleScanResult] {
        var claimed = ClaimedPaths()
        var results: [RuleScanResult] = []
        let running = rules.contains { !$0.closedApps.isEmpty } ? runningApps() : []
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
            let coldCutoff = rule.find?.coldDays.map { Date().addingTimeInterval(-Double($0) * 86400) }
            let kept = rule.special == .unusedToolchains ? ToolchainUsage.keptPaths(home: home, projectRoots: allProjectRoots) : []
            var items: [ScanItem] = []
            for candidate in collector.candidates {
                try Task.checkCancellation()
                let path = candidate.url.path
                let name = candidate.url.lastPathComponent
                guard !rule.excludes.contains(where: { Self.matches($0, name) }), !claimed.overlaps(path) else { continue }
                if rule.special == .unusedToolchains, kept.contains(path) {
                    continue
                }
                if let coldCutoff, let project = candidate.project,
                   ProjectActivity.isActive(
                       project: project,
                       target: candidate.url,
                       within: candidate.searchRoot ?? project,
                       since: coldCutoff
                   )
                {
                    continue
                }
                if let cutoff, let modified = candidate.modified, modified > cutoff {
                    continue
                }
                // Identity before measuring, checked again after: the numbers must belong to this item.
                guard let identity = FileIdentity(path: path) else { continue }
                let usage = try DiskUsage.measure(candidate.url)
                guard FileIdentity(path: path) == identity else { continue }
                let newest = [candidate.modified, usage.newestModification].compactMap(\.self).max()
                // A folder's own date only changes when entries are added or removed directly in it,
                // so age is judged by the newest thing inside (an active node_modules stays put). If part
                // of it could not be read, its age is unknown and it is not offered.
                if let cutoff, !usage.isComplete || (newest.map { $0 > cutoff } ?? false) {
                    if !usage.isComplete {
                        collector.needsAccess = true // tell the user why something may be missing
                    }
                    continue
                }
                let blocker = rule.closedApp(for: candidate.url, home: home).flatMap { running.contains($0.app) ? $0.displayName : nil }
                items.append(ScanItem(url: candidate.url, bytes: usage.bytes, modified: newest, identity: identity, blockedBy: blocker))
                claimed.insert(path)
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
        /// For `find` matches: the project folder the directory belongs to, and the root it was found under.
        var project: URL?
        var searchRoot: URL?
    }

    private struct Collector {
        var candidates: [Candidate] = []
        var seen: Set<String> = []
        var needsAccess = false

        mutating func add(_ url: URL, modified: Date?, project: URL? = nil, searchRoot: URL? = nil) {
            if seen.insert(url.path).inserted {
                candidates.append(Candidate(url: url, modified: modified, project: project, searchRoot: searchRoot))
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
                // A symlinked folder on the way is caught below: its matches' real paths differ.
                for entry in entries where Self.matches(component, entry.lastPathComponent) {
                    next.append(entry)
                }
            }
            level = next
        }
        for url in level {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), values.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            // The path as matched must be the real path: no link anywhere below the root.
            guard resolved.path == url.standardizedFileURL.path, resolved.path.hasPrefix(resolvedRoot.path + "/"),
                  !protected.denies(resolved)
            else { continue }
            collector.add(resolved, modified: values.contentModificationDate)
        }
    }

    private func collectFind(_ find: CleanupRule.Find, into collector: inout Collector) throws {
        var roots: [URL] = []
        for root in find.roots where root.hasPrefix("~/") {
            let components = root.dropFirst(2).split(separator: "/").map(String.init)
            guard !components.contains(".."), !components.contains(".") else { continue }
            roots.append(components.reduce(home) { $0.appendingPathComponent($1) })
        }
        if find.includeProjectRoots {
            roots += projectRoots
        }
        var walked = Set<String>()
        for rootURL in roots {
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedRoot.path.hasPrefix(home.path + "/"), !protected.denies(resolvedRoot),
                  // A user folder inside a default one (or the same folder twice) is walked once.
                  !walked.contains(where: { resolvedRoot.path == $0 || resolvedRoot.path.hasPrefix($0 + "/") })
            else { continue }
            walked.insert(resolvedRoot.path)
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
            if let target = find.targets.first(where: { $0.name == entry.lastPathComponent }) {
                if Self.hasMarker(target, at: resolved) {
                    collector.add(resolved, modified: values.contentModificationDate, project: directory, searchRoot: root)
                }
                // A matching name is never descended into, marker or not (no node_modules inside node_modules).
            } else if depth < find.maxDepth, !entry.lastPathComponent.hasPrefix(".") {
                try walk(resolved, depth: depth + 1, find: find, root: root, into: &collector)
            }
        }
    }

    static func hasMarker(_ target: CleanupRule.Find.Target, at directory: URL) -> Bool {
        if let inside = target.inside, !FileManager.default.fileExists(atPath: directory.appendingPathComponent(inside).path) {
            return false
        }
        if let sibling = target.sibling {
            let parent = directory.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return names.contains { matches(sibling, $0) }
        }
        return true
    }

    // MARK: - Helpers

    /// Shell-style matching where `*` never matches a leading dot, so `~/Downloads/*` skips
    /// `.localized` and `.DS_Store`.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD) == 0
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

/// Disk usage measurement shared by the scanner, the cleaner and built-in cleanups.
enum DiskUsage {
    struct Usage {
        var bytes: UInt64 = 0
        var newestModification: Date?
        /// False when some descendant could not be read, so the size and newest date are lower bounds.
        var isComplete = true
    }

    /// Allocated size on disk. Symlinks inside folders are counted as links, never followed.
    static func allocatedSize(of url: URL) throws -> UInt64 {
        try measure(url).bytes
    }

    /// Allocated size and the newest modification date of `url` and everything inside it.
    ///
    /// A hard-linked file only counts when all of its links are inside `url`: removing one link of a
    /// file that is still linked elsewhere (a pnpm store shared with projects) frees nothing.
    /// Walks with `fts` (physical: symlinks are counted as links, never followed), which is several
    /// times faster than FileManager's enumerator on caches with many small files.
    static func measure(_ scannedURL: URL) throws -> Usage {
        var usage = Usage()
        var linked: [FileIdentity: (seen: Int, links: Int, bytes: UInt64)] = [:]

        func add(_ info: stat, countBytes: Bool) {
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            if date > (usage.newestModification ?? .distantPast) {
                usage.newestModification = date
            }
            guard countBytes else { return }
            let bytes = UInt64(max(0, info.st_blocks)) * 512
            if info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 {
                let identity = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                let entry = linked[identity] ?? (0, Int(info.st_nlink), bytes)
                linked[identity] = (entry.seen + 1, entry.links, entry.bytes)
            } else {
                usage.bytes += bytes
            }
        }

        let path = scannedURL.path
        var root = stat()
        guard lstat(path, &root) == 0 else {
            usage.isComplete = false
            return usage
        }
        guard root.st_mode & S_IFMT == S_IFDIR else {
            add(root, countBytes: true)
            return usage
        }
        guard let cPath = strdup(path) else { throw CocoaError(.fileReadUnknown) }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            usage.isComplete = false
            return usage
        }
        defer { fts_close(fts) }
        var counter = 0
        while let entry = fts_read(fts) {
            counter += 1
            if counter % 4096 == 0 {
                try Task.checkCancellation()
            }
            let kind = Int32(entry.pointee.fts_info)
            let info = entry.pointee.fts_statp?.pointee
            switch kind {
            case FTS_D:
                // Folders count for age, not size (as before: only files and links are summed).
                if let info {
                    add(info, countBytes: false)
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let info {
                    add(info, countBytes: true)
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.isComplete = false
            default:
                break // FTS_DP (folder done), FTS_DC (cycle)
            }
        }
        for entry in linked.values where entry.seen >= entry.links {
            usage.bytes += entry.bytes
        }
        return usage
    }
}

/// Paths already claimed by a rule. `overlaps` is O(path depth) instead of O(claimed paths):
/// a candidate overlaps when it equals, contains or sits inside a claimed path.
struct ClaimedPaths {
    private var claimed: Set<String> = []
    /// Every proper ancestor of a claimed path.
    private var ancestors: Set<String> = []

    mutating func insert(_ path: String) {
        claimed.insert(path)
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/"), slash > current.startIndex {
            current = current[..<slash]
            // An ancestor already recorded means all of its own ancestors are too.
            guard ancestors.insert(String(current)).inserted else { break }
        }
    }

    func overlaps(_ path: String) -> Bool {
        if claimed.contains(path) || ancestors.contains(path) {
            return true
        }
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/"), slash > current.startIndex {
            current = current[..<slash]
            if claimed.contains(String(current)) {
                return true
            }
        }
        return false
    }
}
