import Foundation

/// Runs a command-line tool and returns its standard output. Only fixed, Swift-defined commands are run
/// (rules never contain commands; ADR 0004).
enum ProcessRunner {
    struct Failure: Error {
        let status: Int32
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Failure(status: finished.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Simulators whose runtime is no longer installed (`xcrun simctl delete unavailable`).
public enum SimulatorInventory {
    public static func unavailableUDIDs(fromSimctlJSON data: Data) throws -> [String] {
        struct Listing: Decodable {
            struct Device: Decodable {
                let udid: String
            }

            let devices: [String: [Device]]
        }
        return try JSONDecoder().decode(Listing.self, from: data).devices.values.flatMap { $0.map(\.udid) }
    }

    /// True when developer tools are installed. Calling `xcrun` without them pops up an install dialog.
    public static func developerToolsInstalled() async -> Bool {
        await (try? ProcessRunner.run("/usr/bin/xcode-select", ["-p"])) != nil
    }

    /// Size and count of unavailable simulators, or `nil` when developer tools are missing.
    public static func measure(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> (bytes: UInt64, count: Int)? {
        guard await developerToolsInstalled(),
              let data = try? await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
              let udids = try? unavailableUDIDs(fromSimctlJSON: data)
        else { return nil }
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        let bytes = udids.reduce(UInt64(0)) { total, udid in
            total + ((try? DiskUsage.allocatedSize(of: devices.appendingPathComponent(udid))) ?? 0)
        }
        return (bytes, udids.count)
    }

    public static func deleteUnavailable() async throws {
        _ = try await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
    }
}

/// Emptying the Trash. Permanent: offered unchecked with an explicit warning.
public enum EmptyTrash {
    static func trashURL(home: URL) -> URL {
        home.appendingPathComponent(".Trash", isDirectory: true)
    }

    public static func measure(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> UInt64 {
        // One tree, so hard links shared between trashed items are counted once rather than not at all.
        let trash = trashURL(home: home)
        _ = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) // throws if unreadable
        return try DiskUsage.allocatedSize(of: trash)
    }
}

public struct LargeFile: Sendable, Identifiable, Hashable {
    public var id: String {
        url.path
    }

    public let url: URL
    public let bytes: UInt64
    public let modified: Date?
}

/// Large files in the home folder, found with Spotlight. Listed for manual review only.
public enum LargeFileFinder {
    public static let defaultThreshold: UInt64 = 1 << 30

    static func parse(_ output: String) -> [URL] {
        output.split(separator: "\n").filter { !$0.isEmpty }.map { URL(fileURLWithPath: String($0)) }
    }

    public static func find(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        minimumBytes: UInt64 = defaultThreshold,
        limit: Int = 50
    ) async throws -> [LargeFile] {
        let data = try await ProcessRunner.run("/usr/bin/mdfind", ["-onlyin", home.path, "kMDItemFSSize >= \(minimumBytes)"])
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = parse(String(bytes: data, encoding: .utf8) ?? "").compactMap { url -> LargeFile? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize else { return nil }
            return LargeFile(url: url, bytes: UInt64(size), modified: values.contentModificationDate)
        }
        return Array(files.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
