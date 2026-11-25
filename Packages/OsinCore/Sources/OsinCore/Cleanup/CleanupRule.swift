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

    public var description: String {
        switch self {
        case .deleteNotAllowed: "action 'delete' requires tier 'safe' and regenerable data"
        case .emptyRule: "rule has neither paths nor find"
        case let .pathOutsideHome(path): "path must start with ~/: \(path)"
        case let .parentReference(path): "path must not contain . or .. components: \(path)"
        case let .rootNotGlobbed(path): "last path component must be a glob so the folder itself is kept: \(path)"
        case let .protectedPath(path): "path reaches a protected location: \(path)"
        case .invalidFind: "find needs roots, a plain directory name and a depth of 1-8"
        case let .invalidExclude(pattern): "exclude must be a plain name pattern: \(pattern)"
        }
    }
}

/// A declarative cleanup rule (ADR 0004). Rules hold paths and patterns only, never commands.
public struct CleanupRule: Codable, Sendable, Identifiable, Equatable {
    /// Search for directories with a given name below some roots, e.g. `node_modules` in project folders.
    public struct Find: Codable, Sendable, Equatable {
        public let roots: [String]
        public let directoryName: String
        public let maxDepth: Int

        public init(roots: [String], directoryName: String, maxDepth: Int) {
            self.roots = roots
            self.directoryName = directoryName
            self.maxDepth = maxDepth
        }
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
        find: Find? = nil
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
            let name = find.directoryName
            guard !find.roots.isEmpty, !name.isEmpty, !name.contains("/"), !name.contains("*"), (1 ... 8).contains(find.maxDepth) else {
                throw CleanupRuleError.invalidFind
            }
            for root in find.roots {
                try Self.validate(pattern: root, requireGlob: false)
            }
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
