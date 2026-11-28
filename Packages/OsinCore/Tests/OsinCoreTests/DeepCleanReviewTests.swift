import Foundation
import Testing
@testable import OsinCore

// Regression tests for issues found in reviews of the deeper clean (0.5).

// MARK: - Review fixes (round 1)

struct DeepCleanSafetyTests {
    @Test func globsNeverFollowASymlinkedFolderInTheMiddle() async throws {
        let fixture = try FixtureHome()
        // Code Cache replaced by a link to the profile's site data.
        try fixture.file("Library/Application Support/Google/Chrome/Default/Local Storage/leveldb/000003.log")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Code Cache"),
            withDestinationURL: fixture.home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Local Storage")
        )
        let rule = CleanupRule(
            id: "browser", name: "b", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Application Support/Google/Chrome/*/Code Cache/*"]
        )
        let result = try #require(try await Scanner(home: fixture.home, runningApps: { [] }).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func mavenIsNotCleanedAutomatically() throws {
        let rules = try CleanupRule.bundled()
        #expect(!rules.contains { $0.tier == .safe && $0.paths.contains { $0.hasPrefix("~/.m2") } })
    }

    @Test func keepProtectionCoversEverythingInsideExceptNamedExceptions() {
        let guide = FolderGuide.bundled
        #expect(guide.isKept(relativePath: ".config"))
        #expect(guide.isKept(relativePath: ".config/some-app/settings.json"))
        #expect(guide.isKept(relativePath: ".claude/plugins"))
        #expect(!guide.isKept(relativePath: ".claude/projects/-Users-me-app"))
        #expect(!guide.isKept(relativePath: "Projects/app"))
    }

    @Test func userSelectedTrashRefusesKeptAndSystemFolders() async throws {
        let fixture = try FixtureHome()
        let settings = try fixture.file(".config/tool/config.toml")
        let library = try fixture.directory("Library/Preferences")
        let junk = try fixture.file("stuff/old.zip")
        let rule = CleanupRule(
            id: "space-lens", name: "Space Lens", detail: "", tier: .review, action: .trash, regenerable: false,
            paths: ["~/*"], special: .userSelected
        )
        let cleaner = Cleaner(
            home: fixture.home, trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let items = [settings, library, junk].map { url in
            ScanItem(
                url: url.resolvingSymlinksInPath(),
                bytes: 1,
                modified: nil,
                identity: FileIdentity(path: url.resolvingSymlinksInPath().path)
            )
        }
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: items)])
        #expect(outcome.failures.count == 2)
        #expect(outcome.trashed.map(\.originalURL.lastPathComponent) == ["old.zip"])
    }

    @Test func spaceLensRecordsWhatEachEntryWasWhenMeasured() async throws {
        let fixture = try FixtureHome()
        try fixture.file("folder/file.bin", bytes: 4000)
        let tree = try await SpaceScanner(home: fixture.home, minNodeBytes: 0).scan()
        let folder = try #require(tree.children.first { $0.name == "folder" })
        #expect(folder.identity == FileIdentity(path: folder.path))
    }
}

struct ColdProjectSafetyTests {
    private let rule = CleanupRule(
        id: "dev.cold-projects", name: "Cold projects", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
        find: CleanupRule.Find(roots: ["~/Projects"], targets: [CleanupRule.Find.Target(name: "node_modules")], maxDepth: 4, coldDays: 30)
    )

    @Test func aDeeplyNestedEditKeepsTheProjectWarm() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/app/package.json", age: 60)
        try fixture.file("Projects/app/.git/logs/HEAD", age: 60)
        try fixture.file("Projects/app/src/components/forms/Button.tsx", age: 0)
        try fixture.file("Projects/app/node_modules/x.js", age: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func worktreeActivityIsFoundThroughTheGitFile() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/main/.git/worktrees/feature/logs/HEAD", age: 0)
        try fixture.file("Projects/feature/package.json", age: 60)
        try fixture.file("Projects/feature/node_modules/x.js", age: 60)
        let gitdir = fixture.home.appendingPathComponent("Projects/main/.git/worktrees/feature").resolvingSymlinksInPath().path
        try fixture.file("Projects/feature/.git", age: 60).write("gitdir: \(gitdir)\n")
        try fixture.age(fixture.home.appendingPathComponent("Projects/feature/.git"), days: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func anUnresolvableGitFileKeepsTheProject() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/odd/package.json", age: 60)
        try fixture.file("Projects/odd/node_modules/x.js", age: 60)
        try fixture.file("Projects/odd/.git", age: 60).write("gitdir: /nowhere/at/all\n")
        try fixture.age(fixture.home.appendingPathComponent("Projects/odd/.git"), days: 60)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func aProjectRootLinkedIntoAProtectedFolderIsIgnored() throws {
        let fixture = try FixtureHome()
        try fixture.directory("Documents/Projects")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Projects"),
            withDestinationURL: fixture.home.appendingPathComponent("Documents/Projects")
        )
        #expect(ProjectRoots.all(home: fixture.home.resolvingSymlinksInPath(), extra: []).isEmpty)
    }
}

struct ToolchainSafetyTests {
    private let rule = CleanupRule(
        id: "dev.toolchains", name: "Unused toolchains", detail: "", tier: .review, action: .trash, regenerable: true,
        paths: ["~/.nvm/versions/node/*", "~/.pyenv/versions/*", "~/.rustup/toolchains/*"], special: .unusedToolchains
    )

    @Test func aVirtualenvProtectsThePythonItBelongsTo() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".pyenv/versions/3.11.2/bin/python")
        try fixture.file(".pyenv/versions/3.12.8/envs/myenv/bin/python")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent(".pyenv/versions/myenv"),
            withDestinationURL: fixture.home.appendingPathComponent(".pyenv/versions/3.12.8/envs/myenv")
        )
        try fixture.file(".pyenv/version").write("myenv\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.map(\.url.lastPathComponent) == ["3.11.2"])
    }

    @Test func pinsDeepInsideProjectsCount() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file(".nvm/alias/default").write("22\n")
        try fixture.file("Projects/client/product/apps/web/.nvmrc").write("20\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func theCleanerChecksAgainThatNothingUsesTheVersion() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file(".nvm/alias/default").write("22\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.count == 1)
        // A project starts pinning Node 20 before the clean.
        try fixture.file("Projects/new/.nvmrc").write("20\n")
        let cleaner = Cleaner(
            home: fixture.home, trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: result.items)])
        #expect(outcome.failures.map(\.kind) == [.usedRecently])
    }
}

struct DockerSafetyTests {
    @Test func onlyLocalDaemonsAreCleaned() {
        let local = #"[{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///Users/me/.colima/default/docker.sock"}}}]"#
        let remote = #"[{"Name":"prod","Endpoints":{"docker":{"Host":"ssh://deploy@server"}}}]"#
        #expect(DockerInventory.localHost(fromContextInspect: Data(local.utf8)) == "unix:///Users/me/.colima/default/docker.sock")
        #expect(DockerInventory.localHost(fromContextInspect: Data(remote.utf8)) == nil)
        #expect(DockerInventory.localHost(fromContextInspect: Data("garbage".utf8)) == nil)
    }
}

// MARK: - Review fixes (round 2)

struct DeepCleanSafetyRoundTwoTests {
    @Test func aSymlinkInTheFixedPartOfAPatternIsNotFollowed() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Application Support/Slack/Local Storage/leveldb/000003.log")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Application Support/Slack/Cache"),
            withDestinationURL: fixture.home.appendingPathComponent("Library/Application Support/Slack/Local Storage")
        )
        let rule = CleanupRule(
            id: "browser", name: "b", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Application Support/Slack/Cache/*"]
        )
        let result = try #require(try await Scanner(home: fixture.home, runningApps: { [] }).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func aRepurposedVenvIsKeptAtCleanTime() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/py/main.py", age: 60)
        try fixture.file("Projects/py/.venv/pyvenv.cfg", age: 60)
        let rule = CleanupRule(
            id: "dev.cold-projects", name: "c", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(
                roots: ["~/Projects"],
                targets: [CleanupRule.Find.Target(name: ".venv", inside: "pyvenv.cfg")],
                maxDepth: 4,
                coldDays: 30
            )
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.count == 1)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("Projects/py/.venv/pyvenv.cfg"))
        let cleaner = Cleaner(
            home: fixture.home, trash: FixtureTrash(directory: fixture.root.appendingPathComponent("trash")),
            log: CleanupLog(url: fixture.root.appendingPathComponent("log.jsonl"))
        )
        let outcome = await cleaner.clean([CleanupSelection(rule: rule, items: result.items)])
        #expect(outcome.failures.map(\.kind) == [.changedSinceScan])
    }

    @Test func dockerImageIDsMatchWhateverLengthDockerPrints() {
        #expect(DockerInventory.sameImage("sha256:0123456789abcdef0123", "0123456789ab"))
        #expect(!DockerInventory.sameImage("sha256:0123456789abcdef", "fedcba987654"))
    }
}

struct ToolchainSafetyRoundTwoTests {
    private let rule = CleanupRule(
        id: "dev.toolchains", name: "Unused toolchains", detail: "", tier: .review, action: .trash, regenerable: true,
        paths: ["~/.nvm/versions/node/*", "~/.pyenv/versions/*", "~/.rustup/toolchains/*"], special: .unusedToolchains
    )

    @Test func aTomlRustToolchainFileIsUnderstood() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")
        try fixture.file(".rustup/toolchains/1.75.0-aarch64-apple-darwin/bin/rustc")
        try fixture.file(".rustup/settings.toml").write("default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        try fixture.file("Projects/legacy/rust-toolchain").write("[toolchain]\nchannel = \"1.75.0\"\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func aDefaultThatMatchesNothingInstalledKeepsEverything() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".pyenv/versions/3.11.2/bin/python")
        try fixture.file(".pyenv/versions/3.12.1/bin/python")
        try fixture.file(".pyenv/version").write("3.13.0\n")
        try fixture.file(".rustup/toolchains/nightly-aarch64-apple-darwin/bin/rustc")
        try fixture.file(".rustup/settings.toml").write("default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func anUnreadablePinKeepsEverything() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".pyenv/versions/3.11.2/bin/python")
        try fixture.file(".pyenv/versions/3.12.1/bin/python")
        try fixture.file(".pyenv/version").write("3.12.1\n")
        let pin = try fixture.file("Projects/ml/.python-version")
        try pin.write("3.11\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pin.path)
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }
}

// MARK: - Review fixes (round 3)

struct DeepCleanSafetyRoundThreeTests {
    @Test func websiteOfflineStorageIsNeverDeletedAutomatically() throws {
        let rules = try CleanupRule.bundled()
        let safe = rules.filter { $0.tier == .safe }
        #expect(!safe.contains { $0.paths.contains { $0.contains("CacheStorage") } })
        let offline = try #require(rules.first { $0.id == "browser.site-storage" })
        #expect(offline.tier == .review && offline.action == .trash)
    }

    @Test func aSymlinkedFolderOnTheWayIsNotEvenListed() async throws {
        let fixture = try FixtureHome()
        // Chrome/Default points into Documents: listing it would trigger a privacy prompt.
        try fixture.directory("Documents/Code Cache")
        try fixture.directory("Library/Application Support/Google/Chrome")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Library/Application Support/Google/Chrome/Default"),
            withDestinationURL: fixture.home.appendingPathComponent("Documents")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.home.appendingPathComponent("Documents").path
        )
        let rule = CleanupRule(
            id: "b", name: "b", detail: "", tier: .safe, action: .delete, regenerable: true,
            paths: ["~/Library/Application Support/Google/Chrome/*/Code Cache/*"]
        )
        let result = try #require(try await Scanner(home: fixture.home, runningApps: { [] }).scan([rule]).first)
        // Had the link been followed, the unreadable Documents would have flagged "needs access".
        #expect(!result.needsAccess)
        #expect(result.items.isEmpty)
    }

    @Test func tomlWithCommentsIsReadCorrectly() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")
        try fixture.file(".rustup/toolchains/1.75.0-aarch64-apple-darwin/bin/rustc")
        try fixture.file(".rustup/settings.toml").write("default_toolchain = \"stable-aarch64-apple-darwin\"\n")
        try fixture.file("Projects/legacy/rust-toolchain").write("# Project toolchain\n[toolchain]\nchannel = \"1.75.0\" # Required\n")
        let rule = CleanupRule(
            id: "dev.toolchains", name: "t", detail: "", tier: .review, action: .trash, regenerable: true,
            paths: ["~/.rustup/toolchains/*"], special: .unusedToolchains
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
        #expect(ToolchainUsage.tomlString(#"channel = "1.75.0" # Required"#) == "1.75.0")
    }

    @Test func anUnreadableGitFolderKeepsTheProject() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/app/package.json", age: 60)
        try fixture.file("Projects/app/node_modules/x.js", age: 60)
        try fixture.file("Projects/app/.git/logs/HEAD", age: 0)
        let git = fixture.home.appendingPathComponent("Projects/app/.git")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: git.path)
        let rule = CleanupRule(
            id: "c", name: "c", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(
                roots: ["~/Projects"],
                targets: [CleanupRule.Find.Target(name: "node_modules")],
                maxDepth: 4,
                coldDays: 30
            )
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }
}

struct DeepCleanSafetyRoundFourTests {
    @Test func aLinkedPinFileIsNotRead() {
        let fixture = try? FixtureHome()
        guard let fixture else { return }
        _ = try? fixture.file("Documents/node-version")
        _ = try? fixture.directory("Projects/app")
        try? FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Projects/app/.nvmrc"),
            withDestinationURL: fixture.home.appendingPathComponent("Documents/node-version")
        )
        let pins = ProjectPins.find(in: [fixture.home.appendingPathComponent("Projects")])
        #expect(pins.node.isEmpty)
        #expect(pins.incomplete)
    }

    @Test func websiteStorageIsNotCalledRegenerable() {
        let entry = FolderGuide.bundled.describe(relativePath: "Library/Application Support/Google/Chrome/Default/Service Worker")
        #expect(entry?.advice == .review)
    }
}

struct DeepCleanSafetyRoundFiveTests {
    @Test func volumeCreationDatesAreParsed() {
        let dates = DockerInventory.parseCreationDates("db\t2026-11-01T10:00:00Z\ncache\t2026-11-20T08:00:00Z\nbroken\n")
        #expect(dates == ["db": "2026-11-01T10:00:00Z", "cache": "2026-11-20T08:00:00Z"])
    }

    @Test func aRecentlyEditedSourceFileNamedBuildCounts() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/tool/main.c", age: 60)
        try fixture.file("Projects/tool/build", age: 0)
        try fixture.file("Projects/tool/node_modules/x.js", age: 60)
        let rule = CleanupRule(
            id: "c", name: "c", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(
                roots: ["~/Projects"],
                targets: [CleanupRule.Find.Target(name: "node_modules")],
                maxDepth: 4,
                coldDays: 30
            )
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }

    @Test func aLinkedToolchainDefaultIsNotRead() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file("Documents/default").write("22\n")
        try fixture.directory(".nvm/alias")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent(".nvm/alias/default"),
            withDestinationURL: fixture.home.appendingPathComponent("Documents/default")
        )
        let rule = CleanupRule(
            id: "t", name: "t", detail: "", tier: .review, action: .trash, regenerable: true,
            paths: ["~/.nvm/versions/node/*"], special: .unusedToolchains
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty) // can't read the default safely: keep everything
    }
}

struct DeepCleanSafetyRoundSixTests {
    private let toolchains = CleanupRule(
        id: "t", name: "t", detail: "", tier: .review, action: .trash, regenerable: true,
        paths: ["~/.nvm/versions/node/*", "~/.pyenv/versions/*"], special: .unusedToolchains
    )

    @Test func anExplicitNvmAliasWinsOverTheBuiltInName() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".nvm/versions/node/v20.1.0/bin/node")
        try fixture.file(".nvm/versions/node/v22.1.0/bin/node")
        try fixture.file(".nvm/alias/default").write("stable\n")
        try fixture.file(".nvm/alias/stable").write("20\n")
        let result = try #require(try await Scanner(home: fixture.home).scan([toolchains]).first)
        #expect(result.items.map(\.url.lastPathComponent) == ["v22.1.0"])
    }

    @Test func aPinAboveAProjectFolderCounts() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".pyenv/versions/3.11.2/bin/python")
        try fixture.file(".pyenv/versions/3.12.1/bin/python")
        try fixture.file(".pyenv/version").write("3.12.1\n")
        try fixture.file("Work/.python-version").write("3.11.2\n")
        try fixture.directory("Work/client")
        let scanner = Scanner(home: fixture.home, projectRoots: [fixture.home.appendingPathComponent("Work/client")])
        let result = try #require(try await scanner.scan([toolchains]).first)
        #expect(result.items.isEmpty)
    }

    @Test func aSourceFolderNamedTargetStillCounts() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/app/package.json", age: 60)
        try fixture.file("Projects/app/src/target/platform.rs", age: 0)
        try fixture.file("Projects/app/node_modules/x.js", age: 60)
        let rule = CleanupRule(
            id: "c", name: "c", detail: "", tier: .review, action: .trash, regenerable: true, paths: [],
            find: CleanupRule.Find(
                roots: ["~/Projects"],
                targets: [CleanupRule.Find.Target(name: "node_modules")],
                maxDepth: 4,
                coldDays: 30
            )
        )
        let result = try #require(try await Scanner(home: fixture.home).scan([rule]).first)
        #expect(result.items.isEmpty)
    }
}

struct DeepCleanSafetyRoundSevenTests {
    @Test func pinsInWorktreesAndDeepFoldersCount() throws {
        let fixture = try FixtureHome()
        try fixture.file("Projects/app/.worktrees/feature/.nvmrc").write("20\n")
        try fixture.file("Projects/mono/a/b/c/d/e/f/g/h/.nvmrc").write("18\n")
        let pins = ProjectPins.find(in: [fixture.home.appendingPathComponent("Projects")])
        #expect(Set(pins.node) == ["20", "18"])
        #expect(!pins.incomplete)
    }

    @Test func runningOutOfBudgetMeansIncomplete() throws {
        let fixture = try FixtureHome()
        for index in 0 ..< 5 {
            try fixture.directory("Projects/p\(index)/src")
        }
        let pins = ProjectPins.find(in: [fixture.home.appendingPathComponent("Projects")], budget: 3)
        #expect(pins.incomplete)
    }
}

struct SizeCacheTests {
    private let rule = CleanupRule(
        id: "caches", name: "c", detail: "", tier: .safe, action: .delete, regenerable: true, paths: ["~/Library/Caches/*"]
    )

    @Test func aRecentMeasurementIsReusedForTheSameItem() async throws {
        let fixture = try FixtureHome()
        let blob = try fixture.file("Library/Caches/app/blob", bytes: 100_000)
        let cache = SizeCache(url: fixture.root.appendingPathComponent("sizes.json"))
        let first = try #require(try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 86400).scan([rule]).first)
        try Data(repeating: 1, count: 900_000).write(to: blob) // grows; same folder
        let cached = try #require(try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 86400).scan([rule]).first)
        #expect(cached.totalBytes == first.totalBytes)
        let fresh = try #require(try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 0).scan([rule]).first)
        #expect(fresh.totalBytes > first.totalBytes)
    }

    @Test func aReplacedItemIsMeasuredAgain() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/app/blob", bytes: 100_000)
        let cache = SizeCache(url: nil)
        _ = try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 86400).scan([rule])
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("Library/Caches/app"))
        try fixture.file("Library/Caches/app/other", bytes: 800_000)
        let result = try #require(try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 86400).scan([rule]).first)
        #expect(result.totalBytes >= 800_000)
    }

    @Test func savedEntriesLoadBack() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/app/blob", bytes: 100_000)
        let url = fixture.root.appendingPathComponent("sizes.json")
        let cache = SizeCache(url: url)
        _ = try await Scanner(home: fixture.home, sizeCache: cache, maxCacheAge: 86400).scan([rule])
        cache.save()
        let path = fixture.home.resolvingSymlinksInPath().appendingPathComponent("Library/Caches/app").path
        let reloaded = SizeCache(url: url)
        #expect(try reloaded.lookup(path, identity: #require(FileIdentity(path: path)), maxAge: 86400) != nil)
    }
}

struct SizeCacheExpiryTests {
    @Test func entriesUnusedForAWeekAreDropped() throws {
        let fixture = try FixtureHome()
        let item = try fixture.file("Library/Caches/app/blob").deletingLastPathComponent().resolvingSymlinksInPath()
        let url = fixture.root.appendingPathComponent("sizes.json")
        let cache = SizeCache(url: url)
        let identity = try #require(FileIdentity(path: item.path))
        let long = Date().addingTimeInterval(-8 * 86400)
        cache.store(item.path, identity: identity, usage: DiskUsage.Usage(bytes: 1, newestModification: nil, isComplete: true), now: long)
        cache.save()
        #expect(SizeCache(url: url).lookup(item.path, identity: identity, maxAge: 30 * 86400) == nil)
    }
}
