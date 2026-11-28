import Foundation

/// Sizes measured by recent scans, so the quiet launch scan does not walk hundreds of thousands of cache
/// files again every time Osin starts. An entry is used only for the same item (identity) and while it
/// is young; a user-started scan always measures afresh. Cleaning never trusts it: the cleaner checks
/// ages with a fresh measurement.
public final class SizeCache: @unchecked Sendable {
    struct Entry: Codable {
        let identity: FileIdentity
        let bytes: UInt64
        let newest: Date?
        let measuredAt: Date
        /// Last looked up or stored; entries unused for a week are dropped.
        var lastUsed: Date
    }

    public let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Entries are dropped after this long without being used.
    static let keep: TimeInterval = 7 * 86400

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    public static func defaultURL() -> URL? {
        (try? CleanupLog.defaultURL())?.deletingLastPathComponent().appendingPathComponent("size-cache.json")
    }

    func lookup(_ path: String, identity: FileIdentity, maxAge: TimeInterval, now: Date = Date()) -> DiskUsage.Usage? {
        lock.lock()
        defer { lock.unlock() }
        guard maxAge > 0, let entry = entries[path], entry.identity == identity, now.timeIntervalSince(entry.measuredAt) <= maxAge else {
            return nil
        }
        entries[path]?.lastUsed = now
        return DiskUsage.Usage(bytes: entry.bytes, newestModification: entry.newest, isComplete: true)
    }

    /// Only complete measurements are kept (a partial one must be measured again).
    func store(_ path: String, identity: FileIdentity, usage: DiskUsage.Usage, now: Date = Date()) {
        guard usage.isComplete else { return }
        lock.lock()
        entries[path] = Entry(identity: identity, bytes: usage.bytes, newest: usage.newestModification, measuredAt: now, lastUsed: now)
        lock.unlock()
    }

    public func save(now: Date = Date()) {
        guard let url else { return }
        lock.lock()
        entries = entries.filter { now.timeIntervalSince($0.value.lastUsed) < Self.keep }
        let data = try? JSONEncoder().encode(entries)
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: url, options: .atomic)
    }
}
