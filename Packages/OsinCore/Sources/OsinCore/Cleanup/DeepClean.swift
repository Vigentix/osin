import Darwin
import Foundation

/// Which apps are running, by bundle name (`Google Chrome.app`), read from process paths.
public enum AppActivity {
    /// The outermost `.app` of each executable path, so helpers count as their app.
    static func appNames(fromExecutablePaths paths: [String]) -> Set<String> {
        Set(paths.compactMap { path in
            path.split(separator: "/").first { $0.hasSuffix(".app") }.map(String.init)
        })
    }

    @Sendable public static func runningAppNames() -> Set<String> {
        appNames(fromExecutablePaths: ProcessReader.readAll().compactMap(\.executablePath))
    }
}

/// Project folders: the usual places plus the user's own, only real folders inside home that are not
/// protected (a `~/Projects` linked into `~/Documents` is ignored, so no privacy prompt appears).
public enum ProjectRoots {
    public static func all(home: URL, extra: [URL]) -> [URL] {
        let protected = ProtectedPaths(home: home)
        let defaults = Scanner.defaultProjectRoots.map { home.appendingPathComponent($0) }
        var seen = Set<String>()
        return (defaults + extra).compactMap { url -> URL? in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard resolved.path.hasPrefix(home.path + "/"), !protected.denies(resolved),
                  FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(resolved.path).inserted
            else { return nil }
            return resolved
        }
    }
}

/// Whether a project is still in use: a recent commit, checkout or staging, or a recently edited file
/// anywhere in its sources. When that cannot be told for sure, the project counts as in use.
enum ProjectActivity {
    /// Folders tools regenerate; their dates say nothing about whether the project is worked on.
    static let generated: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".nuxt", ".turbo", "Pods", ".gradle",
        "build", "dist", ".cache", ".git", "DerivedData", ".build", "__pycache__", ".pytest_cache"
    ]

    /// Git files that change when someone commits, checks out or stages (not on a background fetch).
    private static let gitMarkers = ["logs/HEAD", "index", "HEAD", "ORIG_HEAD"]
    /// Files looked at per project before giving up (and keeping it).
    static let fileBudget = 25000

    static func isActive(project: URL, target: URL, within root: URL, since cutoff: Date) -> Bool {
        var budget = fileBudget
        switch newestFile(in: project, skipping: target.lastPathComponent, budget: &budget) {
        case .unknown: return true
        case let .newest(date): if date.map({ $0 > cutoff }) ?? false {
                return true
            }
        }
        // The repository may start above the project (a package in a monorepo).
        var directory = project
        while directory.path.hasPrefix(root.path) {
            let git = directory.appendingPathComponent(".git")
            if let metadata = gitDirectory(git, in: directory) {
                return gitMarkers.contains { marker in
                    modified(metadata.appendingPathComponent(marker)).map { $0 > cutoff } ?? false
                }
            } else if FileManager.default.fileExists(atPath: git.path) {
                return true // a .git we cannot follow: keep the project
            }
            guard directory.path != root.path else { break }
            directory.deleteLastPathComponent()
        }
        return false
    }

    /// The repository's metadata folder: `.git` itself, or where a `.git` file (worktree, submodule) points.
    static func gitDirectory(_ git: URL, in directory: URL) -> URL? {
        var info = stat()
        guard lstat(git.path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFDIR {
            return git
        }
        guard info.st_mode & S_IFMT == S_IFREG, let text = try? String(contentsOf: git, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return target.standardizedFileURL
    }

    private static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    enum Newest {
        case newest(Date?)
        case unknown
    }

    /// Newest file (not folder: a folder's date moves when anything is added) in the project's sources.
    private static func newestFile(in directory: URL, skipping skipped: String, budget: inout Int) -> Newest {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return .unknown }
        var newest: Date?
        for name in names where name != skipped && !generated.contains(name) {
            budget -= 1
            guard budget > 0 else { return .unknown }
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                switch newestFile(in: url, skipping: skipped, budget: &budget) {
                case .unknown: return .unknown
                case let .newest(inner): if let inner {
                        newest = max(newest ?? inner, inner)
                    }
                }
            } else if type == S_IFREG {
                let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                newest = max(newest ?? date, date)
            }
        }
        return .newest(newest)
    }
}

/// Toolchain versions still in use: the default and any version a project pins. When a tool's default
/// cannot be worked out offline, all of its versions are kept.
enum ToolchainUsage {
    static func keptPaths(home: URL, projectRoots: [URL]) -> Set<String> {
        let pins = ProjectPins.find(in: projectRoots)
        var kept = Set<String>()
        kept.formUnion(node(home: home, pins: pins.node))
        kept.formUnion(python(home: home, pins: pins.python))
        kept.formUnion(rust(home: home, pins: pins.rust))
        return kept
    }

    private static func directories(_ url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { url.appendingPathComponent($0).standardizedFileURL }
    }

    private static func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Numeric version components ("v22.3.1" → [22, 3, 1]); nil if not a plain version.
    static func components(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap(\.self)
    }

    /// The highest available version starting with `prefix` ("22" matches 22.x.y).
    static func highest(matching prefix: [Int], in versions: [String]) -> String? {
        versions
            .compactMap { name in components(name).map { (name, $0) } }
            .filter { Array($0.1.prefix(prefix.count)) == prefix }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    // MARK: nvm

    private static func node(home: URL, pins: [String]) -> [String] {
        let root = home.appendingPathComponent(".nvm/versions/node")
        let installed = directories(root)
        guard !installed.isEmpty else { return [] }
        let names = installed.map(\.lastPathComponent)
        var keep: [String] = []
        guard let defaultSpec = read(home.appendingPathComponent(".nvm/alias/default")),
              let defaultVersion = resolveNode(defaultSpec, home: home, names: names, depth: 0)
        else { return installed.map(\.path) }
        keep.append(defaultVersion)
        for pin in pins {
            // A plain version that is not installed protects nothing; anything else we can't resolve keeps all.
            if let prefix = components(pin), highest(matching: prefix, in: names) == nil {
                continue
            }
            guard let version = resolveNode(pin, home: home, names: names, depth: 0) else { return installed.map(\.path) }
            keep.append(version)
        }
        return keep.map { root.appendingPathComponent($0).standardizedFileURL.path }
    }

    private static func resolveNode(_ spec: String, home: URL, names: [String], depth: Int) -> String? {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["node", "stable", "latest", "current"].contains(spec) {
            return highest(matching: [], in: names)
        }
        if let prefix = components(spec) {
            return highest(matching: prefix, in: names)
        }
        // Another alias (lts/* needs the network: unresolved).
        guard depth < 2, !spec.contains("/"), !spec.contains("*"),
              let next = read(home.appendingPathComponent(".nvm/alias").appendingPathComponent(spec))
        else { return nil }
        return resolveNode(next, home: home, names: names, depth: depth + 1)
    }

    // MARK: pyenv

    private static func python(home: URL, pins: [String]) -> [String] {
        let root = home.appendingPathComponent(".pyenv/versions")
        let installed = directories(root)
        guard !installed.isEmpty else { return [] }
        let names = installed.map(\.lastPathComponent)
        guard let global = read(home.appendingPathComponent(".pyenv/version")) else { return installed.map(\.path) }
        var keep: [String] = []
        for spec in global.split(whereSeparator: \.isNewline).map(String.init) + pins {
            let spec = spec.trimmingCharacters(in: .whitespaces)
            guard !spec.isEmpty, spec != "system" else { continue }
            if names.contains(spec) {
                keep.append(spec)
            } else if let prefix = components(spec) {
                // A version that is not installed protects nothing.
                if let match = highest(matching: prefix, in: names) {
                    keep.append(match)
                }
            } else {
                return installed.map(\.path) // a virtualenv or alias name: keep everything
            }
        }
        // A virtualenv (versions/myenv → versions/3.12.8/envs/myenv) also keeps the Python it lives in.
        var paths = Set(keep.map { root.appendingPathComponent($0).standardizedFileURL.path })
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        for name in keep {
            let resolved = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedRoot + "/"),
                  let owner = resolved.dropFirst(resolvedRoot.count + 1).split(separator: "/").first
            else { continue }
            paths.insert(root.appendingPathComponent(String(owner)).standardizedFileURL.path)
        }
        return Array(paths)
    }

    // MARK: rustup

    private static func rust(home: URL, pins: [String]) -> [String] {
        let root = home.appendingPathComponent(".rustup/toolchains")
        let installed = directories(root)
        guard !installed.isEmpty else { return [] }
        guard let settings = read(home.appendingPathComponent(".rustup/settings.toml")) else { return installed.map(\.path) }
        var wanted: [String] = []
        var inOverrides = false
        for line in settings.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inOverrides = line == "[overrides]"
                continue
            }
            guard let value = tomlString(line) else { continue }
            if inOverrides || line.hasPrefix("default_toolchain") {
                wanted.append(value)
            }
        }
        guard !wanted.isEmpty else { return installed.map(\.path) }
        wanted += pins
        return installed.filter { url in
            wanted.contains { url.lastPathComponent == $0 || url.lastPathComponent.hasPrefix($0 + "-") }
        }.map(\.path)
    }

    /// The quoted value of a `key = "value"` line.
    static func tomlString(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }
}

/// Version files in projects: `.nvmrc`, `.node-version`, `.python-version`, `rust-toolchain(.toml)`.
enum ProjectPins {
    struct Pins {
        var node: [String] = []
        var python: [String] = []
        var rust: [String] = []
    }

    /// As deep as cold-project discovery looks (5), plus one for the pin file itself.
    static func find(in roots: [URL], depth: Int = 6) -> Pins {
        var pins = Pins()
        for root in roots {
            visit(root, depth: depth, into: &pins)
        }
        return pins
    }

    private static func visit(_ directory: URL, depth: Int, into pins: inout Pins) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if record(name, at: url, into: &pins) {
                continue
            }
            var info = stat()
            // Real folders only (no symlinks), not hidden or generated ones.
            guard depth > 1, !name.hasPrefix("."), !ProjectActivity.generated.contains(name),
                  lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
            else { continue }
            visit(url, depth: depth - 1, into: &pins)
        }
    }

    /// Reads `url` if `name` is a version file. Returns whether it was one.
    private static func record(_ name: String, at url: URL, into pins: inout Pins) -> Bool {
        switch name {
        case ".nvmrc", ".node-version":
            pins.node += firstLine(url).map { [$0] } ?? []
        case ".python-version":
            pins.python += lines(url)
        case "rust-toolchain.toml":
            pins.rust += lines(url).filter { $0.hasPrefix("channel") }.compactMap(ToolchainUsage.tomlString)
        case "rust-toolchain":
            pins.rust += firstLine(url).map { [$0] } ?? []
        default:
            return false
        }
        return true
    }

    private static func lines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }
}
