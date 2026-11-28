import Foundation
import OsinCore

/// Finds the CLIs through the user's login shell (so nvm and Homebrew paths are known).
enum CLILocator {
    struct Found {
        var path = ProcessRunnerPath.fallback
        var claude: URL?
        var codex: URL?
    }

    nonisolated static func locate() async -> Found {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let script = #"printf 'OSIN_PATH=%s\n' "$PATH"; printf 'OSIN_CLAUDE=%s\n' "$(command -v claude)"; printf 'OSIN_CODEX=%s\n' "$(command -v codex)""#
        let text = await run(URL(fileURLWithPath: shell), ["-l", "-c", script], path: nil) ?? ""
        var found = Found()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("/") || parts[0] == "OSIN_PATH" else { continue }
            switch parts[0] {
            case "OSIN_PATH": if !parts[1].isEmpty {
                    found.path = parts[1]
                }
            case "OSIN_CLAUDE": found.claude = executable(parts[1])
            case "OSIN_CODEX": found.codex = executable(parts[1])
            default: break
            }
        }
        // Fallbacks when the shell gave nothing.
        found.claude = found.claude ?? [
            "~/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "~/.local/bin/claude"
        ]
        .lazy.compactMap { executable(($0 as NSString).expandingTildeInPath) }.first
        found.codex = found.codex ?? ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].lazy.compactMap(executable).first
        return found
    }

    private nonisolated static func executable(_ path: String) -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Only versions that can be locked down are used: Claude Code with `--tools`, Codex with switches
    /// for its shell and with the sandboxed code-mode host.
    nonisolated static func supportsLockdown(_ provider: AgentRunner.Provider, at url: URL, path: String) async -> Bool {
        switch provider {
        case .claude:
            let help = await run(url, ["--help"], path: path) ?? ""
            return ["--tools", "--strict-mcp-config", "--permission-prompts", "--mcp-config"].allSatisfy(help.contains)
        case .codex:
            let features = await run(url, ["features", "list"], path: path) ?? ""
            return ["shell_tool", "unified_exec", "code_mode_host"].allSatisfy(features.contains)
        }
    }

    /// Output of a short command, or `nil` (it is stopped after 20 s).
    nonisolated static func run(_ executable: URL, _ arguments: [String], path: String?) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let path {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = path
                process.environment = environment
            }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { @Sendable in
                // Also its children: one holding the pipe open would keep the read below waiting.
                if process.isRunning {
                    ProcessTree.signal(ProcessTree.collect(process.processIdentifier), SIGKILL)
                }
            }
            DispatchQueue.global(qos: .utility).async { @Sendable in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(bytes: data, encoding: .utf8))
            }
        }
    }
}

/// Command lines that leave the AI nothing but Osin's tools (checked against Claude Code 2.1 and
/// Codex 0.166: with these, neither could read a file).
enum AgentCommand {
    static func claude(prompt: String, config: URL) -> [String] {
        [
            "-p", prompt,
            "--output-format", "stream-json", "--verbose",
            "--tools", "", // no built-in tools at all: no shell, no file reading or writing, no web
            "--strict-mcp-config", "--mcp-config", config.path, // only Osin's MCP server
            "--allowedTools", "mcp__osin",
            "--permission-prompts", "none", // anything else would be denied
            "--setting-sources", "", // no user hooks, plugins or extra servers
            "--no-session-persistence",
            "--append-system-prompt", AgentPrompt.rules
        ]
    }

    /// Codex 0.166 calls MCP tools from its code-mode host: a JavaScript sandbox with no file, process or
    /// network access (checked), so that host stays on. The shell, the Node REPL and everything else go.
    static let codexDisabled = [
        "shell_tool", "unified_exec", "js_repl", "code_mode", "view_image", "apps", "browser_use",
        "browser_use_external", "in_app_browser", "computer_use", "image_generation", "plugins", "hooks",
        "standalone_web_search", "multi_agent", "multi_agent_v2", "memories", "request_permissions_tool", "goals",
        "skill_search", "skill_mcp_dependency_install", "tool_suggest"
    ]

    static func codex(prompt: String, osin: URL, runID: String, workspace: URL) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "-s",
            "read-only"
        ]
        for feature in codexDisabled {
            arguments += ["--disable", feature]
        }
        let command = osin.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        arguments += [
            "-c", #"web_search="disabled""#,
            "-c", #"approval_policy="never""#, // with the read-only sandbox, any write is refused
            "-c", "mcp_servers.osin.command=\"\(command)\"",
            "-c", #"mcp_servers.osin.args=["--mcp"]"#,
            "-c", "mcp_servers.osin.env={OSIN_RUN_ID=\"\(runID)\",OSIN_SOURCE=\"codex\"}",
            "-c", "mcp_servers.osin.tool_timeout_sec=600",
            "-c", "mcp_servers.osin.startup_timeout_sec=60",
            "-C", workspace.path,
            AgentPrompt.rules + "\n\n" + prompt
        ]
        return arguments
    }
}

enum AgentPrompt {
    static var language: String {
        Locale.preferredLanguages.first?.hasPrefix("vi") == true ? "Vietnamese" : "English"
    }

    static let rules = """
    You are helping the user free disk space on their Mac through Osin. You can only use Osin's tools \
    (get_overview, list_folder, describe_folder, smart_scan, docker_usage, propose_cleanup). They show sizes \
    and what Osin knows about folders, never file contents, and they cannot remove anything.
    Rules:
    - Propose only things that are safe to lose or that the user can easily get back: caches, build output, \
    dependencies of projects that are not in use, leftovers of uninstalled apps, old installers, large old \
    downloads you can identify by name. When unsure, leave it out.
    - Never propose the user's own documents, photos, music, messages, source code, keys, settings or \
    app data you cannot identify. Osin refuses protected places anyway.
    - Docker is cleaned from Osin's Smart Scan; mention it in the summary instead of proposing its files.
    - Prefer folders Osin marks "safe"; explain "review" ones clearly.
    - Finish by calling propose_cleanup once (or a few times for many items) with a clear reason per item \
    and a short summary. Then reply with one short paragraph.
    """

    static func task(notes: String) -> String {
        var text = "Find what can safely be removed from my home folder to free space, and propose it with propose_cleanup. "
            + "Write the summary, reasons and categories in \(language)."
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            text += "\nMy notes: \(trimmed.prefix(1000))"
        }
        return text
    }
}

/// Turns the CLI's JSON stream into progress steps for the runner. Runs on background queues:
/// every closure here is `@Sendable` and hops to the main actor explicitly.
enum AgentStream {
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func lines(adding data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                if let text = String(bytes: line, encoding: .utf8) {
                    lines.append(text)
                }
            }
            return lines
        }
    }

    nonisolated static func attach(_ output: Pipe, errors: Pipe, provider: AgentRunner.Provider, runner: AgentRunner) {
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let steps = buffer.lines(adding: data).compactMap { step(from: $0, provider: provider) }
            guard !steps.isEmpty else { return }
            Task { @MainActor in steps.forEach(runner.received) }
        }
        errors.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(bytes: data, encoding: .utf8) ?? ""
            Task { @MainActor in runner.receivedError(text) }
        }
    }

    nonisolated static func terminationHandler(runner: AgentRunner) -> @Sendable (Process) -> Void {
        { @Sendable process in
            let status = process.terminationStatus
            Task { @MainActor in
                // Let the last lines of output arrive first.
                try? await Task.sleep(for: .milliseconds(400))
                runner.ended(status: status)
            }
        }
    }

    /// One progress step from a line of `claude --output-format stream-json` or `codex exec --json`.
    nonisolated static func step(from line: String, provider: AgentRunner.Provider) -> AgentRunner.Step? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch provider {
        case .claude:
            guard object["type"] as? String == "assistant",
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return nil }
            for block in content {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    return AgentRunner.Step(kind: .tool, text: describe(tool: name, input: block["input"] as? [String: Any]))
                }
                if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                    return AgentRunner.Step(kind: .message, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return nil
        case .codex:
            guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String else { return nil }
            if kind == "mcp_tool_call", object["type"] as? String == "item.started", let tool = item["tool"] as? String {
                return AgentRunner.Step(kind: .tool, text: describe(tool: tool, input: item["arguments"] as? [String: Any]))
            }
            if kind == "agent_message", object["type"] as? String == "item.completed", let text = item["text"] as? String {
                return AgentRunner.Step(kind: .message, text: text)
            }
            return nil
        }
    }

    nonisolated static func describe(tool: String, input: [String: Any]?) -> String {
        let name = tool.replacingOccurrences(of: "mcp__osin__", with: "")
        let path = input?["path"] as? String ?? ""
        switch name {
        case "get_overview": return String(localized: "Looking at the whole disk")
        case "list_folder": return String(localized: "Looking in \(path)")
        case "describe_folder": return String(localized: "Checking \(path)")
        case "smart_scan": return String(localized: "Running Smart Scan")
        case "docker_usage": return String(localized: "Checking Docker")
        case "propose_cleanup": return String(localized: "Writing the proposal")
        default: return name
        }
    }
}
