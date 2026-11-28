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

/// Whether a project is still in use: a recent commit or checkout, or a recently edited file.
enum ProjectActivity {
    /// Folders tools regenerate; their dates say nothing about whether the project is worked on.
    static let generated: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".nuxt", ".turbo", "Pods", ".gradle",
        "build", "dist", ".cache", ".git", "DerivedData", ".build", "__pycache__", ".pytest_cache"
    ]

    /// Git files that change when someone commits, checks out or stages (not on a background fetch).
    private static let gitMarkers = ["logs/HEAD", "index", "HEAD", "ORIG_HEAD"]

    static func isActive(project: URL, target: URL, within root: URL, since cutoff: Date) -> Bool {
        if newestFile(in: project, depth: 2, skipping: target.lastPathComponent).map({ $0 > cutoff }) ?? false {
            return true
        }
        // The repository may start above the project (a package in a monorepo).
        var directory = project
        while directory.path.hasPrefix(root.path) {
            let git = directory.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) {
                return gitMarkers.contains { marker in
                    modified(git.appendingPathComponent(marker)).map { $0 > cutoff } ?? false
                }
            }
            guard directory.path != root.path else { break }
            directory.deleteLastPathComponent()
        }
        return false
    }

    private static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Newest file (not folder: a folder's date moves when anything is added) up to `depth` levels down.
    private static func newestFile(in directory: URL, depth: Int, skipping skipped: String) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var newest: Date?
        for name in names where name != skipped && !generated.contains(name) {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                if depth > 1, !name.hasPrefix("."), let inner = newestFile(in: url, depth: depth - 1, skipping: skipped) {
                    newest = max(newest ?? inner, inner)
                }
            } else if type == S_IFREG {
                let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                newest = max(newest ?? date, date)
            }
        }
        return newest
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
        return keep.map { root.appendingPathComponent($0).standardizedFileURL.path }
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

    static func find(in roots: [URL], depth: Int = 3) -> Pins {
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
