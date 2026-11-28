import Foundation

/// Docker's reclaimable space, read and cleaned through the official `docker` command (never by touching
/// its files). Only used when the command exists and the daemon answers.
public enum DockerInventory {
    public struct Image: Sendable, Hashable, Identifiable {
        public let id: String
        public let bytes: UInt64

        public init(id: String, bytes: UInt64) {
            self.id = id
            self.bytes = bytes
        }
    }

    public struct Volume: Sendable, Hashable, Identifiable {
        public var id: String {
            name
        }

        public let name: String
        public let bytes: UInt64
        /// When Docker created it; a volume recreated under the same name since the scan is not removed.
        public let createdAt: String?

        public init(name: String, bytes: UInt64, createdAt: String? = nil) {
            self.name = name
            self.bytes = bytes
            self.createdAt = createdAt
        }
    }

    public struct Usage: Sendable, Equatable {
        /// Build cache not used by any build in progress (`docker builder prune`).
        public let buildCacheBytes: UInt64
        /// Untagged images no container uses.
        public let danglingImages: [Image]
        /// Volumes no container (running or stopped) refers to.
        public let unusedVolumes: [Volume]
        /// The local daemon these were read from; cleaning talks to the same one, never another context.
        public let host: String

        public init(buildCacheBytes: UInt64, danglingImages: [Image], unusedVolumes: [Volume], host: String = "") {
            self.host = host
            self.buildCacheBytes = buildCacheBytes
            self.danglingImages = danglingImages
            self.unusedVolumes = unusedVolumes
        }
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

    /// The current context's daemon, if it runs on this Mac (a `unix://` socket). Remote daemons (ssh,
    /// tcp) are never cleaned from here.
    static func localHost(fromContextInspect data: Data) -> String? {
        guard let contexts = try? JSONDecoder().decode([DockerContext].self, from: data),
              let host = contexts.first?.endpoints.docker.host, host.hasPrefix("unix://")
        else { return nil }
        return host
    }

    static func currentLocalHost(docker: String) async -> String? {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"] {
            return host.hasPrefix("unix://") ? host : nil
        }
        guard let data = try? await ProcessRunner.run(docker, ["context", "inspect"], timeout: 15) else { return nil }
        return localHost(fromContextInspect: data)
    }

    /// Whether two image IDs name the same image, whatever length and prefix Docker printed them with.
    static func sameImage(_ first: String, _ second: String) -> Bool {
        let shortFirst = first.replacingOccurrences(of: "sha256:", with: "")
        let shortSecond = second.replacingOccurrences(of: "sha256:", with: "")
        let length = min(shortFirst.count, shortSecond.count, 64)
        return length >= 12 && shortFirst.prefix(length) == shortSecond.prefix(length)
    }

    /// Images Docker itself calls dangling (untagged and unreferenced); `system df` alone can't tell
    /// a digest-only image from one.
    static func danglingIDs(docker: String, host: String) async -> [String]? {
        guard let data = try? await ProcessRunner.run(
            docker, ["-H", host, "image", "ls", "--filter", "dangling=true", "--no-trunc", "--format", "{{.ID}}"], timeout: 30
        ), let text = String(bytes: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `nil` when Docker is not installed, its daemon is not running, or it is not on this Mac.
    public static func measure() async -> Usage? {
        guard let docker = executable(), let host = await currentLocalHost(docker: docker),
              let data = try? await ProcessRunner.run(docker, ["-H", host, "system", "df", "-v", "--format", "{{json .}}"], timeout: 30),
              let usage = try? parse(systemDF: data)
        else { return nil }
        let dangling = await danglingIDs(docker: docker, host: host) ?? []
        let images = usage.danglingImages.filter { image in dangling.contains { sameImage($0, image.id) } }
        let created = await creationDates(usage.unusedVolumes.map(\.name), docker: docker, host: host)
        let volumes = usage.unusedVolumes.compactMap { volume in
            created[volume.name].map { Volume(name: volume.name, bytes: volume.bytes, createdAt: $0) }
        }
        return Usage(buildCacheBytes: usage.buildCacheBytes, danglingImages: images, unusedVolumes: volumes, host: host)
    }

    /// `docker volume inspect` creation dates by name (volumes that can't be inspected are left out).
    static func creationDates(_ names: [String], docker: String, host: String) async -> [String: String] {
        guard !names.isEmpty, let data = try? await ProcessRunner.run(
            docker, ["-H", host, "volume", "inspect", "--format", "{{.Name}}\t{{.CreatedAt}}"] + names, timeout: 30
        ), let text = String(bytes: data, encoding: .utf8) else { return [:] }
        return parseCreationDates(text)
    }

    static func parseCreationDates(_ text: String) -> [String: String] {
        text.split(whereSeparator: \.isNewline).reduce(into: [:]) { dates, line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[1].isEmpty {
                dates[parts[0]] = parts[1]
            }
        }
    }

    /// Every cleaning command names the daemon that was measured, so a context switch in between
    /// cannot point it at another (possibly remote) Docker.
    private static func run(_ arguments: [String], host: String) async throws {
        guard let docker = executable(), host.hasPrefix("unix://") else { throw ProcessRunner.Failure(status: -1) }
        _ = try await ProcessRunner.run(docker, ["-H", host] + arguments, timeout: 600)
    }

    /// Prunes the measured daemon's own build cache: its default builder, picked explicitly, so a
    /// remote builder chosen elsewhere (BUILDX_BUILDER, `docker buildx use`) is never touched.
    public static func pruneBuildCache(host: String) async throws {
        guard let docker = executable(), host.hasPrefix("unix://") else { throw ProcessRunner.Failure(status: -1) }
        let pinned: [String: String?] = ["DOCKER_HOST": host, "DOCKER_CONTEXT": nil, "BUILDX_BUILDER": nil]
        do {
            _ = try await ProcessRunner.run(
                docker,
                ["buildx", "prune", "--builder", "default", "--force"],
                timeout: 600,
                environment: pinned
            )
        } catch {
            // No buildx plugin (plain Homebrew Docker with Colima): the classic builder prune, which with
            // DOCKER_BUILDKIT=0 talks to the daemon directly instead of forwarding to buildx.
            var classic = pinned
            classic["DOCKER_BUILDKIT"] = "0"
            _ = try await ProcessRunner.run(docker, ["-H", host, "builder", "prune", "--force"], timeout: 600, environment: classic)
        }
    }

    /// Removes only images that are still dangling now.
    public static func removeImages(_ ids: [String], host: String) async throws {
        guard let docker = executable(), let dangling = await danglingIDs(docker: docker, host: host) else {
            throw ProcessRunner.Failure(status: -1)
        }
        let still = ids.filter { id in dangling.contains { sameImage($0, id) } }
        guard !still.isEmpty else { return }
        try await run(["image", "rm"] + still, host: host)
    }

    /// Removes only volumes that are still the ones scanned (same creation date).
    public static func removeVolumes(_ volumes: [Volume], host: String) async throws {
        guard !volumes.isEmpty else { return }
        guard let docker = executable() else { throw ProcessRunner.Failure(status: -1) }
        let now = await creationDates(volumes.map(\.name), docker: docker, host: host)
        let unchanged = volumes.filter { volume in volume.createdAt != nil && now[volume.name] == volume.createdAt }
        guard !unchanged.isEmpty else { return }
        try await run(["volume", "rm"] + unchanged.map(\.name), host: host)
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

/// `docker context inspect` output: the endpoint of the current context.
private struct DockerContext: Decodable {
    struct Endpoint: Decodable {
        let host: String

        enum CodingKeys: String, CodingKey {
            case host = "Host"
        }
    }

    struct Endpoints: Decodable {
        let docker: Endpoint
    }

    let endpoints: Endpoints

    enum CodingKeys: String, CodingKey {
        case endpoints = "Endpoints"
    }
}
