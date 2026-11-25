import Foundation
import Testing
@testable import OsinCore

/// A throwaway home directory. Every scanner test runs inside one; nothing outside it is touched.
final class FixtureHome {
    let root: URL
    let home: URL
    let outside: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("osin-fixture-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions changed by tests so cleanup succeeds.
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10000, age days: Double = 0, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try age(url, days: days)
        return url
    }

    @discardableResult
    func directory(_ relative: String, age days: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try age(url, days: days)
        return url
    }

    func age(_ url: URL, days: Double) throws {
        guard days > 0 else { return }
        let date = Date().addingTimeInterval(-days * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

struct ScannerTests {
    private func rule(_ id: String, _ paths: [String], minAge: Int? = nil, tier: CleanupTier = .safe) -> CleanupRule {
        CleanupRule(
            id: id, name: id, detail: "", tier: tier, action: tier == .safe ? .delete : .trash,
            regenerable: tier == .safe, paths: paths, minAgeDays: minAge
        )
    }

    @Test func globMatchesChildrenAndMeasuresThem() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.a/blob", bytes: 50000)
        try fixture.file("Library/Caches/com.b/blob", bytes: 20000)
        let results = try await Scanner(home: fixture.home).scan([rule("caches", ["~/Library/Caches/*"])])
        let caches = try #require(results.first)
        #expect(caches.items.map(\.url.lastPathComponent).sorted() == ["com.a", "com.b"])
        #expect(caches.totalBytes >= 70000)
    }

    @Test func extensionGlobsMatchOnlyThoseFiles() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Downloads/a.dmg")
        try fixture.file("Downloads/b.pkg")
        try fixture.file("Downloads/c.pdf")
        let results = try await Scanner(home: fixture.home).scan([rule(
            "installers",
            ["~/Downloads/*.dmg", "~/Downloads/*.pkg"],
            tier: .review
        )])
        #expect(results.first?.items.map(\.url.lastPathComponent).sorted() == ["a.dmg", "b.pkg"])
    }

    @Test func minimumAgeFiltersRecentItems() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Logs/old.log", age: 30)
        try fixture.file("Library/Logs/new.log")
        let results = try await Scanner(home: fixture.home).scan([rule("logs", ["~/Library/Logs/*"], minAge: 7)])
        #expect(results.first?.items.map(\.url.lastPathComponent) == ["old.log"])
    }

    @Test func symlinkPointingOutsideIsSkippedAndNotMeasured() async throws {
        let fixture = try FixtureHome()
        let precious = try fixture.file("precious/data", bytes: 900_000, in: fixture.outside)
        try fixture.directory("Library/Caches")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Caches/escape"),
            withDestinationURL: precious.deletingLastPathComponent()
        )
        try fixture.file("Library/Caches/real/blob", bytes: 1000)
        let results = try await Scanner(home: fixture.home).scan([rule("caches", ["~/Library/Caches/*"])])
        let names = results.first?.items.map(\.url.lastPathComponent) ?? []
        #expect(names == ["real"])
        #expect((results.first?.totalBytes ?? 0) < 900_000)
    }

    @Test func symlinkedRuleRootIntoProtectedFolderYieldsNothing() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/thesis.docx")
        try fixture.directory("Library")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Caches"),
            withDestinationURL: fixture.home.appendingPathComponent("Documents")
        )
        let results = try await Scanner(home: fixture.home).scan([rule("caches", ["~/Library/Caches/*"])])
        #expect(results.first?.items.isEmpty == true)
    }

    @Test func nestedSymlinksInsideAnItemAreNotFollowedWhenMeasuring() async throws {
        let fixture = try FixtureHome()
        try fixture.file("big", bytes: 2_000_000, in: fixture.outside)
        try fixture.file("Library/Caches/app/small", bytes: 1000)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Caches/app/link"),
            withDestinationURL: fixture.outside
        )
        let results = try await Scanner(home: fixture.home).scan([rule("caches", ["~/Library/Caches/*"])])
        #expect((results.first?.totalBytes ?? .max) < 2_000_000)
    }

    @Test func itemsClaimedByAnEarlierRuleAreNotCountedTwice() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/Homebrew/downloads/x", bytes: 5000)
        let results = try await Scanner(home: fixture.home).scan([
            rule("caches", ["~/Library/Caches/*"]),
            rule("brew", ["~/Library/Caches/Homebrew/*"])
        ])
        #expect(results.count == 2)
        #expect(results[0].items.count == 1)
        #expect(results[1].items.isEmpty)
    }

    @Test func missingRootGivesEmptyResult() async throws {
        let fixture = try FixtureHome()
        let results = try await Scanner(home: fixture.home).scan([rule("gradle", ["~/.gradle/caches/*"])])
        #expect(results.first?.items.isEmpty == true)
        #expect(results.first?.needsAccess == false)
    }

    @Test func unreadableRootIsReportedAsNeedingAccess() async throws {
        let fixture = try FixtureHome()
        let locked = try fixture.directory("Library/Containers")
        try fixture.file("Library/Containers/x/y")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let results = try await Scanner(home: fixture.home).scan([rule("containers", ["~/Library/Containers/*"])])
        #expect(results.first?.needsAccess == true)
        #expect(results.first?.items.isEmpty == true)
    }

    @Test func findRuleLocatesOldNodeModulesWithoutDescendingIntoThem() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/old-app/node_modules/left-pad/index.js", bytes: 3000)
        try fixture.file("Projects/old-app/node_modules/dep/node_modules/inner/index.js", bytes: 3000)
        try fixture.age(fixture.home.appendingPathComponent("Projects/old-app/node_modules"), days: 200)
        try fixture.file("Projects/new-app/node_modules/react/index.js", bytes: 3000)
        let find = CleanupRule(
            id: "node", name: "node", detail: "", tier: .review, action: .trash, regenerable: false, paths: [],
            minAgeDays: 90, find: CleanupRule.Find(roots: ["~/Projects", "~/Missing"], directoryName: "node_modules", maxDepth: 4)
        )
        let results = try await Scanner(home: fixture.home).scan([find])
        let paths = results.first?.items.map(\.url.path) ?? []
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("Projects/old-app/node_modules") == true)
    }

    @Test func protectedFolderIsNeverReturnedEvenIfARuleTargetsIt() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/thesis.docx")
        // Bypass validation on purpose: the scanner must still refuse.
        let hostile = rule("bad", ["~/Documents/*"])
        let results = try await Scanner(home: fixture.home).scan([hostile])
        #expect(results.first?.items.isEmpty == true)
    }

    @Test func progressReportsEachRule() async throws {
        let fixture = try FixtureHome()
        let recorder = ProgressRecorder()
        _ = try await Scanner(home: fixture.home).scan([rule("a", ["~/a/*"]), rule("b", ["~/b/*"])]) { event in
            if event.completed == nil {
                recorder.append(event.ruleID)
            }
        }
        #expect(recorder.values == ["a", "b"])
    }

    @Test func cancellationStopsTheScan() async throws {
        let fixture = try FixtureHome()
        for index in 0 ..< 50 {
            try fixture.file("Library/Caches/c\(index)/f", bytes: 100)
        }
        let task = Task {
            try await Scanner(home: fixture.home).scan(Array(repeating: rule("caches", ["~/Library/Caches/*"]), count: 200))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

struct ScannerCompletionTests {
    @Test func eachRuleReportsItsResultWhenFinished() async throws {
        let fixture = try FixtureHome()
        try fixture.file("a/x", bytes: 5000)
        let finished = ProgressRecorder()
        let rules = [
            CleanupRule(id: "a", name: "a", detail: "", tier: .safe, action: .delete, regenerable: true, paths: ["~/a/*"]),
            CleanupRule(id: "b", name: "b", detail: "", tier: .safe, action: .delete, regenerable: true, paths: ["~/b/*"])
        ]
        _ = try await Scanner(home: fixture.home).scan(rules) { event in
            if let result = event.completed {
                finished.append("\(result.rule.id):\(result.items.count)")
            }
        }
        #expect(finished.values == ["a:1", "b:0"])
    }
}

struct ScannerExcludeTests {
    @Test func excludedNamesAreNeverMatched() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.apple.AppleMediaServices/x", bytes: 4000)
        try fixture.file("Library/Caches/com.google.Chrome/x", bytes: 4000)
        let rule = CleanupRule(
            id: "caches", name: "c", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Caches/*"], excludes: ["com.apple.*"]
        )
        let results = try await Scanner(home: fixture.home).scan([rule])
        #expect(results.first?.items.map(\.url.lastPathComponent) == ["com.google.Chrome"])
    }

    @Test func excludePatternsCannotContainPaths() {
        let rule = CleanupRule(
            id: "x", name: "x", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Caches/*"], excludes: ["../Documents"]
        )
        #expect(throws: CleanupRuleError.self) { try rule.validate() }
    }

    @Test func bundledCacheRuleSkipsAppleCaches() throws {
        let caches = try #require(try CleanupRule.bundled().first { $0.id == "user.caches" })
        #expect(caches.excludes.contains("com.apple.*"))
    }

    @Test func storageCachesSkipAppleCaches() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.apple.AppleMediaServices/x", bytes: 500_000)
        try fixture.file("Library/Caches/com.google.Chrome/x", bytes: 4000)
        let breakdown = try await StorageBreakdown.measure(
            home: fixture.home, applications: fixture.outside, totalBytes: 10_000_000, availableBytes: 1_000_000, reclaimableBytes: 0
        )
        #expect(breakdown.caches < 500_000)
    }
}
