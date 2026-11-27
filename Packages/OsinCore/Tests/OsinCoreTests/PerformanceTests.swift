import Foundation
import Testing
@testable import OsinCore

/// Performance follow-ups (v0.2.2): bounded work that used to grow with the data.
struct ClaimedPathsTests {
    @Test func overlapMeansSameAncestorOrDescendant() {
        var claimed = ClaimedPaths()
        claimed.insert("/h/Library/Caches/app")
        #expect(claimed.overlaps("/h/Library/Caches/app"))
        #expect(claimed.overlaps("/h/Library/Caches/app/sub/file"))
        #expect(claimed.overlaps("/h/Library/Caches"))
        #expect(claimed.overlaps("/h/Library"))
        #expect(!claimed.overlaps("/h/Library/Caches/app2"))
        #expect(!claimed.overlaps("/h/Library/Caches/ap"))
        #expect(!claimed.overlaps("/h/Library/Logs"))
    }

    @Test func manySiblingsStayFast() {
        var claimed = ClaimedPaths()
        let clock = ContinuousClock()
        let start = clock.now
        var overlapping = 0
        for index in 0 ..< 20000 {
            let path = "/h/Library/pnpm/store/v10/files/\(index)"
            if claimed.overlaps(path) {
                overlapping += 1
            }
            claimed.insert(path)
        }
        let elapsed = clock.now - start
        #expect(overlapping == 0)
        // The old linear scan needed about 200 million comparisons here (tens of seconds); the bound
        // is loose enough for slow CI runners and debug builds.
        #expect(elapsed < .seconds(5))
    }
}

struct CleanupLogRotationTests {
    private func entry(_ index: Int) -> CleanupLog.Entry {
        CleanupLog.Entry(ruleID: "r", action: "delete", path: "/h/item-\(index)", bytes: 1)
    }

    @Test func rotatesIntoOneArchiveAndKeepsReadingBoth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = CleanupLog(url: folder.appendingPathComponent("cleanup-log.jsonl"), maxBytes: 2000)
        for index in 0 ..< 60 {
            try log.append(entry(index))
        }
        let archive = folder.appendingPathComponent("cleanup-log.1.jsonl")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        let size = try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int ?? 0
        #expect(size <= 2000)
        let entries = try log.entries()
        // Oldest first, newest last, nothing duplicated; the oldest beyond the archive are dropped.
        #expect(entries.last?.path == "/h/item-59")
        let indices = entries.compactMap { Int($0.path.split(separator: "-").last ?? "") }
        #expect(indices == indices.sorted())
        #expect(Set(indices).count == indices.count)
        #expect(entries.count < 60)
    }

    @Test func lifetimeFreedSurvivesRotation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = CleanupLog(url: folder.appendingPathComponent("cleanup-log.jsonl"), maxBytes: 1500)
        for index in 0 ..< 80 {
            try log.append(CleanupLog.Entry(
                ruleID: "r",
                action: index.isMultiple(of: 2) ? "delete" : "trash",
                path: "/h/\(index)",
                bytes: 10
            ))
        }
        // 40 deletions of 10 bytes, even though most entries were rotated away.
        #expect(try log.freedBytesTotal() == 400)
        #expect(try log.entries().count < 80)
    }

    @Test func recentEntriesAreNewestFirstAndLimited() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = CleanupLog(url: folder.appendingPathComponent("cleanup-log.jsonl"))
        for index in 0 ..< 10 {
            try log.append(entry(index))
        }
        #expect(try log.recentEntries(limit: 3).map(\.path) == ["/h/item-9", "/h/item-8", "/h/item-7"])
    }
}

@Suite(.serialized) struct ProcessCatalogTests {
    @Test func refreshesFindNewProcessesAndKeepTheirDetails() async throws {
        let catalog = RunningProcessCatalog()
        let first = await catalog.refresh()
        #expect(!first.isEmpty)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["33"]
        try child.run()
        defer { child.terminate() }
        let second = await catalog.refresh()
        let entry = try #require(second.first { $0.pid == child.processIdentifier })
        #expect(entry.commandLine.contains("sleep 33"))
        let third = await catalog.refresh()
        #expect(third.first { $0.pid == child.processIdentifier }?.commandLine == entry.commandLine)
    }

    @Test func argumentsAreReadAgainWhenTheExecutableChanges() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["34"]
        try child.run()
        defer { child.terminate() }
        let real = try #require(RunningProcesses.list().first { $0.pid == child.processIdentifier })
        // A stale entry from before an `exec`: same PID and start time, different executable.
        var cache: [Int32: RunningProcesses.CachedArguments] = [
            child.processIdentifier: .init(startTime: real.startTime, executablePath: "/bin/zsh", arguments: ["-zsh"])
        ]
        let listed = RunningProcesses.list(cache: &cache).first { $0.pid == child.processIdentifier }
        #expect(listed?.commandLine.contains("sleep 34") == true)
    }
}

struct AlertCooldownRestoreTests {
    @Test func undeliveredAlertsDoNotStartACooldown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = AlertReading(diskFreeFraction: 0.5, freeBytes: 1, memoryPressure: .normal, batteryHealth: 0.7)
        var evaluator = AlertEvaluator(settings: AlertSettings())
        let before = evaluator.lastAlerts
        let alerts = evaluator.evaluate(reading, at: now)
        #expect(alerts.map(\.kind) == [.batteryHealth])
        // Notifications turned out to be off: the alert never showed, so it can fire again later.
        evaluator.restoreCooldowns(for: alerts.map(\.kind), firedAt: now, previous: before)
        #expect(evaluator.evaluate(reading, at: now.addingTimeInterval(60)).map(\.kind) == [.batteryHealth])
    }

    @Test func restoringNeverUndoesANewerAlert() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = AlertReading(diskFreeFraction: 0.5, freeBytes: 1, memoryPressure: .normal, batteryHealth: 0.7)
        var evaluator = AlertEvaluator(settings: AlertSettings())
        let before = evaluator.lastAlerts
        _ = evaluator.evaluate(reading, at: now)
        // A restore for an older firing time leaves the cooldown alone.
        evaluator.restoreCooldowns(for: [.batteryHealth], firedAt: now.addingTimeInterval(-10), previous: before)
        #expect(evaluator.lastAlerts[.batteryHealth] == now)
    }
}

struct CleanupLogTotalsIdempotenceTests {
    @Test func anArchiveIsCountedOnlyOnceEvenIfRotationIsInterrupted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osin-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = CleanupLog(url: folder.appendingPathComponent("cleanup-log.jsonl"), maxBytes: 1500)
        for index in 0 ..< 80 {
            try log.append(CleanupLog.Entry(ruleID: "r", action: "delete", path: "/h/\(index)", bytes: 10))
        }
        let total = try log.freedBytesTotal()
        #expect(total == 800)
        // Simulate a crash right after the totals were saved: count the current archive again.
        try log.countArchiveIntoDroppedTotals()
        try log.countArchiveIntoDroppedTotals()
        #expect(try log.freedBytesTotal() == total + 0)
    }
}
