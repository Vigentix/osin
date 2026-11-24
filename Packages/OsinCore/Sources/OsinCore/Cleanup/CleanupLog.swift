import Foundation

/// Append-only record of every cleanup action (PRD §6.5), stored as JSON Lines.
public struct CleanupLog: Sendable {
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public var id: String {
            "\(date.timeIntervalSince1970)-\(path)-\(action)"
        }

        public let date: Date
        public let ruleID: String
        /// `delete`, `trash`, `restore` or `builtin:<kind>`.
        public let action: String
        public let path: String
        public let bytes: UInt64
        public let trashPath: String?

        public init(date: Date = Date(), ruleID: String, action: String, path: String, bytes: UInt64, trashPath: String? = nil) {
            self.date = date
            self.ruleID = ruleID
            self.action = action
            self.path = path
            self.bytes = bytes
            self.trashPath = trashPath
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Osin/cleanup-log.jsonl`.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Osin", isDirectory: true).appendingPathComponent("cleanup-log.jsonl")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public func append(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder().encode(entry)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All entries, oldest first. Malformed lines are skipped.
    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
