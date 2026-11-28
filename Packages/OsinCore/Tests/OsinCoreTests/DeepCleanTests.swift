import Foundation
import Testing
@testable import OsinCore

// MARK: - Apps that must be closed

struct ClosedAppTests {
    private func browserRule() -> CleanupRule {
        CleanupRule(
            id: "browser.caches", name: "Browser caches", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Application Support/Google/Chrome/*/Code Cache/*", "~/Library/Application Support/Slack/Cache/*"],
            closedApps: [
                CleanupRule.ClosedApp(app: "Google Chrome.app", folder: "~/Library/Application Support/Google/Chrome"),
                CleanupRule.ClosedApp(app: "Slack.app", folder: "~/Library/Application Support/Slack")
            ]
        )
    }

    @Test func itemsOfARunningAppAreMarkedBlocked() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Application Support/Google/Chrome/Default/Code Cache/js/a")
        try fixture.file("Library/Application Support/Slack/Cache/b")
        let scanner = Scanner(home: fixture.home, runningApps: { ["Google Chrome.app"] })
        let result = try #require(try await scanner.scan([browserRule()]).first)
        let blocked = result.items.filter { $0.blockedBy != nil }
        #expect(blocked.map(\.blockedBy) == ["Google Chrome"])
        #expect(result.items.count(where: { $0.blockedBy == nil }) == 1)
        #expect(result.blockedBytes == blocked.reduce(0) { $0 + $1.bytes })
    }

    @Test func theCleanerRefusesWhileTheAppRuns() async throws {
        let fixture = try FixtureHome()
        let cache = try fixture.file("Library/Application Support/Slack/Cache/b")
        let scanner = Scanner(home: fixture.home, runningApps: { [] })
        let result = try #require(try await scanner.scan([browserRule()]).first)
        // Slack was opened between the scan and the clean.
        let cleaner = Cleaner(
            home: fixture.home, trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl")), runningApps: { ["Slack.app"] }
        )
        let outcome = await cleaner.clean([CleanupSelection(rule: result.rule, items: result.items)])
        #expect(outcome.failures.map(\.kind) == [.appRunning("Slack")])
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func closedAppsMustNameAnAppAndAFolderInHome() {
        let bad = CleanupRule(
            id: "x", name: "x", detail: "", tier: .safe, action: .delete, regenerable: true, paths: ["~/x/*"],
            closedApps: [CleanupRule.ClosedApp(app: "Chrome", folder: "/Library")]
        )
        #expect(throws: CleanupRuleError.self) { try bad.validate() }
    }

    @Test func runningAppNamesComeFromProcessPaths() {
        let names = AppActivity.appNames(fromExecutablePaths: [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/"
                + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            "/usr/bin/ssh",
            "/Applications/Slack.app/Contents/MacOS/Slack"
        ])
        #expect(names == ["Google Chrome.app", "Slack.app"])
    }
}

// MARK: - Cold projects

struct ColdProjectTests {
    private let rule = CleanupRule(
        id: "dev.cold-projects", name: "Cold projects", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
        find: CleanupRule.Find(
            roots: ["~/Projects"],
            targets: [
                CleanupRule.Find.Target(name: "node_modules"),
                CleanupRule.Find.Target(name: ".venv", inside: "pyvenv.cfg"),
                CleanupRule.Find.Target(name: "target", sibling: "Cargo.toml")
            ],
            maxDepth: 4, coldDays: 30, includeProjectRoots: true
        )
    )

    @Test func onlyProjectsUntouchedForThirtyDaysAreOffered() async throws {
        let fixture = try FixtureHome()
        // Cold: sources and git both 60 days old, node_modules freshly installed (its own dates don't matter).
        try fixture.file("Projects/old/package.json", age: 60)
        try fixture.file("Projects/old/.git/logs/HEAD", age: 60)
        try fixture.file("Projects/old/node_modules/lib/index.js", age: 0)
        // Warm: a commit yesterday.
        try fixture.file("Projects/active/package.json", age: 60)
        try fixture.file("Projects/active/.git/logs/HEAD", age: 1)
        try fixture.file("Projects/active/node_modules/lib/index.js", age: 60)
        // Warm: a source file edited last week, no git.
        try fixture.file("Projects/sketch/src/main.ts", age: 7)
        try fixture.file("Projects/sketch/node_modules/lib/index.js", age: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.map { $0.url.path.replacingOccurrences(of: fixture.home.path, with: "~") } == ["~/Projects/old/node_modules"])
    }

    @Test func targetsNeedTheirMarker() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/rust/Cargo.toml", age: 60)
        try fixture.file("Projects/rust/target/debug/app", age: 60)
        try fixture.file("Projects/web/target/notes.txt", age: 60) // a folder that happens to be called target
        try fixture.file("Projects/py/.venv/pyvenv.cfg", age: 60)
        try fixture.file("Projects/py/main.py", age: 60)
        try fixture.file("Projects/fake/.venv/readme.txt", age: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        let found = Set(result.items.map { $0.url.path.replacingOccurrences(of: fixture.home.path, with: "~") })
        #expect(found == ["~/Projects/rust/target", "~/Projects/py/.venv"])
    }

    @Test func userProjectFoldersAreSearchedToo() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Work/clients/acme/package.json", age: 60)
        try fixture.file("Work/clients/acme/node_modules/x.js", age: 60)
        let scanner = Scanner(home: fixture.home, projectRoots: [fixture.home.appendingPathComponent("Work")])
        let result = try #require(try await scanner.scan([rule]).first)
        #expect(result.items.count == 1)
    }

    @Test func projectFoldersOutsideHomeOrProtectedAreIgnored() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/app/package.json", age: 60)
        try fixture.file("Documents/app/node_modules/x.js", age: 60)
        try fixture.file("app/package.json", age: 60, in: fixture.outside)
        try fixture.file("app/node_modules/x.js", age: 60, in: fixture.outside)
        let scanner = Scanner(home: fixture.home, projectRoots: [fixture.home.appendingPathComponent("Documents"), fixture.outside])
        let result = try #require(try await scanner.scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func theCleanerChecksTheProjectIsStillCold() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/old/package.json", age: 60)
        try fixture.file("Projects/old/node_modules/x.js", age: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.count == 1)
        // The user opened the project again before cleaning.
        try fixture.file("Projects/old/src/new.ts", age: 0)
        let cleaner = Cleaner(
            home: fixture.home, trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: result.items)])
        #expect(outcome.failures.map(\.kind) == [.usedRecently])
    }

    @Test func findRulesAreValidated() {
        let empty = CleanupRule(
            id: "x", name: "x", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(roots: ["~/Projects"], targets: [], maxDepth: 4)
        )
        #expect(throws: CleanupRuleError.self) { try empty.validate() }
        let sneaky = CleanupRule(
            id: "x", name: "x", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(roots: ["~/Projects"], targets: [CleanupRule.Find.Target(name: "target", sibling: "../x")], maxDepth: 4)
        )
        #expect(throws: CleanupRuleError.self) { try sneaky.validate() }
    }
}

// MARK: - Unused toolchains

struct ToolchainTests {
    private let rule = CleanupRule(
        id: "dev.toolchains", name: "Unused toolchains", detail: "", tier: .review, action: .trash, regenerable: true,
        paths: ["~/.nvm/versions/node/*", "~/.pyenv/versions/*", "~/.rustup/toolchains/*"], special: .unusedToolchains
    )

    @Test func keepsDefaultsAndVersionsProjectsUse() async throws {
        let fixture = try FixtureHome()
        for version in ["v18.20.1", "v22.23.3", "v24.18.0", "v25.8.0"] {
            try fixture.file(".nvm/versions/node/\(version)/bin/node")
        }
        try fixture.file(".nvm/alias/default").write("25\n")
        try fixture.file("Projects/api/.nvmrc").write("v22\n")
        for version in ["3.11.12", "3.12.8", "3.13.1"] {
            try fixture.file(".pyenv/versions/\(version)/bin/python")
        }
        try fixture.file(".pyenv/version").write("3.13.1\n")
        try fixture.file("Projects/ml/.python-version").write("3.11\n")
        for toolchain in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin", "1.75.0-aarch64-apple-darwin"] {
            try fixture.file(".rustup/toolchains/\(toolchain)/bin/rustc")
        }
        try fixture.file(".rustup/settings.toml").write("default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        try fixture.file("Projects/legacy/rust-toolchain.toml").write("[toolchain]\nchannel = \"1.75.0\"\n")

        let scanner = Scanner(home: fixture.home)
        let result = try #require(try await scanner.scan([rule]).first)
        let offered = Set(result.items.map(\.url.lastPathComponent))
        #expect(offered == ["v18.20.1", "v24.18.0", "3.12.8", "nightly-aarch64-apple-darwin"])
    }

    @Test func aPinnedVersionThatIsNotInstalledIsIgnored() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file(".nvm/alias/default").write("22\n")
        try fixture.file("Projects/old/.nvmrc").write("12.18.0\n")
        try fixture.file(".pyenv/versions/3.11.2/bin/python")
        try fixture.file(".pyenv/versions/3.12.1/bin/python")
        try fixture.file(".pyenv/version").write("3.12.1\n")
        try fixture.file("Projects/new/.python-version").write("3.13\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(Set(result.items.map(\.url.lastPathComponent)) == ["v20.1.0", "3.11.2"])
    }

    @Test func anUnreadableDefaultKeepsEverythingForThatTool() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file(".nvm/alias/default").write("lts/*\n") // needs the network to resolve
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }
}

// MARK: - Docker

struct DockerTests {
    @Test func parsesSizesTheWayDockerPrintsThem() {
        #expect(DockerInventory.bytes("262.9MB") == 262_900_000)
        #expect(DockerInventory.bytes("1.547GB") == 1_547_000_000)
        #expect(DockerInventory.bytes("28.67kB") == 28670)
        #expect(DockerInventory.bytes("0B") == 0)
        #expect(DockerInventory.bytes("garbage") == nil)
    }

    @Test func findsDanglingImagesUnusedVolumesAndReclaimableBuildCache() throws {
        let json = """
        {"Images":[
          {"ID":"sha256:aaa","Repository":"<none>","Tag":"<none>","Size":"262.9MB","Containers":"0"},
          {"ID":"sha256:bbb","Repository":"postgres","Tag":"16","Size":"431MB","Containers":"1"}],
         "Containers":[],
         "Volumes":[
          {"Name":"old_data","Links":"0","Size":"1.2GB"},
          {"Name":"live_data","Links":"1","Size":"3GB"}],
         "BuildCache":[
          {"ID":"c1","InUse":false,"Size":"400MB","Shared":false},
          {"ID":"c2","InUse":true,"Size":"100MB","Shared":false},
          {"ID":"c3","InUse":false,"Size":"97.1MB","Shared":false}]}
        """
        let usage = try DockerInventory.parse(systemDF: Data(json.utf8))
        #expect(usage.danglingImages.map(\.id) == ["sha256:aaa"])
        #expect(usage.danglingImages.first?.bytes == 262_900_000)
        #expect(usage.unusedVolumes.map(\.name) == ["old_data"])
        #expect(usage.buildCacheBytes == 497_100_000)
    }

    @Test func findsTheDockerCommandInKnownPlacesOnly() {
        #expect(DockerInventory.candidatePaths(home: URL(fileURLWithPath: "/Users/me")).allSatisfy { $0.hasPrefix("/") })
    }
}

// MARK: - Space Lens

struct SpaceLensTests {
    @Test func sizesAddUpAndLargestComeFirst() async throws {
        let fixture = try FixtureHome()
        try fixture.file("big/a.bin", bytes: 300_000)
        try fixture.file("big/nested/b.bin", bytes: 200_000)
        try fixture.file("small/c.bin", bytes: 10000)
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 0).scan()
        #expect(tree.children.map(\.name).prefix(2) == ["big", "small"])
        let big = try #require(tree.children.first)
        #expect(big.bytes >= 500_000)
        #expect(big.children.map(\.name) == ["a.bin", "nested"])
        #expect(tree.bytes >= big.bytes + 10000)
    }

    @Test func symlinksAreNotFollowed() async throws {
        let fixture = try FixtureHome()
        try fixture.file("data.bin", bytes: 400_000, in: fixture.outside)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("link"), withDestinationURL: fixture.outside)
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 0).scan()
        #expect(tree.bytes < 100_000)
    }

    @Test func privacyProtectedFoldersAreSkippedWithoutFullDiskAccess() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/report.pdf", bytes: 50000)
        try fixture.file("Library/Containers/com.example/data", bytes: 50000)
        let tree = try await SpaceScanner(home: fixture.home, includePrivateAreas: false, minNodeBytes: 0).scan()
        let documents = try #require(tree.children.first { $0.name == "Documents" })
        #expect(documents.isSkipped)
        #expect(documents.bytes == 0)
        let library = try #require(tree.children.first { $0.name == "Library" })
        #expect(library.children.first { $0.name == "Containers" }?.isSkipped == true)
    }

    @Test func protectedLocationsAreMarkedSoTheyCannotBeTrashed() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Pictures/photo.jpg", bytes: 20000)
        try fixture.file("stuff/file.bin", bytes: 20000)
        let tree = try await SpaceScanner(home: fixture.home, includePrivateAreas: true, minNodeBytes: 0).scan()
        #expect(tree.children.first { $0.name == "Pictures" }?.canTrash == false)
        #expect(tree.children.first { $0.name == "stuff" }?.canTrash == true)
    }

    @Test func manySmallEntriesAreFoldedIntoOne() async throws {
        let fixture = try FixtureHome()
        for index in 0 ..< (SpaceScanner.childLimit + 10) {
            try fixture.file("many/f\(index)", bytes: 1000 + index)
        }
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 0).scan()
        let many = try #require(tree.children.first { $0.name == "many" })
        #expect(many.children.count == SpaceScanner.childLimit)
        #expect(many.otherCount == 10)
        #expect(many.otherBytes > 0)
    }

    @Test func smallEntriesAreCountedButNotListed() async throws {
        let fixture = try FixtureHome()
        try fixture.file("mix/big.bin", bytes: 2_000_000)
        for index in 0 ..< 5 {
            try fixture.file("mix/small\(index)", bytes: 1000)
        }
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 1_000_000).scan()
        let mix = try #require(tree.children.first { $0.name == "mix" })
        #expect(mix.children.map(\.name) == ["big.bin"])
        #expect(mix.otherCount == 5)
        #expect(mix.bytes >= 2_000_000 + 5000)
    }

    @Test func treeSurvivesACodableRoundTrip() async throws {
        let fixture = try FixtureHome()
        try fixture.file("a/b.bin", bytes: 4000)
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 0).scan()
        let decoded = try JSONDecoder().decode(SpaceNode.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
    }
}

struct FolderGuideTests {
    @Test func describesWellKnownFolders() throws {
        let uvCache = try #require(FolderGuide.bundled.describe(relativePath: ".cache/uv"))
        #expect(uvCache.advice == .safe)
        let chromeModel = try #require(FolderGuide.bundled
            .describe(relativePath: "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"))
        #expect(chromeModel.advice == .review)
        let keychains = try #require(FolderGuide.bundled.describe(relativePath: "Library/Keychains"))
        #expect(keychains.advice == .keep)
        #expect(FolderGuide.bundled.describe(relativePath: "Projects/random-folder") == nil)
    }

    @Test func everyEntryHasTextAndAValidPattern() {
        for entry in FolderGuide.bundled.entries {
            #expect(!entry.title.isEmpty && !entry.detail.isEmpty)
            #expect(!entry.pattern.hasPrefix("/") && !entry.pattern.contains(".."))
        }
    }
}

// MARK: - Bundled rules

struct DeepCleanRuleTests {
    @Test func newRulesShipAndValidate() throws {
        let rules = try CleanupRule.bundled()
        for rule in rules {
            try rule.validate()
        }
        let ids = Set(rules.map(\.id))
        for id in [
            "dev.tool-caches",
            "browser.caches",
            "browser.chrome-ai-model",
            "dev.cold-projects",
            "dev.toolchains",
            "ai.agent-sessions"
        ] {
            #expect(ids.contains(id), "missing \(id)")
        }
        #expect(!ids.contains("dev.node-modules"), "replaced by dev.cold-projects")
    }

    @Test func browserCachesNeverTouchProfilesThemselves() throws {
        let rules = try CleanupRule.bundled()
        let browser = try #require(rules.first { $0.id == "browser.caches" })
        #expect(browser.tier == .safe)
        for path in browser.paths {
            let cacheFolder = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            #expect(
                ["Cache", "Code Cache", "GPUCache", "CacheStorage", "CachedData", "ScriptCache", "DawnGraphiteCache", "DawnWebGPUCache"]
                    .contains(cacheFolder),
                "\(path) is not a cache folder"
            )
        }
        #expect(!browser.closedApps.isEmpty)
        for path in browser.paths {
            #expect(browser.closedApps.contains { path.hasPrefix($0.folder + "/") }, "\(path) has no app to wait for")
        }
    }
}

extension URL {
    /// Test helper: overwrite a fixture file with text.
    func write(_ text: String) throws {
        try Data(text.utf8).write(to: self)
    }
}
