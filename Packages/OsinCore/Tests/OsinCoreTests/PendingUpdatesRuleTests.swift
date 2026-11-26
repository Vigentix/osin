import Foundation
import Testing
@testable import OsinCore

/// App caches skip Osin's own cache and half-downloaded app updates; those updates are offered
/// separately for review instead (feedback from the first real cleanup).
struct PendingUpdatesRuleTests {
    @Test func appCachesLeaveOsinAndPendingUpdatesAlone() throws {
        let caches = try #require(try CleanupRule.bundled().first { $0.id == "user.caches" })
        for pattern in ["com.vigentix.osin", "*.ShipIt", "*-updater"] {
            #expect(caches.excludes.contains(pattern))
        }
    }

    @Test func pendingUpdatesAreAReviewItemThatGoesToTheTrash() throws {
        let rule = try #require(try CleanupRule.bundled().first { $0.id == "app.pending-updates" })
        #expect(rule.tier == .review)
        #expect(rule.action == .trash)
        try rule.validate()
    }

    @Test func scanSortsCachesUpdatesAndOsinCorrectly() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/Homebrew/bottle.tar.gz")
        try fixture.file("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update.zip")
        try fixture.file("Library/Caches/orca-updater/pending/Orca.zip")
        try fixture.file("Library/Caches/com.vigentix.osin/Cache.db")
        let rules = try CleanupRule.bundled().filter { ["user.caches", "app.pending-updates"].contains($0.id) }
        let results = try await Scanner(home: fixture.home).scan(rules)
        func names(_ id: String) -> [String] {
            (results.first { $0.rule.id == id }?.items.map(\.url.lastPathComponent) ?? []).sorted()
        }
        #expect(names("user.caches") == ["Homebrew"])
        #expect(names("app.pending-updates") == ["com.tinyspeck.slackmacgap.ShipIt", "orca-updater"])
    }
}
