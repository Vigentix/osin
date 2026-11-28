import Foundation
import Observation
import OsinCore

/// Runs the user's own Claude Code or Codex, headless, with only Osin's MCP tools: no shell, no file
/// reading or writing, no web. Osin never signs in or holds a token; the CLI uses its own login.
@MainActor
@Observable
final class AgentRunner {
    enum Provider: String, CaseIterable, Identifiable {
        case claude
        case codex

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }
    }

    struct Step: Identifiable, Equatable {
        enum Kind {
            case tool
            case message
            case note
        }

        let id = UUID()
        let kind: Kind
        let text: String

        static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum Phase: Equatable {
        case idle
        case running(startedAt: Date)
        case finished(proposalID: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var steps: [Step] = []
    /// Installed CLIs, by provider (found once, through the user's login shell).
    private(set) var installed: [Provider: URL] = [:]
    private(set) var detected = false
    private(set) var runID: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var searchPath = ProcessRunnerPath.fallback
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var workspace: URL?

    /// The longest a run may take.
    static let maxDuration: TimeInterval = 15 * 60

    var isRunning: Bool {
        if case .running = phase {
            return true
        }
        return false
    }

    // MARK: Detection

    /// Finds `claude` and `codex` the way the user's terminal would (nvm and Homebrew put them on PATH).
    func detect() async {
        let found = await CLILocator.locate()
        searchPath = found.path
        var tools: [Provider: URL] = [:]
        if let claude = found.claude, await CLILocator.supportsLockdown(.claude, at: claude, path: found.path) {
            tools[.claude] = claude
        }
        if let codex = found.codex, await CLILocator.supportsLockdown(.codex, at: codex, path: found.path) {
            tools[.codex] = codex
        }
        installed = tools
        detected = true
    }

    // MARK: Running

    func start(_ provider: Provider, notes: String) {
        guard !isRunning, let executable = installed[provider], let osin = Bundle.main.executableURL else { return }
        let id = "run-" + UUID().uuidString.prefix(8).lowercased()
        runID = id
        steps = []
        stderrTail = ""
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("osin-ai-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        self.workspace = workspace
        let prompt = AgentPrompt.task(notes: notes)
        let arguments: [String]
        switch provider {
        case .claude:
            let config = workspace.appendingPathComponent("mcp.json")
            let server: [String: Any] = ["command": osin.path, "args": ["--mcp"], "env": ["OSIN_RUN_ID": id, "OSIN_SOURCE": "claude"]]
            let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["osin": server]])
            try? data?.write(to: config)
            arguments = AgentCommand.claude(prompt: prompt, config: config)
        case .codex:
            arguments = AgentCommand.codex(prompt: prompt, osin: osin, runID: id, workspace: workspace)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        // Generous MCP timeouts: measuring a big folder can take a minute.
        environment["MCP_TOOL_TIMEOUT"] = "600000"
        environment["MCP_TIMEOUT"] = "60000"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        AgentStream.attach(output, errors: errors, provider: provider, runner: self)
        process.terminationHandler = AgentStream.terminationHandler(runner: self)
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            self.workspace = nil
            phase = .failed(String(localized: "\(provider.title) could not be started: \(error.localizedDescription)"))
            return
        }
        self.process = process
        phase = .running(startedAt: Date())
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            self?.stop(reason: String(localized: "Stopped after 15 minutes."))
        }
    }

    func stop(reason: String? = nil) {
        guard let process, process.isRunning else { return }
        if let reason {
            steps.append(Step(kind: .note, text: reason))
        }
        // The CLI, its MCP server (Osin itself) and anything else it started.
        let tree = ProcessTree.collect(process.processIdentifier)
        ProcessTree.signal(tree, SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(5))
            ProcessTree.signal(tree.filter(ProcessTree.isAlive), SIGKILL)
        }
    }

    /// Ends a run at once (Osin is quitting).
    func stopNow() {
        guard let process, process.isRunning else { return }
        ProcessTree.signal(ProcessTree.collect(process.processIdentifier), SIGKILL)
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        steps = []
    }

    // MARK: Callbacks (main actor)

    func received(_ step: Step) {
        steps.append(step)
        if steps.count > 400 {
            steps.removeFirst(steps.count - 400)
        }
    }

    func receivedError(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    func ended(status: Int32) {
        timeout?.cancel()
        process = nil
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
            self.workspace = nil
        }
        let proposal = runID.flatMap { id in ProposalStore.defaultFolder().flatMap { try? ProposalStore(folder: $0).load(id: id) } }
        if proposal != nil {
            phase = .finished(proposalID: runID)
        } else if status == 0 {
            phase = .finished(proposalID: nil)
        } else {
            let detail = stderrTail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            phase = .failed(String(localized: "The run ended without a proposal. \(detail)"))
        }
    }
}

/// A process and everything it started, so stopping a run leaves nothing behind.
enum ProcessTree {
    /// `pid` and its descendants, deepest first.
    nonisolated static func collect(_ pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        let children = count > 0 ? Array(buffer.prefix(Int(count))) : []
        return children.flatMap(collect) + [pid]
    }

    nonisolated static func signal(_ pids: [pid_t], _ signal: Int32) {
        for pid in pids where pid > 1 {
            kill(pid, signal)
        }
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

/// The search PATH for child processes.
enum ProcessRunnerPath {
    static let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
