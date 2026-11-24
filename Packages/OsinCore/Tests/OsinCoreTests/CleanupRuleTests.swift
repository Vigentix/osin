import Foundation
import Testing
@testable import OsinCore

struct CleanupRuleValidationTests {
    private func rule(
        paths: [String] = ["~/Library/Caches/*"],
        tier: CleanupTier = .safe,
        action: CleanupAction = .delete,
        regenerable: Bool = true
    ) -> CleanupRule {
        CleanupRule(id: "test", name: "Test", detail: "", tier: tier, action: action, regenerable: regenerable, paths: paths)
    }

    @Test func validSafeDeleteRulePasses() throws {
        try rule().validate()
    }

    @Test func deleteRequiresSafeTier() {
        #expect(throws: CleanupRuleError.deleteNotAllowed) { try rule(tier: .review).validate() }
    }

    @Test func deleteRequiresRegenerableData() {
        #expect(throws: CleanupRuleError.deleteNotAllowed) { try rule(regenerable: false).validate() }
    }

    @Test func trashIsAllowedForReview() throws {
        try rule(tier: .review, action: .trash, regenerable: false).validate()
    }

    @Test(arguments: ["/Library/Caches/*", "Library/Caches/*", "$HOME/Library/*", "~root/x/*"])
    func pathMustBeInsideHome(path: String) {
        #expect(throws: CleanupRuleError.self) { try rule(paths: [path]).validate() }
    }

    @Test func parentDirectoryComponentsAreRejected() {
        #expect(throws: CleanupRuleError.self) { try rule(paths: ["~/Library/Caches/../../Documents/*"]).validate() }
    }

    @Test func lastComponentMustBeAGlobSoTheRootIsNeverRemoved() {
        #expect(throws: CleanupRuleError.self) { try rule(paths: ["~/Library/Developer/Xcode/DerivedData"]).validate() }
    }

    @Test(arguments: ["~/Documents/*", "~/Desktop/old/*", "~/Library/Mail/*", "~/Library/Mobile Documents/*", "~/*"])
    func protectedLocationsAreRejected(path: String) {
        #expect(throws: CleanupRuleError.self) { try rule(paths: [path]).validate() }
    }

    @Test func findRulesNeedRootsAndAName() {
        let bad = CleanupRule(
            id: "x", name: "x", detail: "", tier: .review, action: .trash, regenerable: false,
            paths: [], find: CleanupRule.Find(roots: [], directoryName: "node_modules", maxDepth: 4)
        )
        #expect(throws: CleanupRuleError.self) { try bad.validate() }
    }

    @Test func bundledRulesAreAllValid() throws {
        let rules = try CleanupRule.bundled()
        #expect(rules.count >= 8)
        #expect(Set(rules.map(\.id)).count == rules.count)
        for rule in rules {
            try rule.validate()
        }
    }

    @Test func bundledRulesDecodeFromJSON() throws {
        let json = """
        {"id": "a", "name": "A", "detail": "d", "tier": "review", "action": "trash", "regenerable": false,
         "paths": ["~/Downloads/*.dmg"], "minAgeDays": 30, "requiresFullDiskAccess": false}
        """
        let decoded = try JSONDecoder().decode(CleanupRule.self, from: Data(json.utf8))
        #expect(decoded.minAgeDays == 30)
        #expect(decoded.tier == .review)
    }
}

struct ProtectedPathsTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test(arguments: [
        "/Users/tester/Documents/report.pdf",
        "/Users/tester/Desktop",
        "/Users/tester/Library/Mail/V10/x",
        "/Users/tester/Pictures/Photos Library.photoslibrary",
        "/Applications/Xcode.app",
        "/System/Library"
    ])
    func protectedPathsAndTheirContentsAreDenied(path: String) {
        #expect(ProtectedPaths(home: home).denies(URL(fileURLWithPath: path)))
    }

    @Test(arguments: ["/Users/tester", "/Users/tester/Library", "/Users", "/"])
    func ancestorsOfProtectedPathsAreDenied(path: String) {
        // Removing ~/Library would remove Mail with it.
        #expect(ProtectedPaths(home: home).denies(URL(fileURLWithPath: path)))
    }

    @Test(arguments: ["/Users/tester/Library/Caches/com.example", "/Users/tester/Downloads/old.zip", "/Users/tester/.npm/_cacache/x"])
    func ordinaryCachePathsAreAllowed(path: String) {
        #expect(!ProtectedPaths(home: home).denies(URL(fileURLWithPath: path)))
    }

    @Test func similarlyNamedSiblingIsNotTreatedAsInside() {
        #expect(!ProtectedPaths(home: home).denies(URL(fileURLWithPath: "/Users/tester/DocumentsOld/x")))
    }
}
