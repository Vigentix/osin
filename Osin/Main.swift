import Foundation
import OsinCore

/// `Osin --mcp` runs Osin's MCP server for Claude Code or Codex (no window, no menu bar item);
/// anything else starts the app.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPEntry.run()
        }
        OsinApp.main()
    }
}

enum MCPEntry {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        let folder = ProposalStore.defaultFolder() ?? FileManager.default.temporaryDirectory.appendingPathComponent("osin-proposals")
        let tools = AITools(
            proposals: ProposalStore(folder: folder),
            runID: environment["OSIN_RUN_ID"],
            source: environment["OSIN_SOURCE"] ?? "external",
            projectRoots: Preferences.projectRoots,
            // Launched by another app, macOS would ask on its behalf: never look into private folders.
            includePrivateAreas: false,
            spaceCacheURL: SpaceLensCache.defaultURL()
        )
        MCPServer(tools: tools).serveStandardIO()
        exit(0)
    }
}
