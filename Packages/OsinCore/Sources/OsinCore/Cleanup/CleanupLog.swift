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
        /// The trashed item, so a restore from History can verify it is the same item.
        public let identity: FileIdentity?

        public init(
            date: Date = Date(),
            ruleID: String,
            action: String,
            path: String,
            bytes: UInt64,
            trashPath: String? = nil,
            identity: FileIdentity? = nil
        ) {
            self.date = date
            self.ruleID = ruleID
            self.action = action
            self.path = path
            self.bytes = bytes
            self.trashPath = trashPath
            self.identity = identity
        }
    }

    public let url: URL
    /// When the log would grow past this, it moves to `cleanup-log.1.jsonl` (replacing the previous
    /// archive) and a new log starts. Keeps reading History cheap however long Osin is used.
    public let maxBytes: Int

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    var archiveURL: URL {
        url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
    }

    /// Bytes freed by entries that rotation has already dropped, so the lifetime total never shrinks.
    var droppedTotalsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("cleanup-totals.json")
    }

    private struct DroppedTotals: Codable {
        var freedBytes: UInt64
        /// The first line of the archive already added to `freedBytes`, so an interrupted rotation
        /// (totals saved, archive not yet deleted) never counts it twice.
        var countedArchive: String?
    }

    private func droppedTotals() -> DroppedTotals {
        (try? JSONDecoder().decode(DroppedTotals.self, from: Data(contentsOf: droppedTotalsURL))) ?? DroppedTotals(freedBytes: 0)
    }

    private func lines(of file: URL) -> [Substring] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
    }

    private func decode(_ lines: [Substring]) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// Adds the current archive's freed bytes to the dropped totals, once per archive.
    func countArchiveIntoDroppedTotals() throws {
        let archived = lines(of: archiveURL)
        guard let identity = archived.first.map(String.init) else { return }
        var totals = droppedTotals()
        guard totals.countedArchive != identity else { return }
        totals.freedBytes += Self.freed(decode(archived))
        totals.countedArchive = identity
        try JSONEncoder().encode(totals).write(to: droppedTotalsURL, options: .atomic)
    }

    static func freed(_ entries: [Entry]) -> UInt64 {
        entries.filter { $0.action == "delete" || $0.action.hasPrefix("builtin:") }.reduce(0) { $0 + $1.bytes }
    }

    /// Everything Osin ever freed (deleted or emptied), including entries no longer kept.
    private func unlockedFreedBytesTotal() throws -> UInt64 {
        let totals = droppedTotals()
        let archived = lines(of: archiveURL)
        let archiveAlreadyCounted = archived.first.map(String.init) == totals.countedArchive
        let archiveFreed = archiveAlreadyCounted ? 0 : Self.freed(decode(archived))
        return totals.freedBytes + archiveFreed + Self.freed(decode(lines(of: url)))
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

    /// Whether entries can be written. Cleaning refuses to start otherwise: every action must be logged.
    public func isWritable() -> Bool {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            return manager.isWritableFile(atPath: url.path)
        }
        return manager.isWritableFile(atPath: folder.path)
    }

    private func unlockedAppend(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder().encode(entry)
        line.append(0x0A)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0, size + line.count > maxBytes {
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                // The old archive is about to go: keep what it freed in the running total first.
                try countArchiveIntoDroppedTotals()
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: url, to: archiveURL)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All kept entries (archive, then current log), oldest first. Malformed lines are skipped.
    private func unlockedEntries() throws -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try [archiveURL, url]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { file in
                try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n")
                    .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
            }
    }

    /// Appends, reads and totals take one lock, so History never reads half a rotation.
    private nonisolated(unsafe) static let lock = NSLock()

    public func append(_ entry: Entry) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try unlockedAppend(entry)
    }

    /// All kept entries (archive, then current log), oldest first. Malformed lines are skipped.
    public func entries() throws -> [Entry] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try unlockedEntries()
    }

    /// Everything Osin ever freed (deleted or emptied), including entries no longer kept.
    public func freedBytesTotal() throws -> UInt64 {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try unlockedFreedBytesTotal()
    }

    /// The newest `limit` entries, newest first (what History shows).
    public func recentEntries(limit: Int) throws -> [Entry] {
        try Array(entries().suffix(limit).reversed())
    }
}
