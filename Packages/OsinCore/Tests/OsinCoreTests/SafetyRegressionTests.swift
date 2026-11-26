import Darwin
import Foundation
import Testing
@testable import OsinCore

/// Puts every item at `<directory>/<name>`, like the Finder Trash does once earlier items are gone.
private struct SameNameTrash: TrashMover {
    let directory: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Regression tests for issues found in the v0.1.0 review.
struct SafetyRegressionTests {
    private func rule(
        _ id: String,
        tier: CleanupTier = .review,
        action: CleanupAction = .trash,
        paths: [String] = ["~/x/*"],
        minAgeDays: Int? = nil,
        find: CleanupRule.Find? = nil
    ) -> CleanupRule {
        CleanupRule(
            id: id, name: id, detail: "", tier: tier, action: action, regenerable: action == .delete,
            paths: paths, minAgeDays: minAgeDays, find: find
        )
    }

    private func scanned(_ url: URL) -> ScanItem {
        let resolved = url.resolvingSymlinksInPath()
        return ScanItem(url: resolved, bytes: 10000, modified: nil, identity: FileIdentity(path: resolved.path))
    }

    // MARK: Restore identity

    @Test func restoreRefusesAnItemThatIsNotTheOneThatWasTrashed() async throws {
        let fixture = try FixtureHome()
        let trash = fixture.root.appendingPathComponent("trash")
        let cleaner = Cleaner(
            home: fixture.home,
            trash: SameNameTrash(directory: trash),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let projectA = try fixture.file("P/a/node_modules/lib.js").deletingLastPathComponent()
        let projectC = try fixture.file("P/c/node_modules/other.js").deletingLastPathComponent()
        let modules = rule("dev.node-modules")

        let first = await cleaner.clean([CleanupSelection(rule: modules, items: [scanned(projectA)])])
        let trashedA = try #require(first.trashed.first)
        // The user empties the Trash, then a later clean trashes another node_modules to the same path.
        try FileManager.default.removeItem(at: trashedA.trashURL)
        _ = await cleaner.clean([CleanupSelection(rule: modules, items: [scanned(projectC)])])

        let failures = await cleaner.undo([trashedA])
        #expect(failures.map(\.kind) == [.notTheTrashedItem])
        #expect(!FileManager.default.fileExists(atPath: projectA.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("node_modules/other.js").path))
    }

    @Test func restoreWithoutRecordedIdentityIsRefused() async throws {
        let fixture = try FixtureHome()
        let cleaner = Cleaner(home: fixture.home, log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl")))
        let inTrash = try fixture.file("trash/file.txt", in: fixture.root)
        let item = TrashedItem(originalURL: fixture.home.appendingPathComponent("file.txt"), trashURL: inTrash, bytes: 1, ruleID: "x")
        let failures = await cleaner.undo([item])
        #expect(failures.map(\.kind) == [.notTheTrashedItem])
        #expect(FileManager.default.fileExists(atPath: inTrash.path))
    }

    @Test func trashedItemIdentityIsLoggedForLaterRestore() async throws {
        let fixture = try FixtureHome()
        let logURL = fixture.root.appendingPathComponent("log.jsonl")
        let cleaner = Cleaner(
            home: fixture.home,
            trash: SameNameTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: logURL)
        )
        let file = try fixture.file("Downloads/setup.dmg")
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("installers"), items: [scanned(file)])])
        let entry = try #require(try CleanupLog(url: logURL).entries().first)
        #expect(entry.identity != nil)
        #expect(entry.identity == outcome.trashed.first?.identity)
    }

    // MARK: Empty Trash

    @Test func emptyTrashContinuesPastAnItemItCannotRemove() async throws {
        let fixture = try FixtureHome()
        let logURL = fixture.root.appendingPathComponent("log.jsonl")
        let cleaner = Cleaner(home: fixture.home, log: CleanupLog(url: logURL))
        try fixture.file(".Trash/a.zip", bytes: 4000)
        let locked = try fixture.file(".Trash/b.zip", bytes: 4000)
        try fixture.file(".Trash/c/inner", bytes: 4000)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

        let result = await cleaner.emptyTrash()
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.url.lastPathComponent == "b.zip")
        #expect(result.freedBytes >= 8000)
        #expect(result.freedBytes < 12000)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.home.appendingPathComponent(".Trash").path)
        #expect(remaining == ["b.zip"])
        let logged = try CleanupLog(url: logURL).entries()
        #expect(logged.count == 2)
        #expect(logged.allSatisfy { $0.action == "builtin:empty-trash" })
    }

    // MARK: Matching

    @Test func wildcardsDoNotMatchHiddenFiles() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Downloads/.localized", age: 400)
        try fixture.file("Downloads/.DS_Store", age: 400)
        let old = try fixture.file("Downloads/old.zip", age: 400)
        let results = try await Scanner(home: fixture.home).scan([rule("downloads.old", paths: ["~/Downloads/*"], minAgeDays: 30)])
        #expect(results.first?.items.map(\.url.lastPathComponent) == [old.lastPathComponent])
    }

    // MARK: Age

    @Test func ageUsesTheNewestFileInsideAFolder() async throws {
        let fixture = try FixtureHome()
        let find = CleanupRule.Find(roots: ["~/P"], directoryName: "node_modules", maxDepth: 3)
        // Active project: dependencies untouched, but something inside was written today.
        try fixture.file("P/active/node_modules/.cache/build", age: 0)
        try fixture.file("P/active/node_modules/lib/index.js", age: 200)
        try fixture.age(fixture.home.appendingPathComponent("P/active/node_modules/lib"), days: 200)
        try fixture.age(fixture.home.appendingPathComponent("P/active/node_modules"), days: 200)
        // Abandoned project: everything old.
        try fixture.file("P/stale/node_modules/lib/index.js", age: 200)
        try fixture.age(fixture.home.appendingPathComponent("P/stale/node_modules/lib"), days: 200)
        try fixture.age(fixture.home.appendingPathComponent("P/stale/node_modules"), days: 200)

        let results = try await Scanner(home: fixture.home).scan([rule("dev.node-modules", paths: [], minAgeDays: 90, find: find)])
        let found = try #require(results.first).items.map { $0.url.deletingLastPathComponent().lastPathComponent }
        #expect(found == ["stale"])
    }

    @Test func cleanerRechecksAgeAtCleanTime() async throws {
        let fixture = try FixtureHome()
        let cleaner = Cleaner(
            home: fixture.home,
            trash: SameNameTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let modules = try fixture.file("P/app/node_modules/lib.js", age: 200).deletingLastPathComponent()
        try fixture.age(modules, days: 200)
        let item = scanned(modules)
        // Used again after the scan.
        try fixture.file("P/app/node_modules/new.js")
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("dev.node-modules", minAgeDays: 90), items: [item])])
        #expect(outcome.failures.map(\.kind) == [.usedRecently])
        #expect(FileManager.default.fileExists(atPath: modules.path))
    }

    // MARK: Identity at clean time

    @Test func itemReplacedSinceTheScanIsRefused() async throws {
        let fixture = try FixtureHome()
        let cleaner = Cleaner(
            home: fixture.home,
            trash: SameNameTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let installer = try fixture.file("Downloads/tool.dmg")
        let item = scanned(installer)
        try FileManager.default.removeItem(at: installer)
        try fixture.file("Downloads/tool.dmg", bytes: 20)
        let outcome = await cleaner.clean([CleanupSelection(rule: rule("downloads.installers"), items: [item])])
        #expect(outcome.failures.map(\.kind) == [.changedSinceScan])
        #expect(FileManager.default.fileExists(atPath: installer.path))
    }

    // MARK: Sizes

    @Test func hardLinksSharedWithFilesOutsideTheItemAreNotCounted() throws {
        let fixture = try FixtureHome()
        let store = try fixture.directory("store")
        let shared = try fixture.file("store/shared.bin", bytes: 50000)
        try fixture.file("store/own.bin", bytes: 50000)
        let project = try fixture.directory("project")
        try FileManager.default.linkItem(at: shared, to: project.appendingPathComponent("shared.bin"))

        let storeSize = try DiskUsage.allocatedSize(of: store)
        let ownSize = try DiskUsage.allocatedSize(of: store.appendingPathComponent("own.bin"))
        #expect(storeSize == ownSize)

        // Both links inside the measured folder: counted once.
        let both = try DiskUsage.allocatedSize(of: fixture.home)
        #expect(both >= ownSize * 2)
        #expect(both < ownSize * 3)
    }

    // MARK: Rules

    @Test func appCachesKeepJetBrainsLocalHistory() throws {
        let caches = try #require(try CleanupRule.bundled().first { $0.id == "user.caches" })
        #expect(caches.excludes.contains("JetBrains"))
    }
}
