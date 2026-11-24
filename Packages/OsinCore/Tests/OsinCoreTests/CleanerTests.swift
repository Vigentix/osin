import Foundation
import Testing
@testable import OsinCore

/// Moves items into the fixture's own trash folder instead of the user's real Trash.
struct FixtureTrash: TrashMover {
    let directory: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

struct CleanerTests {
    private func rule(_ id: String, tier: CleanupTier, action: CleanupAction, regenerable: Bool = true) -> CleanupRule {
        CleanupRule(id: id, name: id, detail: "", tier: tier, action: action, regenerable: regenerable, paths: ["~/x/*"])
    }

    private func setup() throws -> (FixtureHome, Cleaner, URL) {
        let fixture = try FixtureHome()
        let trash = fixture.root.appendingPathComponent("trash")
        let log = fixture.root.appendingPathComponent("log.jsonl")
        let cleaner = Cleaner(home: fixture.home, trash: FixtureTrash(directory: trash), log: CleanupLog(url: log))
        return (fixture, cleaner, log)
    }

    private func item(_ url: URL, bytes: UInt64 = 10000) -> ScanItem {
        ScanItem(url: url.resolvingSymlinksInPath(), bytes: bytes, modified: nil)
    }

    @Test func deleteRemovesItemAndCountsFreedBytes() async throws {
        let (fixture, cleaner, _) = try setup()
        let cache = try fixture.file("Library/Caches/app/blob")
        let target = cache.deletingLastPathComponent()
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [item(target)])])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(outcome.freedBytes == 10000)
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.failures.isEmpty)
    }

    @Test func trashMovesItemAndCanBeUndone() async throws {
        let (fixture, cleaner, _) = try setup()
        let file = try fixture.file("Downloads/setup.dmg")
        let outcome = await cleaner.clean([CleanupSelection(
            rule: rule("installers", tier: .review, action: .trash, regenerable: false),
            items: [item(file)]
        )])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(outcome.trashedBytes == 10000)
        #expect(outcome.freedBytes == 0)
        let trashed = try #require(outcome.trashed.first)
        #expect(FileManager.default.fileExists(atPath: trashed.trashURL.path))

        let failures = await cleaner.undo(outcome.trashed)
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func undoNeverOverwritesAFileThatReappeared() async throws {
        let (fixture, cleaner, _) = try setup()
        let file = try fixture.file("Downloads/notes.txt", bytes: 10)
        let outcome = await cleaner.clean([CleanupSelection(
            rule: rule("old", tier: .review, action: .trash, regenerable: false),
            items: [item(file)]
        )])
        try Data("new".utf8).write(to: file)
        let failures = await cleaner.undo(outcome.trashed)
        #expect(failures.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    }

    @Test func deleteIsRefusedForRulesThatAreNotSafeAndRegenerable() async throws {
        let (fixture, cleaner, _) = try setup()
        let file = try fixture.file("Downloads/thesis-draft.pdf")
        let bogus = rule("bogus", tier: .review, action: .delete, regenerable: false)
        let outcome = await cleaner.clean([CleanupSelection(rule: bogus, items: [item(file)])])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(outcome.failures.count == 1)
    }

    @Test func protectedItemIsRefusedEvenIfSelected() async throws {
        let (fixture, cleaner, _) = try setup()
        let file = try fixture.file("Documents/thesis.docx")
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [item(file)])])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(outcome.failures.count == 1)
    }

    @Test func itemOutsideHomeIsRefused() async throws {
        let (fixture, cleaner, _) = try setup()
        let file = try fixture.file("elsewhere", in: fixture.outside)
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [item(file)])])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(outcome.failures.count == 1)
    }

    @Test func itemReplacedBySymlinkAfterScanIsRefused() async throws {
        let (fixture, cleaner, _) = try setup()
        let precious = try fixture.file("precious", in: fixture.outside)
        let cache = try fixture.directory("Library/Caches/app")
        let scanned = item(cache)
        // Between scan and clean, the folder is swapped for a link to something precious.
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: precious)
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [scanned])])
        #expect(FileManager.default.fileExists(atPath: precious.path))
        #expect(outcome.failures.count == 1)
    }

    @Test func missingItemIsSkippedQuietly() async throws {
        let (fixture, cleaner, _) = try setup()
        let gone = fixture.home.appendingPathComponent("Library/Caches/gone")
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [item(gone)])])
        #expect(outcome.failures.isEmpty)
        #expect(outcome.freedBytes == 0)
    }

    @Test func everyActionIsLogged() async throws {
        let (fixture, cleaner, logURL) = try setup()
        let cache = try fixture.directory("Library/Caches/app")
        let file = try fixture.file("Downloads/a.dmg")
        _ = await cleaner.clean([
            CleanupSelection(rule: rule("caches", tier: .safe, action: .delete), items: [item(cache)]),
            CleanupSelection(rule: rule("installers", tier: .review, action: .trash, regenerable: false), items: [item(file)])
        ])
        let entries = try CleanupLog(url: logURL).entries()
        #expect(entries.map(\.action) == ["delete", "trash"])
        #expect(entries.map(\.ruleID) == ["caches", "installers"])
        #expect(entries[1].trashPath != nil)
    }
}

struct BuiltinCleanupTests {
    @Test func parsesUnavailableSimulatorUDIDs() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
            {"udid": "AAA", "isAvailable": false, "name": "iPhone 14"},
            {"udid": "BBB", "isAvailable": false, "name": "iPad"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0": []
        }}
        """
        #expect(try SimulatorInventory.unavailableUDIDs(fromSimctlJSON: Data(json.utf8)).sorted() == ["AAA", "BBB"])
    }

    @Test func emptyTrashMeasuresAndRemovesOnlyTrashContents() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".Trash/old.zip", bytes: 4000)
        try fixture.file(".Trash/folder/x", bytes: 4000)
        let keep = try fixture.file("Downloads/keep.zip")
        let measured = try await EmptyTrash.measure(home: fixture.home)
        #expect(measured >= 8000)
        try await EmptyTrash.perform(home: fixture.home)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.home.appendingPathComponent(".Trash").path)
        #expect(remaining.isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func parsesMdfindOutputIntoLargeFiles() {
        let output = "/Users/t/Movies/a.mov\n/Users/t/Downloads/b.iso\n\n"
        #expect(LargeFileFinder.parse(output).map(\.path) == ["/Users/t/Movies/a.mov", "/Users/t/Downloads/b.iso"])
    }
}
