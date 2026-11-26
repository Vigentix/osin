import Foundation
import Testing
@testable import OsinCore

/// Regression tests for issues found in the second review of the v0.1.1 fixes.
struct SecondReviewTests {
    private func trashRule(minAgeDays: Int? = nil) -> CleanupRule {
        CleanupRule(
            id: "downloads.old", name: "old", detail: "", tier: .review, action: .trash, regenerable: false,
            paths: ["~/Downloads/*"], minAgeDays: minAgeDays
        )
    }

    private func cleaner(_ fixture: FixtureHome) -> Cleaner {
        Cleaner(
            home: fixture.home,
            trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
    }

    // MARK: Identity is required

    @Test func itemsWithoutAScanIdentityAreRefused() async throws {
        let fixture = try FixtureHome()
        let file = try fixture.file("Downloads/old.zip")
        let item = ScanItem(url: file.resolvingSymlinksInPath(), bytes: 10000, modified: nil)
        let outcome = await cleaner(fixture).clean([CleanupSelection(rule: trashRule(), items: [item])])
        #expect(outcome.failures.map(\.kind) == [.changedSinceScan])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func scannedItemsCarryTheirIdentity() async throws {
        let fixture = try FixtureHome()
        let file = try fixture.file("Downloads/old.zip", age: 400)
        let results = try await Scanner(home: fixture.home).scan([trashRule(minAgeDays: 30)])
        let item = try #require(results.first?.items.first)
        #expect(item.identity == FileIdentity(path: file.resolvingSymlinksInPath().path))
    }

    // MARK: Age needs a complete look inside

    @Test func folderWithAnUnreadablePartIsNotCalledOld() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Downloads/project/readme.txt", age: 400)
        let hidden = try fixture.file("Downloads/project/private/today.txt").deletingLastPathComponent()
        try fixture.age(hidden, days: 400)
        try fixture.age(fixture.home.appendingPathComponent("Downloads/project"), days: 400)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }

        let results = try await Scanner(home: fixture.home).scan([trashRule(minAgeDays: 30)])
        #expect(results.first?.items.isEmpty == true)
    }

    @Test func measureReportsWhetherItSawEverything() throws {
        let fixture = try FixtureHome()
        let open = try fixture.directory("open")
        try fixture.file("open/a.txt")
        let locked = try fixture.directory("open/locked")
        try fixture.file("open/locked/b.txt")
        #expect(try DiskUsage.measure(open).isComplete)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(try !DiskUsage.measure(open).isComplete)
    }

    @Test func ageCheckIgnoresResourceValuesCachedAtScanTime() throws {
        let fixture = try FixtureHome()
        let file = try fixture.file("Downloads/notes.txt", age: 400)
        // URLs from a directory listing carry prefetched (cached) modification dates.
        let listed = try #require(try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).first)
        try Data("edited today".utf8).write(to: file)
        let newest = try #require(try DiskUsage.measure(listed).newestModification)
        #expect(newest > Date().addingTimeInterval(-3600))
    }

    // MARK: Fresh samples on request

    @Test func invalidatingTheSamplerForcesAFreshSample() async {
        let sampler = SystemSampler(minimumInterval: .seconds(60))
        let first = await sampler.sample()
        await sampler.invalidate()
        let second = await sampler.sample()
        #expect(second.date > first.date)
    }

    // MARK: Battery weight in history

    private func point(_ date: Date, battery: Double?) -> HistoryPoint {
        HistoryPoint(
            date: date, cpu: 0, memoryUsed: 0.5, pressure: .normal, diskFree: 0.3,
            networkReceive: 0, networkSend: 0, batteryCharge: battery, score: 90
        )
    }

    @Test func compactionWeighsBatteryOnlyByTimeWithAReading() async throws {
        let store = try HistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minute = Date(timeIntervalSince1970: (now.addingTimeInterval(-2 * 3600).timeIntervalSince1970 / 60).rounded(.down) * 60)
        try await store.record(point(minute, battery: nil), seconds: 30)
        try await store.record(point(minute.addingTimeInterval(30), battery: 0.8), seconds: 2)
        try await store.compact(now: now)
        try await store.record(point(minute.addingTimeInterval(45), battery: 0.4), seconds: 32)
        let points = try await store.points(since: minute.addingTimeInterval(-60), bucket: 60)
        let battery = try #require(points.first?.batteryCharge)
        #expect(abs(battery - (0.8 * 2 + 0.4 * 32) / 34) < 1e-9)
    }
}
