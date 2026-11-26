import Foundation
import Testing
@testable import OsinCore

/// Regression tests for issues found in the third review.
struct ThirdReviewTests {
    @Test func emptyTrashRefusesASymlinkedTrash() async throws {
        let fixture = try FixtureHome()
        let precious = try fixture.file("keep/thesis.docx", in: fixture.outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent(".Trash"),
            withDestinationURL: precious.deletingLastPathComponent()
        )
        let cleaner = Cleaner(home: fixture.home, log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl")))
        let result = await cleaner.emptyTrash()
        #expect(result.freedBytes == 0)
        #expect(result.failures.map(\.kind) == [.symbolicLink])
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func restoreRefusesADestinationReachedThroughASymlink() async throws {
        let fixture = try FixtureHome()
        let cleaner = Cleaner(
            home: fixture.home,
            trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let modules = try fixture.file("Projects/app/node_modules/lib.js").deletingLastPathComponent()
        let resolved = modules.resolvingSymlinksInPath()
        let rule = CleanupRule(
            id: "dev.node-modules", name: "n", detail: "", tier: .review, action: .trash, regenerable: false, paths: ["~/x/*"]
        )
        let item = ScanItem(url: resolved, bytes: 1, modified: nil, identity: FileIdentity(path: resolved.path))
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: [item])])
        #expect(outcome.trashed.count == 1)

        // Projects moves into Documents and a symlink takes its place.
        let projects = fixture.home.appendingPathComponent("Projects")
        let documents = try fixture.directory("Documents")
        try FileManager.default.moveItem(at: projects, to: documents.appendingPathComponent("Projects"))
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: documents.appendingPathComponent("Projects"))

        let failures = await cleaner.undo(outcome.trashed)
        #expect(failures.map(\.kind) == [.throughSymbolicLink])
        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent("Projects/app/node_modules").path))
    }

    @Test func restoreRefusesAProtectedDestination() async throws {
        let fixture = try FixtureHome()
        let cleaner = Cleaner(home: fixture.home, log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl")))
        let inTrash = try fixture.file("trash/report.pdf", in: fixture.root)
        let item = TrashedItem(
            originalURL: fixture.home.appendingPathComponent("Documents/report.pdf"),
            trashURL: inTrash, bytes: 1, ruleID: "x", identity: FileIdentity(path: inTrash.path)
        )
        let failures = await cleaner.undo([item])
        #expect(failures.map(\.kind) == [.protectedLocation])
        #expect(FileManager.default.fileExists(atPath: inTrash.path))
    }

    // MARK: Fourth review

    @Test func nothingIsRemovedWhenTheLogCannotBeWritten() async throws {
        let fixture = try FixtureHome()
        let logFolder = fixture.root.appendingPathComponent("readonly-log", isDirectory: true)
        try FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logFolder.path) }
        let cleaner = Cleaner(home: fixture.home, log: CleanupLog(url: logFolder.appendingPathComponent("log.jsonl")))

        let trashed = try fixture.file(".Trash/old.zip")
        let emptied = await cleaner.emptyTrash()
        #expect(emptied.failures.map(\.kind) == [.logUnavailable])
        #expect(FileManager.default.fileExists(atPath: trashed.path))

        let cache = try fixture.directory("Library/Caches/app")
        let rule = CleanupRule(id: "c", name: "c", detail: "", tier: .safe, action: .delete, regenerable: true, paths: ["~/x/*"])
        let resolved = cache.resolvingSymlinksInPath()
        let item = ScanItem(url: resolved, bytes: 1, modified: nil, identity: FileIdentity(path: resolved.path))
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: [item])])
        #expect(outcome.failures.map(\.kind) == [.logUnavailable])
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func trashSizeCountsHardLinksSharedBetweenTrashedItems() async throws {
        let fixture = try FixtureHome()
        let first = try fixture.file(".Trash/a.bin", bytes: 50000)
        try FileManager.default.linkItem(at: first, to: fixture.home.appendingPathComponent(".Trash/b.bin"))
        let measured = try await EmptyTrash.measure(home: fixture.home)
        #expect(measured >= 50000)
    }

    @Test func unreadableFolderMarksTheRuleAsNeedingAccess() async throws {
        let fixture = try FixtureHome()
        let hidden = try fixture.file("Downloads/project/private/notes.txt", age: 400).deletingLastPathComponent()
        try fixture.age(hidden, days: 400)
        try fixture.age(fixture.home.appendingPathComponent("Downloads/project"), days: 400)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }
        let rule = CleanupRule(
            id: "downloads.old", name: "old", detail: "", tier: .review, action: .trash, regenerable: false,
            paths: ["~/Downloads/*"], minAgeDays: 30
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
        #expect(result.needsAccess)
    }
}
