import Foundation

/// Runs a command-line tool and returns its standard output. Only fixed, Swift-defined commands are run
/// (rules never contain commands; ADR 0004).
enum ProcessRunner {
    struct Failure: Error {
        let status: Int32
    }

    /// Output read on another thread; guarded by a lock.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ data: Data) {
            lock.lock()
            stored = data
            lock.unlock()
        }
    }

    /// Homebrew folders first, so tools that call helpers (colima calls limactl) find them.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Runs the tool and returns its output. With a `timeout`, a tool that hangs (a Docker daemon that
    /// never answers) gets SIGTERM, then SIGKILL five seconds later, and the call fails.
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval? = nil, environment overrides: [String: String?] = [:]
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            for (key, value) in overrides {
                environment[key] = value
            }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // Read while the tool runs: a pipe holds only 64 KB, and a tool writing more would block forever.
            let collected = Collected()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global(qos: .utility).async {
                collected.set(output.fileHandleForReading.readDataToEndOfFile())
                reading.leave()
            }
            process.terminationHandler = { finished in
                // A helper the tool started may still hold the pipe open: don't wait for it forever.
                let drained = reading.wait(timeout: .now() + 5) == .success
                if drained, finished.terminationStatus == 0, finished.terminationReason == .exit {
                    continuation.resume(returning: collected.data)
                } else {
                    continuation.resume(throwing: Failure(status: finished.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                // Ends the reader: nothing will ever write to the pipe.
                try? output.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }
            if let timeout {
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { @Sendable in
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { @Sendable in
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
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
