import Foundation

/// Best-effort check for Full Disk Access. macOS has no API for this, so Osin probes locations
/// that only become readable once access is granted.
public enum FullDiskAccess {
    public static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let probes = [
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.apple.stocks", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe.path) {
            return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
        }
        return false
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
