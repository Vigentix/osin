import Foundation

/// What an AI (Claude Code or Codex, through Osin's MCP tools) suggests cleaning. Only suggestions:
/// the user reviews them in Osin, and anything chosen goes to the Trash through the usual checks.
public struct CleanupProposal: Codable, Sendable, Identifiable, Equatable {
    public struct Item: Codable, Sendable, Identifiable, Equatable {
        public var id: String {
            path
        }

        public let path: String
        public let bytes: UInt64
        public let reason: String
        public let category: String?
        /// Osin's own note for known folders (safe / review / keep).
        public let advice: String?
        /// What the path was when proposed; the Trash step refuses anything else.
        public let identity: FileIdentity?

        public init(path: String, bytes: UInt64, reason: String, category: String?, advice: String?, identity: FileIdentity?) {
            self.path = path
            self.bytes = bytes
            self.reason = reason
            self.category = category
            self.advice = advice
            self.identity = identity
        }
    }

    public let id: String
    /// "claude", "codex" or "external" (the user's own session through "Add Osin to …").
    public let source: String
    public let createdAt: Date
    public var updatedAt: Date
    public var summary: String
    public var items: [Item]

    public init(id: String, source: String, createdAt: Date, updatedAt: Date, summary: String, items: [Item]) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.items = items
    }

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.bytes }
    }
}

/// Proposals as JSON files in `~/Library/Application Support/Osin/ai-proposals`.
public struct ProposalStore: Sendable {
    public let folder: URL
    /// Posted (distributed, so the app hears it from the MCP process) when a proposal is written.
    public static let changedNotification = Notification.Name("com.vigentix.osin.aiProposal")

    public init(folder: URL) {
        self.folder = folder
    }

    public static func defaultFolder() -> URL? {
        (try? CleanupLog.defaultURL())?.deletingLastPathComponent().appendingPathComponent("ai-proposals", isDirectory: true)
    }

    private func url(for id: String) -> URL {
        folder.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Proposals kept on disk; older ones are removed when a new one is saved.
    static let keptCount = 20

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// The folder and its parent must be real folders: a link could send proposals somewhere else.
    private func checkFolder() throws {
        if Self.isLink(folder) || Self.isLink(folder.deletingLastPathComponent()) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public func load(id: String) throws -> CleanupProposal? {
        try checkFolder()
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path), !Self.isLink(file) else { return nil }
        return try Self.coder().1.decode(CleanupProposal.self, from: Data(contentsOf: file))
    }

    public func save(_ proposal: CleanupProposal) throws {
        try checkFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.coder().0.encode(proposal).write(to: url(for: proposal.id), options: .atomic)
        for old in files().dropFirst(Self.keptCount) {
            try? FileManager.default.removeItem(at: old)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.changedNotification, object: proposal.id, userInfo: nil, deliverImmediately: true
        )
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Proposal files, most recently written first.
    private func files() -> [URL] {
        guard (try? checkFolder()) != nil else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The most recently written proposal (only that one is read).
    public func latest() -> CleanupProposal? {
        files().lazy.compactMap { try? Self.coder().1.decode(CleanupProposal.self, from: Data(contentsOf: $0)) }.first
    }

    /// Newest first.
    public func all() -> [CleanupProposal] {
        files().compactMap { try? Self.coder().1.decode(CleanupProposal.self, from: Data(contentsOf: $0)) }
    }
}

/// The Space Lens measurement saved between launches, shared by the app and the MCP tools.
public struct SpaceLensCache: Codable, Sendable {
    public let tree: SpaceNode
    public let scannedAt: Date

    public init(tree: SpaceNode, scannedAt: Date) {
        self.tree = tree
        self.scannedAt = scannedAt
    }

    public static func defaultURL() -> URL? {
        (try? CleanupLog.defaultURL())?.deletingLastPathComponent().appendingPathComponent("space-lens.json")
    }

    public static func load(from url: URL?) -> SpaceLensCache? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpaceLensCache.self, from: data)
    }

    public func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
