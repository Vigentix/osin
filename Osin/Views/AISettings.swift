import OsinCore
import SwiftUI

/// Settings › AI: turn Clean with AI on or off, and add Osin's tools to your own Claude Code or Codex.
struct AISettings: View {
    @Environment(AgentRunner.self) private var runner
    @AppStorage(Preferences.Key.aiEnabled) private var enabled = false
    @State private var added: [AgentRunner.Provider: String] = [:]
    @State private var working: AgentRunner.Provider?

    var body: some View {
        Form {
            Section {
                Toggle("Clean with AI", isOn: $enabled)
                    .onChange(of: enabled) { _, isOn in
                        if isOn, !runner.detected {
                            Task { await runner.detect() }
                        }
                    }
            } footer: {
                Text(
                    // swiftlint:disable:next line_length
                    "Runs your own Claude Code or Codex with only Osin's tools: folder names and sizes, never file contents, no terminal. It proposes; you choose what goes to the Trash. Folder names and sizes are sent to Anthropic or OpenAI, with the CLI's usual instruction files (CLAUDE.md, AGENTS.md), and count toward your plan."
                )
            }
            Section {
                ForEach(AgentRunner.Provider.allCases) { provider in
                    HStack {
                        Text(provider.title)
                        Spacer()
                        if !runner.detected {
                            ProgressView().controlSize(.small)
                        } else if runner.installed[provider] == nil {
                            Text("Not found").foregroundStyle(.secondary)
                        } else if let message = added[provider] {
                            Text(message).foregroundStyle(.secondary)
                        } else {
                            Button("Add Osin's Tools") { add(provider) }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(working != nil)
                        }
                    }
                }
            } header: {
                Text("Use Osin in your own sessions")
            } footer: {
                Text(
                    // swiftlint:disable:next line_length
                    "Adds Osin as a tool server, so you can ask Claude Code or Codex to clean up your Mac. Whatever it proposes appears in Cleanup › Clean with AI for you to review."
                )
            }
        }
        .formStyle(.grouped)
        .task {
            if !runner.detected {
                await runner.detect()
            }
        }
    }

    private func add(_ provider: AgentRunner.Provider) {
        guard let executable = runner.installed[provider], let osin = Bundle.main.executableURL else { return }
        working = provider
        Task {
            let ok = await AIIntegration.add(provider, executable: executable, osin: osin)
            added[provider] = ok ? String(localized: "Added") : String(localized: "Could not add")
            working = nil
        }
    }
}

/// Registers `Osin --mcp` with the user's CLI (`claude mcp add` / `codex mcp add`).
enum AIIntegration {
    nonisolated static func add(_ provider: AgentRunner.Provider, executable: URL, osin: URL) async -> Bool {
        let path = await CLILocator.locate().path
        switch provider {
        case .claude:
            if let existing = await CLILocator.run(executable, ["mcp", "get", "osin"], path: path), existing.contains(osin.path) {
                return true
            }
            _ = await CLILocator.run(executable, ["mcp", "add", "--scope", "user", "osin", "--", osin.path, "--mcp"], path: path)
        case .codex:
            if let existing = await CLILocator.run(executable, ["mcp", "get", "osin"], path: path), existing.contains(osin.path) {
                return true
            }
            _ = await CLILocator.run(executable, ["mcp", "add", "osin", "--", osin.path, "--mcp"], path: path)
        }
        // Added if the CLI now lists it.
        return await CLILocator.run(executable, ["mcp", "get", "osin"], path: path)?.contains(osin.path) ?? false
    }
}
