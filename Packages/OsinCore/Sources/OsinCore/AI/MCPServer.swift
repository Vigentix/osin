import Foundation

/// A minimal Model Context Protocol server (JSON-RPC 2.0, one message per line on stdin/stdout) that
/// offers `AITools`. Started as `Osin --mcp` by Claude Code or Codex.
public final class MCPServer: @unchecked Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private let tools: AITools

    public init(tools: AITools) {
        self.tools = tools
    }

    /// Answers one message; `nil` for notifications (no `id`).
    public func handle(_ data: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return error(NSNull(), -32700, "Parse error")
        }
        // A valid request: an object with jsonrpc "2.0", a string method, a string or number id (none
        // for notifications) and, if present, object params.
        guard let message = parsed as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String
        else {
            return error(NSNull(), -32600, "Invalid Request")
        }
        guard let id = message["id"] else { return nil }
        guard id is String || (id is NSNumber && !Self.isBool(id)) else {
            return error(NSNull(), -32600, "Invalid Request")
        }
        if let raw = message["params"], !(raw is [String: Any]) {
            return error(id, -32602, "Invalid params")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "osin", "version": Self.version],
                "instructions": Self.instructions
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": tools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, -32602, "Invalid params: name is required") }
            if let raw = params["arguments"], !(raw is [String: Any]) {
                return error(id, -32602, "Invalid params: arguments must be an object")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try tools.call(name, arguments: arguments)
                return result(id, ["content": [["type": "text", "text": text(payload)]], "isError": false])
            } catch let error as AIToolError {
                return result(id, ["content": [["type": "text", "text": text(["error": error.message])]], "isError": true])
            } catch {
                return result(id, ["content": [["type": "text", "text": text(["error": error.localizedDescription])]], "isError": true])
            }
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    /// Reads requests from stdin until it closes; each answer is one line on stdout.
    public func serveStandardIO() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = handle(Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(reply + Data([0x0A]))
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let instructions = """
    Osin is a Mac cleaner. Its tools show sizes in the user's home folder and what Osin knows about \
    well-known folders, but never file contents, and they cannot remove anything. Find what can safely \
    go (caches, build output, old downloads of installers, leftovers of tools) and call propose_cleanup \
    with a reason for each item. The user reviews the list in Osin and moves what they choose to the Trash.
    """

    private func error(_ id: Any, _ code: Int, _ message: String) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// JSONSerialization gives booleans as NSNumber too.
    private static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    private func result(_ id: Any, _ value: [String: Any]) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": value])
    }

    private func text(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
