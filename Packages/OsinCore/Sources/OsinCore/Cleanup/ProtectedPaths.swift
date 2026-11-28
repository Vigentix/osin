import Foundation

/// The global deny-list (PRD §6.4, "Never" tier). Applied after every rule match.
///
/// A path is denied when it is a protected location, inside one, or an ancestor of one
/// (removing `~/Library` would take `~/Library/Mail` with it). Callers pass symlink-resolved paths.
public struct ProtectedPaths: Sendable {
    public let home: URL
    public let roots: [String]
    /// APFS is usually case-insensitive: `~/documents` is `~/Documents`, so comparisons ignore case.
    private let foldedRoots: [String]
    private let foldedHome: String

    static let homeRelative = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", "Public",
        "Library/Mail", "Library/Mobile Documents", "Library/Messages", "Library/Keychains",
        "Library/Application Support/AddressBook", "Library/Calendars", "Library/Photos",
        "Library/Group Containers/group.com.apple.notes", "Library/Safari",
        ".ssh", ".gnupg", ".Trash"
    ]

    static let system = ["/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/opt", "/etc"]

    public init(home: URL) {
        self.home = home
        let homePath = home.standardizedFileURL.path
        roots = Self.homeRelative.map { homePath + "/" + $0 } + Self.system
        foldedRoots = roots.map { $0.lowercased() }
        foldedHome = homePath.lowercased()
    }

    public func denies(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        if path == foldedHome {
            return true
        }
        let ancestorPrefix = path == "/" ? "/" : path + "/"
        return foldedRoots.contains { root in
            path == root || path.hasPrefix(root + "/") || root.hasPrefix(ancestorPrefix)
        }
    }
}
