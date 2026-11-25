import Foundation
import SQLite3
import Testing
@testable import OsinCore

struct HistoryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ secondsAgo: TimeInterval, cpu: Double = 0.1, pressure: MemoryPressure = .normal, score: Int = 90) -> HistoryPoint {
        HistoryPoint(
            date: now.addingTimeInterval(-secondsAgo),
            cpu: cpu,
            memoryUsed: 0.5,
            pressure: pressure,
            diskFree: 0.3,
            networkReceive: 100,
            networkSend: 50,
            batteryCharge: 0.8,
            score: score
        )
    }

    @Test func returnsRecordedPointsInOrder() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(point(20, cpu: 0.2))
        try await store.record(point(10, cpu: 0.4))
        let points = try await store.points(since: now.addingTimeInterval(-60), bucket: 1)
        #expect(points.map(\.cpu) == [0.2, 0.4])
    }

    @Test func bucketsAverageValuesAndKeepWorstPressureAndScore() async throws {
        let store = try HistoryStore.inMemory()
        // Same 60 s bucket: 1_799_999_940 ... 1_799_999_999.
        try await store.record(point(50, cpu: 0.2, pressure: .normal, score: 90))
        try await store.record(point(40, cpu: 0.6, pressure: .warning, score: 70))
        let points = try await store.points(since: now.addingTimeInterval(-3600), bucket: 60)
        #expect(points.count == 1)
        #expect(abs((points.first?.cpu ?? 0) - 0.4) < 1e-9)
        #expect(points.first?.pressure == .warning)
        #expect(points.first?.score == 70)
    }

    @Test func excludesPointsBeforeSince() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(point(7200))
        try await store.record(point(10))
        let points = try await store.points(since: now.addingTimeInterval(-3600), bucket: 1)
        #expect(points.count == 1)
    }

    @Test func compactionMergesOldRawSamplesIntoMinutes() async throws {
        let store = try HistoryStore.inMemory()
        // Two raw samples two hours ago, inside the same minute.
        let base = 7200.0 + Double(Int(now.timeIntervalSince1970) % 60)
        try await store.record(point(base, cpu: 0.2))
        try await store.record(point(base - 30, cpu: 0.4))
        try await store.record(point(10, cpu: 0.9))
        try await store.compact(now: now)
        #expect(try await store.rowCount() == 2)
        let points = try await store.points(since: now.addingTimeInterval(-86400), bucket: 1)
        #expect(points.map(\.cpu).count == 2)
        #expect(abs(points[0].cpu - 0.3) < 1e-9)
        #expect(points[1].cpu == 0.9)
    }

    @Test func compactionMergesDayOldMinutesIntoQuarterHours() async throws {
        let store = try HistoryStore.inMemory()
        let aligned = Double(Int(now.timeIntervalSince1970) % 900)
        let start = 2 * 86400 + aligned // two days ago, at a 15-minute boundary
        for minute in 0 ..< 15 {
            try await store.record(point(start - Double(minute * 60), cpu: Double(minute) / 100))
        }
        try await store.compact(now: now)
        #expect(try await store.rowCount() == 1)
        let points = try await store.points(since: now.addingTimeInterval(-3 * 86400), bucket: 1)
        #expect(abs((points.first?.cpu ?? 0) - 0.07) < 1e-9) // mean of 0.00 ... 0.14
    }

    @Test func compactionDropsDataOlderThanRetention() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(point(8 * 86400))
        try await store.record(point(10))
        try await store.compact(now: now)
        #expect(try await store.rowCount() == 1)
    }

    @Test func persistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osin-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try HistoryStore(url: url)
            try await store.record(point(10))
        }
        let reopened = try HistoryStore(url: url)
        #expect(try await reopened.rowCount() == 1)
    }
}

struct HistoryDiskIOTests {
    @Test func diskThroughputRoundTrips() async throws {
        let store = try HistoryStore.inMemory()
        let now = Date()
        try await store.record(HistoryPoint(
            date: now, cpu: 0.1, memoryUsed: 0.5, pressure: .normal, diskFree: 0.3,
            networkReceive: 1, networkSend: 2, batteryCharge: nil, score: 90, diskRead: 300, diskWrite: 400
        ))
        let point = try await store.points(since: now.addingTimeInterval(-60), bucket: 1).first
        #expect(point?.diskRead == 300)
        #expect(point?.diskWrite == 400)
    }

    @Test func olderDatabasesGainTheNewColumns() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osin-old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE samples (ts INTEGER NOT NULL, res INTEGER NOT NULL, cpu REAL NOT NULL, mem REAL NOT NULL,
          pressure INTEGER NOT NULL, disk REAL NOT NULL, rx REAL NOT NULL, tx REAL NOT NULL, battery REAL, score INTEGER NOT NULL);
        INSERT INTO samples VALUES (\(Int(Date().timeIntervalSince1970)), 0, 0.2, 0.5, 0, 0.3, 1, 2, NULL, 80);
        """, nil, nil, nil)
        sqlite3_close(db)
        let store = try HistoryStore(url: url)
        let points = try await store.points(since: Date().addingTimeInterval(-3600), bucket: 1)
        #expect(points.count == 1)
        #expect(points.first?.diskRead == 0)
    }
}
