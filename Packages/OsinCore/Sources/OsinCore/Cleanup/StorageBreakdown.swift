import Foundation

/// Disk usage by category for the Overview. Only measures folders that never trigger a macOS
/// permission prompt; Documents, Desktop and Downloads end up in `other`.
public struct StorageBreakdown: Sendable, Equatable, Codable {
    public let apps: UInt64
    public let developer: UInt64
    public let caches: UInt64
    /// Safe-to-clean bytes from the last scan. Overlaps the categories above; shown as a highlight.
    public let reclaimable: UInt64
    public let other: UInt64
    public let free: UInt64
    public let total: UInt64
    public let measuredAt: Date

    public init(
        apps: UInt64, developer: UInt64, caches: UInt64, reclaimable: UInt64,
        other: UInt64, free: UInt64, total: UInt64, measuredAt: Date
    ) {
        self.apps = apps
        self.developer = developer
        self.caches = caches
        self.reclaimable = reclaimable
        self.other = other
        self.free = free
        self.total = total
        self.measuredAt = measuredAt
    }

    public static func measure(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: URL = URL(fileURLWithPath: "/Applications"),
        totalBytes: UInt64,
        availableBytes: UInt64,
        reclaimableBytes: UInt64
    ) async throws -> StorageBreakdown {
        let task = Task.detached(priority: .utility) { () throws -> (UInt64, UInt64, UInt64) in
            let apps = try DiskUsage.allocatedSize(of: applications)
            let developer = try DiskUsage.allocatedSize(of: home.appendingPathComponent("Library/Developer"))
            let caches = try DiskUsage.allocatedSize(of: home.appendingPathComponent("Library/Caches"))
            return (apps, developer, caches)
        }
        let (apps, developer, caches) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        let used = totalBytes > availableBytes ? totalBytes - availableBytes : 0
        let measured = apps + developer + caches
        return StorageBreakdown(
            apps: apps,
            developer: developer,
            caches: caches,
            reclaimable: reclaimableBytes,
            other: used > measured ? used - measured : 0,
            free: availableBytes,
            total: totalBytes,
            measuredAt: Date()
        )
    }
}
