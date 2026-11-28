import Foundation

public enum CleanupTier: String, Codable, Sendable {
    /// Pre-selected. Regenerable data only.
    case safe
    /// Shown but not selected; the user decides.
    case review
}

public enum CleanupAction: String, Codable, Sendable {
    /// Permanent removal. Only for regenerable data in the safe tier (ADR 0003).
    case delete
    /// Move to the Trash; restorable.
    case trash
}

public enum CleanupRuleError: Error, Equatable, CustomStringConvertible {
    case deleteNotAllowed
    case emptyRule
    case pathOutsideHome(String)
    case parentReference(String)
    case rootNotGlobbed(String)
    case protectedPath(String)
    case invalidFind
    case invalidExclude(String)
    case invalidClosedApp(String)

    public var description: String {
        switch self {
        case .deleteNotAllowed: "action 'delete' requires tier 'safe' and regenerable data"
        case .emptyRule: "rule has neither paths nor find"
        case let .pathOutsideHome(path): "path must start with ~/: \(path)"
        case let .parentReference(path): "path must not contain . or .. components: \(path)"
        case let .rootNotGlobbed(path): "last path component must be a glob so the folder itself is kept: \(path)"
        case let .protectedPath(path): "path reaches a protected location: \(path)"
        case .invalidFind: "find needs roots, plain directory names (markers: a plain name), a depth of 1-8 and coldDays of 1-365"
        case let .invalidExclude(pattern): "exclude must be a plain name pattern: \(pattern)"
        case let .invalidClosedApp(app): "closedApps needs an app name ending in .app and a folder in the home folder: \(app)"
        }
    }
}

/// A declarative cleanup rule (ADR 0004). Rules hold paths and patterns only, never commands.
public struct CleanupRule: Codable, Sendable, Identifiable, Equatable {
    /// Search for directories with given names below some roots, e.g. `node_modules` in project folders.
    public struct Find: Codable, Sendable, Equatable {
        /// A directory name to look for, optionally confirmed by a marker so a folder that merely shares
        /// the name is left alone (`target` only next to a `Cargo.toml`).
        public struct Target: Codable, Sendable, Equatable {
            public let name: String
            /// A file that must exist inside the directory (`.venv` holds `pyvenv.cfg`).
            public let inside: String?
            /// A file that must exist next to it; may be a name pattern (`settings.gradle*`).
            public let sibling: String?

            public init(name: String, inside: String? = nil, sibling: String? = nil) {
                self.name = name
                self.inside = inside
                self.sibling = sibling
            }
        }

        public let roots: [String]
        public let targets: [Target]
        public let maxDepth: Int
        /// Only offer directories of projects with no activity (git or file changes) for this many days.
        public let coldDays: Int?
        /// Also search the project folders the user added in Settings.
        public let includeProjectRoots: Bool

        public init(roots: [String], targets: [Target], maxDepth: Int, coldDays: Int? = nil, includeProjectRoots: Bool = false) {
            self.roots = roots
            self.targets = targets
            self.maxDepth = maxDepth
            self.coldDays = coldDays
            self.includeProjectRoots = includeProjectRoots
        }

        /// The original single-name form.
        public init(roots: [String], directoryName: String, maxDepth: Int) {
            self.init(roots: roots, targets: [Target(name: directoryName)], maxDepth: maxDepth)
        }

        private enum CodingKeys: String, CodingKey {
            case roots, targets, directoryName, maxDepth, coldDays, includeProjectRoots
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            roots = try container.decode([String].self, forKey: .roots)
            if let targets = try container.decodeIfPresent([Target].self, forKey: .targets) {
                self.targets = targets
            } else {
                targets = try [Target(name: container.decode(String.self, forKey: .directoryName))]
            }
            maxDepth = try container.decode(Int.self, forKey: .maxDepth)
            coldDays = try container.decodeIfPresent(Int.self, forKey: .coldDays)
            includeProjectRoots = try container.decodeIfPresent(Bool.self, forKey: .includeProjectRoots) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(roots, forKey: .roots)
            try container.encode(targets, forKey: .targets)
            try container.encode(maxDepth, forKey: .maxDepth)
            try container.encodeIfPresent(coldDays, forKey: .coldDays)
            try container.encode(includeProjectRoots, forKey: .includeProjectRoots)
        }
    }

    /// Items under `folder` belong to `app`, which must be closed before they are cleaned (a browser
    /// rewrites its caches while it runs).
    public struct ClosedApp: Codable, Sendable, Equatable {
        /// Bundle name, e.g. `Google Chrome.app`.
        public let app: String
        /// `~/`-relative folder the app owns.
        public let folder: String

        public init(app: String, folder: String) {
            self.app = app
            self.folder = folder
        }

        public var displayName: String {
            String(app.dropLast(4))
        }
    }

    /// Rule-specific logic beyond paths and patterns, implemented in Swift.
    public enum Special: String, Codable, Sendable {
        /// Keep toolchain versions that a default or a project still uses (nvm, pyenv, rustup).
        case unusedToolchains
    }

    public let id: String
    public let name: String
    public let detail: String
    public let tier: CleanupTier
    public let action: CleanupAction
    public let regenerable: Bool
    /// `~/`-relative patterns. `*` is allowed in any component and required in the last one.
    public let paths: [String]
    /// Name patterns (last path component) never matched, e.g. `com.apple.*`.
    public let excludes: [String]
    public let minAgeDays: Int?
    public let requiresFullDiskAccess: Bool
    public let find: Find?
    public let closedApps: [ClosedApp]
    public let special: Special?

    public init(
        id: String,
        name: String,
        detail: String,
        tier: CleanupTier,
        action: CleanupAction,
        regenerable: Bool,
        paths: [String],
        excludes: [String] = [],
        minAgeDays: Int? = nil,
        requiresFullDiskAccess: Bool = false,
        find: Find? = nil,
        closedApps: [ClosedApp] = [],
        special: Special? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.tier = tier
        self.action = action
        self.regenerable = regenerable
        self.paths = paths
        self.excludes = excludes
        self.minAgeDays = minAgeDays
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.find = find
        self.closedApps = closedApps
        self.special = special
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decode(String.self, forKey: .detail)
        tier = try container.decode(CleanupTier.self, forKey: .tier)
        action = try container.decode(CleanupAction.self, forKey: .action)
        regenerable = try container.decode(Bool.self, forKey: .regenerable)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        excludes = try container.decodeIfPresent([String].self, forKey: .excludes) ?? []
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
        requiresFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .requiresFullDiskAccess) ?? false
        find = try container.decodeIfPresent(Find.self, forKey: .find)
        closedApps = try container.decodeIfPresent([ClosedApp].self, forKey: .closedApps) ?? []
        special = try container.decodeIfPresent(Special.self, forKey: .special)
    }

    /// The app that must be closed before `url` is cleaned, if any.
    func closedApp(for url: URL, home: URL) -> ClosedApp? {
        closedApps.first { entry in
            let folder = home.appendingPathComponent(String(entry.folder.dropFirst(2))).standardizedFileURL.path
            return url.standardizedFileURL.path.hasPrefix(folder + "/")
        }
    }

    // MARK: Validation

    public func validate() throws {
        if action == .delete, tier != .safe || !regenerable {
            throw CleanupRuleError.deleteNotAllowed
        }
        if paths.isEmpty, find == nil {
            throw CleanupRuleError.emptyRule
        }
        for path in paths {
            try Self.validate(pattern: path, requireGlob: true)
        }
        for pattern in excludes where pattern.isEmpty || pattern.contains("/") {
            throw CleanupRuleError.invalidExclude(pattern)
        }
        if let find {
            try Self.validate(find)
        }
        for entry in closedApps {
            guard entry.app.hasSuffix(".app"), entry.app.count > 4, !entry.app.contains("/") else {
                throw CleanupRuleError.invalidClosedApp(entry.app)
            }
            do {
                try Self.validate(pattern: entry.folder, requireGlob: false)
            } catch {
                throw CleanupRuleError.invalidClosedApp(entry.app)
            }
        }
    }

    private static func isPlainName(_ name: String?, allowGlob: Bool) -> Bool {
        guard let name else { return true }
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".." && (allowGlob || !name.contains("*"))
    }

    static func validate(_ find: Find) throws {
        guard !find.roots.isEmpty, !find.targets.isEmpty, (1 ... 8).contains(find.maxDepth),
              find.coldDays.map({ (1 ... 365).contains($0) }) ?? true,
              find.targets.allSatisfy({ isPlainName($0.name, allowGlob: false) && isPlainName($0.inside, allowGlob: false)
                      && isPlainName($0.sibling, allowGlob: true) })
        else {
            throw CleanupRuleError.invalidFind
        }
        for root in find.roots {
            try validate(pattern: root, requireGlob: false)
        }
    }

    static func validate(pattern: String, requireGlob: Bool) throws {
        guard pattern.hasPrefix("~/") else { throw CleanupRuleError.pathOutsideHome(pattern) }
        let components = pattern.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CleanupRuleError.parentReference(pattern)
        }
        if requireGlob, components.last?.contains("*") != true {
            throw CleanupRuleError.rootNotGlobbed(pattern)
        }
        // The fixed part before the first glob must not be, contain, or sit inside a protected location.
        let home = URL(fileURLWithPath: "/Users/__osin_validation__", isDirectory: true)
        let fixed = components.prefix { !$0.contains("*") }
        let fixedURL = fixed.reduce(home) { $0.appendingPathComponent(String($1)) }
        if ProtectedPaths(home: home).denies(fixedURL) {
            throw CleanupRuleError.protectedPath(pattern)
        }
    }

    // MARK: Bundled rules

    /// The rules shipped with Osin, in evaluation order (earlier rules claim items first).
    public static func bundled() throws -> [CleanupRule] {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json", subdirectory: "Rules") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([CleanupRule].self, from: Data(contentsOf: url))
    }
}
