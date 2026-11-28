import Foundation

/// A tool call the AI got wrong (bad path, protected place…); returned to it as an error result.
public struct AIToolError: Error {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The tools Osin offers an AI over MCP. They only read sizes and Osin's own knowledge, and record
/// proposals; none reads file contents, runs commands or removes anything.
public final class AITools: @unchecked Sendable {
    public let home: URL
    private let proposals: ProposalStore
    /// The proposal this session writes to: the app's run, or one per session of the user's own CLI.
    private let proposalID: String
    private let source: String
    private let projectRoots: [URL]
    private let includePrivateAreas: Bool
    private let spaceCacheURL: URL?
    private let lock = NSLock()
    /// The home measurement, from Space Lens's cache or measured once for this session.
    private var homeTree: SpaceNode?

    public static let maxItemsPerProposal = 300
    private let maxItems: Int

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        proposals: ProposalStore,
        runID: String? = nil,
        source: String = "external",
        projectRoots: [URL] = [],
        includePrivateAreas: Bool = false,
        spaceCacheURL: URL? = nil,
        maxItems: Int = AITools.maxItemsPerProposal
    ) {
        self.maxItems = maxItems
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        self.home = resolved
        self.proposals = proposals
        proposalID = runID ?? "external-" + UUID().uuidString.prefix(8).lowercased()
        self.source = source
        self.projectRoots = projectRoots
        self.includePrivateAreas = includePrivateAreas
        self.spaceCacheURL = spaceCacheURL
    }

    // MARK: Definitions

    public var definitions: [[String: Any]] {
        let path: [String: Any] = ["type": "string", "description": "A path in the home folder, like ~/Library/Caches or an absolute path."]
        return [
            tool(
                "get_overview",
                "Disk capacity and free space, and the largest folders in the home folder with what Osin knows about them. Start here.",
                [:]
            ),
            tool(
                "list_folder",
                "Sizes of the largest entries in a folder (no file contents). Each entry says whether Osin knows it, its advice "
                    +
                    "(safe = rebuilt automatically, review = the user decides, keep = never remove) and whether it may be moved to the Trash.",
                ["path": path], required: ["path"]
            ),
            tool(
                "describe_folder",
                "What Osin knows about one file or folder: its size, a plain description for well-known folders, its advice "
                    + "and whether it may be moved to the Trash.",
                ["path": path],
                required: ["path"]
            ),
            tool(
                "smart_scan",
                "Run Osin's own cleanup rules (caches, logs, developer and browser caches, cold projects, unused toolchains, old AI sessions…) "
                    + "and return each group with its size, tier (safe or review) and largest items. Takes up to a minute.",
                [:]
            ),
            tool("docker_usage", "Docker build cache, untagged images and unused volumes on this Mac's Docker, if it runs.", [:]),
            tool(
                "propose_cleanup",
                "Propose files or folders for the user to move to the Trash, each with a short reason. Nothing is removed: the user reviews "
                    + "the list in Osin. Paths Osin considers unsafe are rejected with the reason; call again to add more.",
                [
                    "summary": [
                        "type": "string",
                        "description": "One or two sentences for the user: what you found and why these are safe to remove."
                    ],
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": path,
                                "reason": ["type": "string", "description": "Why removing it is safe, in plain words."],
                                "category": [
                                    "type": "string",
                                    "description": "A short group name, e.g. Caches, Old projects, Docker, Downloads."
                                ]
                            ],
                            "required": ["path", "reason"]
                        ]
                    ]
                ],
                required: ["summary", "items"]
            )
        ]
    }

    private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["readOnlyHint": name != "propose_cleanup", "destructiveHint": false, "openWorldHint": false]
        ]
    }

    // MARK: Calls

    public func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_overview": try overview()
        case "list_folder": try listFolder(arguments["path"] as? String)
        case "describe_folder": try describe(arguments["path"] as? String)
        case "smart_scan": smartScan()
        case "docker_usage": docker()
        case "propose_cleanup": try propose(summary: arguments["summary"] as? String, items: arguments["items"] as? [[String: Any]])
        default: throw AIToolError("Unknown tool \(name).")
        }
    }

    /// `~/…` or an absolute path, standardized and inside home (no other checks).
    private func lexicalPath(_ raw: String) throws -> URL {
        let expanded = raw == "~" ? home.path : (raw.hasPrefix("~/") ? home.path + raw.dropFirst(1) : raw)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.path == home.path || url.path.hasPrefix(home.path + "/") else {
            throw AIToolError("Only the home folder (\(home.path)) can be looked at.")
        }
        return url
    }

    /// Protected places (keys, mail…), privacy-guarded areas (Documents, Downloads…) and cloud folders:
    /// the AI never looks inside them. Checked on the path as written, ignoring case, before touching the disk.
    func isOffLimits(_ url: URL) -> Bool {
        let relative = relativePath(url.path).lowercased()
        guard !relative.isEmpty else { return false }
        let areas = ProtectedPaths.homeRelative + SpaceScanner.cloudAreas + (includePrivateAreas ? [] : SpaceScanner.privateAreas)
        return areas.contains { area in
            let area = area.lowercased()
            return relative == area || relative.hasPrefix(area + "/")
        }
    }

    /// Whether `url` contains an off-limits place (home, `~/Library`…): measured without entering it.
    private func containsOffLimits(_ url: URL) -> Bool {
        let relative = relativePath(url.path).lowercased()
        let areas = ProtectedPaths.homeRelative + SpaceScanner.cloudAreas + SpaceScanner.privateAreas
        return relative.isEmpty || areas.contains { $0.lowercased().hasPrefix(relative + "/") }
    }

    /// A path in home, without links on the way, not in a protected or privacy-guarded place.
    func resolve(_ raw: String?) throws -> URL {
        guard let raw, !raw.isEmpty else { throw AIToolError("A path is required.") }
        let url = try lexicalPath(raw)
        if isOffLimits(url) {
            throw AIToolError("\(raw) is a protected or private place (documents, photos, mail, keys…). Osin does not look inside it.")
        }
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
            throw AIToolError("The path goes through a symbolic link; it is not followed.")
        }
        // Names must match the disk exactly: on a case-insensitive disk `~/documents` would otherwise
        // slip past checks written for `~/Documents`.
        guard Self.matchesDiskSpelling(url, below: home),
              FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(raw) does not exist.") }
        return url
    }

    /// Whether every component below `home` is spelled as on disk (same case; Unicode forms compare equal).
    static func matchesDiskSpelling(_ url: URL, below home: URL) -> Bool {
        guard url.path != home.path else { return true }
        var parent = home
        for name in url.path.dropFirst(home.path.count + 1).split(separator: "/").map(String.init) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path), names.contains(name) else {
                return false
            }
            parent.appendPathComponent(name)
        }
        return true
    }

    private func relativePath(_ path: String) -> String {
        path == home.path ? "" : String(path.dropFirst(home.path.count + 1))
    }

    private func entry(_ node: SpaceNode) -> [String: Any] {
        let guide = FolderGuide.bundled.describe(relativePath: relativePath(node.path))
        var value: [String: Any] = [
            "name": node.name, "path": "~/" + relativePath(node.path), "bytes": node.bytes, "size": Self.size(node.bytes),
            "is_folder": node.isDirectory, "can_move_to_trash": node.canTrash
        ]
        if node.isSkipped {
            value["note"] = "Not measured: macOS protects it."
        }
        if let guide {
            value["known_as"] = guide.title
            value["description"] = guide.detail
            value["advice"] = guide.advice.rawValue
        }
        return value
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Home measurement

    /// Space Lens's measurement if it is less than a day old (without off-limits places, which the app
    /// may have measured with Full Disk Access), otherwise measured now (about a minute). Kept in memory
    /// only: the MCP server writes nothing but proposals.
    private func tree() -> SpaceNode {
        lock.lock()
        defer { lock.unlock() }
        if let homeTree {
            return homeTree
        }
        if let cache = SpaceLensCache.load(from: spaceCacheURL), Date().timeIntervalSince(cache.scannedAt) < 86400,
           cache.tree.path == home.path
        {
            let pruned = pruned(cache.tree)
            homeTree = pruned
            return pruned
        }
        let scanner = SpaceScanner(home: home, includePrivateAreas: includePrivateAreas)
        let measured = Self.blocking { try? await scanner.scan() } ?? SpaceNode(
            name: home.lastPathComponent,
            path: home.path,
            bytes: 0,
            isDirectory: true
        )
        homeTree = measured
        return measured
    }

    /// The tree without what lies inside off-limits places (their own size still counts).
    private func pruned(_ node: SpaceNode) -> SpaceNode {
        let hidden = isOffLimits(URL(fileURLWithPath: node.path))
        return SpaceNode(
            name: node.name, path: node.path, bytes: node.bytes, isDirectory: node.isDirectory,
            children: hidden ? [] : node.children.map(pruned), otherCount: hidden ? 0 : node.otherCount,
            otherBytes: hidden ? 0 : node.otherBytes, isSkipped: node.isSkipped || hidden, canTrash: node.canTrash,
            identity: node.identity
        )
    }

    private static func find(_ path: String, in node: SpaceNode) -> SpaceNode? {
        if node.path == path {
            return node
        }
        guard path.hasPrefix(node.path + "/") else { return nil }
        return node.children.lazy.compactMap { find(path, in: $0) }.first
    }

    private func overview() throws -> [String: Any] {
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let free = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let root = tree()
        return [
            "disk": ["total": Self.size(total), "free": Self.size(free), "free_bytes": free],
            "home": ["path": "~", "size": Self.size(root.bytes), "largest": root.children.prefix(25).map(entry)],
            "next": "Use list_folder to look deeper, smart_scan for Osin's own rules, then propose_cleanup."
        ]
    }

    private func listFolder(_ raw: String?) throws -> [String: Any] {
        let url = try resolve(raw)
        var node = Self.find(url.path, in: tree())
        // Deeper than the saved measurement keeps (small or deep folders): measure just this folder.
        if node == nil || (node?.isDirectory == true && node?.children.isEmpty == true && (node?.bytes ?? 0) > 0) {
            let scanner = SpaceScanner(home: home, includePrivateAreas: includePrivateAreas)
            node = Self.blocking { try? await scanner.scan(root: url) }
        }
        guard let node else { throw AIToolError("Could not measure \(raw ?? "").") }
        var result: [String: Any] = [
            "path": "~/" + relativePath(node.path),
            "size": Self.size(node.bytes),
            "entries": node.children.map(entry)
        ]
        if node.otherCount > 0 {
            result["smaller_entries"] = ["count": node.otherCount, "size": Self.size(node.otherBytes)]
        }
        return result
    }

    private func describe(_ raw: String?) throws -> [String: Any] {
        // A protected place is described (it must be kept) but not looked into.
        if let raw, let url = try? lexicalPath(raw), isOffLimits(url) {
            return [
                "path": raw,
                "can_move_to_trash": false,
                "advice": "keep",
                "note": "A protected place (documents, photos, mail, keys…). Osin never removes it or looks inside."
            ]
        }
        let url = try resolve(raw)
        if containsOffLimits(url) {
            // Home or `~/Library`: report the measurement that skips private places instead of walking them.
            var result = entry(Self.find(url.path, in: tree()) ?? SpaceNode(
                name: url.lastPathComponent, path: url.path, bytes: 0, isDirectory: true
            ))
            result["can_move_to_trash"] = false
            result["note"] = "Contains protected or private places; use list_folder to look inside."
            return result
        }
        let usage = try? DiskUsage.measure(url)
        let node = SpaceNode(
            name: url.lastPathComponent, path: url.path, bytes: usage?.bytes ?? 0,
            isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false,
            canTrash: SpaceScanner.canTrash(url, home: home)
        )
        var result = entry(node)
        if let newest = usage?.newestModification {
            result["last_modified"] = ISO8601DateFormatter().string(from: newest)
        }
        return result
    }

    // MARK: Smart Scan and Docker

    private func smartScan() -> [String: Any] {
        // Downloads is left out: reading it from here would show a macOS privacy prompt.
        let rules = ((try? CleanupRule.bundled()) ?? []).filter { rule in
            (try? rule.validate()) != nil && !rule.paths.contains { $0.hasPrefix("~/Downloads") }
        }
        let scanner = Scanner(home: home, projectRoots: projectRoots)
        let results = Self.blocking { try? await scanner.scan(rules) } ?? []
        let groups: [[String: Any]] = results.filter { $0.totalBytes > 0 }.map { result in
            var group: [String: Any] = [
                "id": result.rule.id, "name": result.rule.name, "detail": result.rule.detail, "tier": result.rule.tier.rawValue,
                "size": Self.size(result.totalBytes), "bytes": result.totalBytes, "items": result.items.count,
                "largest": result.items.sorted { $0.bytes > $1.bytes }.prefix(10).map { item in
                    ["path": "~/" + relativePath(item.url.path), "size": Self.size(item.bytes)]
                }
            ]
            if !result.blockingApps.isEmpty {
                group["waiting_for_apps_to_quit"] = result.blockingApps
            }
            return group
        }
        return [
            "groups": groups,
            "note": "Safe groups are rebuilt automatically; review groups need the user's judgment. Downloads is not scanned here."
        ]
    }

    private func docker() -> [String: Any] {
        guard let usage = Self.blocking({ await DockerInventory.measure() }) else {
            return ["available": false, "note": "Docker is not installed, not running, or not on this Mac."]
        }
        return [
            "available": true,
            "build_cache": Self.size(usage.buildCacheBytes),
            "untagged_images": usage.danglingImages.map { ["id": $0.id, "size": Self.size($0.bytes)] },
            "unused_volumes": usage.unusedVolumes.map { ["name": $0.name, "size": Self.size($0.bytes)] },
            "note": "Docker is cleaned from Osin's Smart Scan (it uses Docker's own commands), not through propose_cleanup."
        ]
    }

    // MARK: Proposals

    private func propose(summary: String?, items: [[String: Any]]?) throws -> [String: Any] {
        guard let items, !items.isEmpty else { throw AIToolError("items must list at least one path.") }
        guard items.count <= maxItems else { throw AIToolError("Propose at most \(maxItems) items.") }
        let id = proposalID
        var proposal = (try? proposals.load(id: id)) ?? CleanupProposal(
            id: id, source: source, createdAt: Date(), updatedAt: Date(), summary: "", items: []
        )
        var accepted: [[String: Any]] = []
        var rejected: [[String: Any]] = []
        for raw in items {
            let path = raw["path"] as? String ?? ""
            let reason = (raw["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let item = try validate(path, reason: reason, category: raw["category"] as? String, against: proposal.items)
                if let index = proposal.items.firstIndex(where: { $0.path == item.path }) {
                    proposal.items[index] = item
                } else if proposal.items.count >= maxItems {
                    throw AIToolError("The proposal already has \(maxItems) items; propose the largest ones only.")
                } else {
                    proposal.items.append(item)
                }
                accepted.append(["path": path, "size": Self.size(item.bytes)])
            } catch let error as AIToolError {
                rejected.append(["path": path, "reason": error.message])
            }
        }
        if let summary, !summary.isEmpty {
            proposal.summary = String(summary.prefix(2000))
        }
        proposal.updatedAt = Date()
        if !accepted.isEmpty {
            do {
                try proposals.save(proposal)
            } catch {
                throw AIToolError("Osin could not save the proposal (\(error.localizedDescription)). Nothing was proposed.")
            }
        }
        return [
            "accepted": accepted, "rejected": rejected,
            "total_proposed": Self.size(proposal.totalBytes),
            "note": "The user reviews these in Osin and decides; nothing has been removed."
        ]
    }

    private func validate(
        _ raw: String,
        reason: String,
        category: String?,
        against existing: [CleanupProposal.Item]
    ) throws -> CleanupProposal.Item {
        guard !reason.isEmpty else { throw AIToolError("Give a reason for every item.") }
        let url = try resolve(raw)
        guard url.path != home.path, SpaceScanner.canTrash(url, home: home) else {
            throw AIToolError("Osin keeps this: it is a system or settings folder, or one the user's data depends on.")
        }
        if let other = existing
            .first(where: { $0.path != url.path && (url.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(url.path + "/")) })
        {
            throw AIToolError("Overlaps with ~/\(relativePath(other.path)), already proposed.")
        }
        guard let identity = FileIdentity(path: url.path) else { throw AIToolError("\(raw) does not exist.") }
        let usage = try? DiskUsage.measure(url)
        let advice = FolderGuide.bundled.describe(relativePath: relativePath(url.path))?.advice.rawValue
        return CleanupProposal.Item(
            path: url.path, bytes: usage?.bytes ?? 0, reason: String(reason.prefix(500)),
            category: category.map { String($0.prefix(60)) }, advice: advice, identity: identity
        )
    }

    // MARK: Helpers

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// Runs async work from the synchronous MCP loop (never called on the main actor's executor).
    static func blocking<Value>(_ work: @escaping @Sendable () async -> Value?) -> Value? {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value
    }
}
