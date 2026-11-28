import Darwin
import Foundation

/// One file or folder in Space Lens, with its size on disk.
public struct SpaceNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String {
        path
    }

    public let name: String
    public let path: String
    public let bytes: UInt64
    public let isDirectory: Bool
    /// The largest entries (up to `SpaceScanner.childLimit`); the rest are folded into `other…`.
    public let children: [SpaceNode]
    public let otherCount: Int
    public let otherBytes: UInt64
    /// Not measured: macOS protects it (needs Full Disk Access) or it holds cloud files.
    public let isSkipped: Bool
    /// Whether Space Lens offers Move to Trash (never for protected locations or system folders).
    public let canTrash: Bool
    /// What the path referred to when it was measured; Move to Trash refuses anything else.
    public let identity: FileIdentity?

    public init(
        name: String, path: String, bytes: UInt64, isDirectory: Bool, children: [SpaceNode] = [],
        otherCount: Int = 0, otherBytes: UInt64 = 0, isSkipped: Bool = false, canTrash: Bool = true, identity: FileIdentity? = nil
    ) {
        self.identity = identity
        self.name = name
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.children = children
        self.otherCount = otherCount
        self.otherBytes = otherBytes
        self.isSkipped = isSkipped
        self.canTrash = canTrash
    }
}

/// Measures the home folder for Space Lens. Read-only; never follows symbolic links; skips the folders
/// macOS guards with a privacy prompt unless Full Disk Access was granted.
public struct SpaceScanner: Sendable {
    public static let childLimit = 40
    /// Folders below this depth are measured but not broken down.
    static let maxDepth = 8

    /// Opening these without Full Disk Access shows a macOS privacy prompt (or fails).
    static let privateAreas = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash",
        "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Calendars", "Library/Reminders", "Library/HomeKit", "Library/Cookies", "Library/Suggestions",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Application Support/Knowledge", "Library/Metadata/CoreSpotlight"
    ]

    /// Listing these can make macOS fetch file lists from the cloud: always skipped.
    static let cloudAreas = ["Library/CloudStorage", "Library/Mobile Documents"]

    public let home: URL
    public let includePrivateAreas: Bool
    /// Smaller files and folders are counted but not listed, so the tree stays small.
    public let minNodeBytes: UInt64
    private let protected: ProtectedPaths
    private let guide: FolderGuide

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includePrivateAreas: Bool = false,
        minNodeBytes: UInt64 = 1_000_000,
        guide: FolderGuide = .bundled
    ) {
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = resolved
        self.includePrivateAreas = includePrivateAreas
        self.minNodeBytes = minNodeBytes
        protected = ProtectedPaths(home: resolved)
        self.guide = guide
    }

    /// Measures `root` (default: home). `progress` gets the number of items seen so far, now and then.
    /// Walks with `fts` (what `du` uses): physical (no symlinks followed), one device, no chdir.
    public func scan(root: URL? = nil, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> SpaceNode {
        let start = (root ?? home).resolvingSymlinksInPath().standardizedFileURL
        guard let cPath = strdup(start.path) else { throw CocoaError(.fileReadUnknown) }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { fts_close(fts) }

        var walk = Walk(scanner: self)
        var seen = 0
        while let entry = fts_read(fts) {
            seen += 1
            if seen % 4096 == 0 {
                try Task.checkCancellation()
                progress(seen)
            }
            if walk.visit(entry.pointee) == .skip {
                fts_set(fts, entry, FTS_SKIP)
            }
        }
        return walk.result ?? node(start, bytes: 0, isDirectory: true)
    }

    /// The state of one walk: the folders currently open, innermost last.
    private struct Walk {
        enum Instruction {
            case next
            case skip
        }

        let scanner: SpaceScanner
        var stack: [Frame] = []
        var result: SpaceNode?
        var hardLinks = Set<FileIdentity>()

        private mutating func countEntry() {
            if let parent = stack.indices.last {
                stack[parent].entries += 1
            }
        }

        mutating func visit(_ info: FTSENT) -> Instruction {
            let path = String(cString: info.fts_path)
            let depth = Int(info.fts_level)
            switch Int32(info.fts_info) {
            case FTS_D:
                return open(path, depth: depth, info: info)
            case FTS_DP, FTS_DNR, FTS_ERR:
                close(path, depth: depth, reportsAfterOpen: Int32(info.fts_info) == FTS_DP)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                file(path, depth: depth, info: info)
            default:
                if depth > 0 {
                    countEntry() // something unreadable still counts as an entry
                }
            }
            return .next
        }

        private mutating func open(_ path: String, depth: Int, info: FTSENT) -> Instruction {
            let url = URL(fileURLWithPath: path)
            if depth > 0, scanner.isSkipped(scanner.relative(url)) {
                if let parent = stack.indices.last {
                    stack[parent].add(scanner.node(url, bytes: 0, isDirectory: true, skipped: true), keep: true)
                }
                return .skip
            }
            let own = info.fts_statp.map { UInt64(max(0, $0.pointee.st_blocks)) * 512 } ?? 0
            let identity = info.fts_statp.map { FileIdentity(device: Int64($0.pointee.st_dev), inode: UInt64($0.pointee.st_ino)) }
            stack.append(Frame(url: url, rawPath: path, depth: depth, identity: identity, bytes: own))
            return .next
        }

        /// Closes the folder: post-order visit, or the folder could not be read (it was opened at FTS_D).
        /// fts also reports skipped folders here; those were never opened and are ignored.
        private mutating func close(_ path: String, depth: Int, reportsAfterOpen: Bool) {
            guard stack.contains(where: { $0.rawPath == path }) else {
                if depth > 0, !reportsAfterOpen {
                    countEntry()
                }
                return
            }
            while let frame = stack.popLast() {
                let built = frame.build(scanner: scanner)
                if let parent = stack.indices.last {
                    stack[parent].add(built, keep: built.bytes >= scanner.minNodeBytes && frame.depth <= SpaceScanner.maxDepth)
                } else {
                    result = built
                }
                if frame.rawPath == path {
                    return
                }
            }
        }

        private mutating func file(_ path: String, depth: Int, info: FTSENT) {
            guard let stat = info.fts_statp?.pointee, let parent = stack.indices.last else { return }
            // A hard-linked file counts once.
            if Int32(info.fts_info) == FTS_F, stat.st_nlink > 1,
               !hardLinks.insert(FileIdentity(device: Int64(stat.st_dev), inode: UInt64(stat.st_ino))).inserted
            {
                stack[parent].entries += 1
                return
            }
            let bytes = UInt64(max(0, stat.st_blocks)) * 512
            if bytes >= scanner.minNodeBytes, depth <= SpaceScanner.maxDepth {
                let identity = FileIdentity(device: Int64(stat.st_dev), inode: UInt64(stat.st_ino))
                stack[parent].add(
                    scanner.node(URL(fileURLWithPath: path), bytes: bytes, isDirectory: false, identity: identity),
                    keep: true
                )
            } else {
                stack[parent].bytes += bytes
                stack[parent].entries += 1
            }
        }
    }

    /// A folder being measured: its running total and the entries worth showing.
    private struct Frame {
        let url: URL
        /// The path exactly as fts reports it (URL may normalise it), to pair pre- and post-order visits.
        let rawPath: String
        let depth: Int
        let identity: FileIdentity?
        var bytes: UInt64
        var entries = 0
        var kept: [SpaceNode] = []

        mutating func add(_ child: SpaceNode, keep: Bool) {
            bytes += child.bytes
            entries += 1
            if keep {
                kept.append(child)
                // Bound memory in huge folders: keep only the largest few hundred while walking.
                if kept.count > SpaceScanner.childLimit * 8 {
                    kept.sort { $0.bytes > $1.bytes }
                    kept.removeLast(kept.count - SpaceScanner.childLimit)
                }
            }
        }

        func build(scanner: SpaceScanner) -> SpaceNode {
            let sorted = kept.sorted { $0.bytes > $1.bytes }
            let shown = Array(sorted.prefix(SpaceScanner.childLimit))
            let shownBytes = shown.reduce(UInt64(0)) { $0 + $1.bytes }
            let relativePath = scanner.relative(url)
            return SpaceNode(
                name: url.lastPathComponent, path: url.path, bytes: bytes, isDirectory: true,
                children: depth >= SpaceScanner.maxDepth ? [] : shown,
                otherCount: max(0, entries - shown.count), otherBytes: bytes > shownBytes ? bytes - shownBytes : 0,
                isSkipped: false, canTrash: scanner.canTrash(url, relativePath: relativePath), identity: identity
            )
        }
    }

    fileprivate func node(_ url: URL, bytes: UInt64, isDirectory: Bool, skipped: Bool = false, identity: FileIdentity? = nil) -> SpaceNode {
        SpaceNode(
            name: url.lastPathComponent, path: url.path, bytes: bytes, isDirectory: isDirectory, children: [],
            otherCount: 0, otherBytes: 0, isSkipped: skipped, canTrash: !skipped && canTrash(url, relativePath: relative(url)),
            identity: identity
        )
    }

    fileprivate func relative(_ url: URL) -> String {
        url.path == home.path ? "" : String(url.path.dropFirst(home.path.count + 1))
    }

    fileprivate func isSkipped(_ relativePath: String) -> Bool {
        Self.cloudAreas.contains(relativePath) || (!includePrivateAreas && Self.privateAreas.contains(relativePath))
    }

    fileprivate func canTrash(_ url: URL, relativePath _: String) -> Bool {
        Self.canTrash(url, home: home, guide: guide)
    }

    /// Offered for the Trash: inside home, not protected, not home's Library or its top level, and not in a
    /// folder the guide says to keep. The cleaner checks this again for items picked in Space Lens.
    public static func canTrash(_ url: URL, home: URL, guide: FolderGuide = .bundled) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/"), !ProtectedPaths(home: home).denies(url) else { return false }
        let relativePath = String(path.dropFirst(home.path.count + 1))
        let components = relativePath.split(separator: "/")
        if components.first == "Library", components.count <= 2 {
            return false
        }
        return !guide.isKept(relativePath: relativePath)
    }
}

/// What well-known folders are and whether removing them is safe, shown in Space Lens (and given to
/// the AI in 0.6). Bundled data, matched against home-relative paths.
public struct FolderGuide: Sendable {
    public enum Advice: String, Codable, Sendable {
        /// Rebuilt automatically; removing it only costs time.
        case safe
        /// Removing it loses something; decide case by case.
        case review
        /// Needed by macOS or apps; Space Lens does not offer it for the Trash.
        case keep
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// Home-relative path; `*` matches one component.
        public let pattern: String
        public let title: String
        public let detail: String
        public let advice: Advice
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static let bundled: FolderGuide = {
        guard let url = Bundle.module.url(forResource: "folders", withExtension: "json", subdirectory: "Rules"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return FolderGuide(entries: []) }
        return FolderGuide(entries: entries)
    }()

    /// Whether the folder, or the nearest described folder above it, is one to keep. A more specific
    /// entry wins: `.claude` is kept, `.claude/projects` (old sessions) is not.
    public func isKept(relativePath: String) -> Bool {
        var components = relativePath.split(separator: "/").map(String.init)
        while !components.isEmpty {
            if let entry = describe(relativePath: components.joined(separator: "/")) {
                return entry.advice == .keep
            }
            components.removeLast()
        }
        return false
    }

    public func describe(relativePath: String) -> Entry? {
        let components = relativePath.split(separator: "/").map(String.init)
        return entries.first { entry in
            let pattern = entry.pattern.split(separator: "/").map(String.init)
            return pattern.count == components.count && zip(pattern, components).allSatisfy { fnmatch($0, $1, 0) == 0 }
        }
    }
}
