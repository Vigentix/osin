import Foundation

/// Docker's reclaimable space, read and cleaned through the official `docker` command (never by touching
/// its files). Only used when the command exists and the daemon answers.
public enum DockerInventory {
    public struct Image: Sendable, Hashable, Identifiable {
        public let id: String
        public let bytes: UInt64
    }

    public struct Volume: Sendable, Hashable, Identifiable {
        public var id: String {
            name
        }

        public let name: String
        public let bytes: UInt64
    }

    public struct Usage: Sendable, Equatable {
        /// Build cache not used by any build in progress (`docker builder prune`).
        public let buildCacheBytes: UInt64
        /// Untagged images no container uses.
        public let danglingImages: [Image]
        /// Volumes no container (running or stopped) refers to.
        public let unusedVolumes: [Volume]
    }

    /// Known install locations (Homebrew, Docker Desktop, OrbStack). PATH is not consulted: apps
    /// started from Finder get a minimal one.
    public static func candidatePaths(home: URL) -> [String] {
        [
            "/opt/homebrew/bin/docker", "/usr/local/bin/docker",
            home.appendingPathComponent(".docker/bin/docker").path,
            home.appendingPathComponent(".orbstack/bin/docker").path,
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
    }

    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        candidatePaths(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Docker prints decimal units (go-units): "262.9MB", "28.67kB", "0B".
    static func bytes(_ text: String) -> UInt64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)), value >= 0 else { return nil }
            return UInt64((value * factor).rounded())
        }
        return nil
    }

    /// Parses `docker system df -v --format '{{json .}}'`.
    static func parse(systemDF data: Data) throws -> Usage {
        let report = try JSONDecoder().decode(DockerSystemDF.self, from: data)
        let images = (report.images ?? []).filter { row in
            row.repository?.text == "<none>" && (row.containers?.text ?? "0") == "0"
        }.map { Image(id: $0.identifier, bytes: $0.size.flatMap { bytes($0.text) } ?? 0) }
        let volumes = (report.volumes ?? []).filter { $0.links?.text == "0" }
            .map { Volume(name: $0.name, bytes: $0.size.flatMap { bytes($0.text) } ?? 0) }
        let cache = (report.buildCache ?? []).filter { $0.inUse?.text != "true" && $0.shared?.text != "true" }
            .reduce(UInt64(0)) { $0 + ($1.size.flatMap { bytes($0.text) } ?? 0) }
        return Usage(buildCacheBytes: cache, danglingImages: images, unusedVolumes: volumes)
    }

    /// `nil` when Docker is not installed or its daemon is not running.
    public static func measure() async -> Usage? {
        guard let docker = executable(), let data = try? await ProcessRunner.run(
            docker,
            ["system", "df", "-v", "--format", "{{json .}}"],
            timeout: 30
        ) else {
            return nil
        }
        return try? parse(systemDF: data)
    }

    public static func pruneBuildCache() async throws {
        guard let docker = executable() else { throw ProcessRunner.Failure(status: -1) }
        _ = try await ProcessRunner.run(docker, ["builder", "prune", "--force"], timeout: 600)
    }

    public static func removeImages(_ ids: [String]) async throws {
        guard let docker = executable(), !ids.isEmpty else { return }
        _ = try await ProcessRunner.run(docker, ["image", "rm"] + ids, timeout: 600)
    }

    public static func removeVolumes(_ names: [String]) async throws {
        guard let docker = executable(), !names.isEmpty else { return }
        _ = try await ProcessRunner.run(docker, ["volume", "rm"] + names, timeout: 600)
    }
}

/// Colima keeps Docker's data in a virtual disk that does not shrink by itself after a prune; `fstrim`
/// inside the VM hands freed blocks back to macOS.
public enum ColimaDisk {
    static func executable() -> String? {
        ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool {
        executable() != nil
    }

    public static func trim() async throws {
        guard let colima = executable() else { throw ProcessRunner.Failure(status: -1) }
        _ = try await ProcessRunner.run(colima, ["ssh", "--", "sudo", "fstrim", "-a"], timeout: 600)
    }
}

/// Decodes a field Docker may print as a string or as a JSON bool/number.
private struct Loose: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let bool = try? container.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else {
            text = try String(container.decode(Int.self))
        }
    }
}

/// `docker system df -v` rows. The JSON keys are Docker's (capitalised).
private struct DockerImageRow: Decodable {
    let identifier: String
    let repository: Loose?
    let size: Loose?
    let containers: Loose?

    enum CodingKeys: String, CodingKey {
        case identifier = "ID", repository = "Repository", size = "Size", containers = "Containers"
    }
}

private struct DockerVolumeRow: Decodable {
    let name: String
    let links: Loose?
    let size: Loose?

    enum CodingKeys: String, CodingKey {
        case name = "Name", links = "Links", size = "Size"
    }
}

private struct DockerCacheRow: Decodable {
    let inUse: Loose?
    let shared: Loose?
    let size: Loose?

    enum CodingKeys: String, CodingKey {
        case inUse = "InUse", shared = "Shared", size = "Size"
    }
}

private struct DockerSystemDF: Decodable {
    let images: [DockerImageRow]?
    let volumes: [DockerVolumeRow]?
    let buildCache: [DockerCacheRow]?

    enum CodingKeys: String, CodingKey {
        case images = "Images", volumes = "Volumes", buildCache = "BuildCache"
    }
}
