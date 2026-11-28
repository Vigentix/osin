import AppKit
import OsinCore
import SwiftUI

/// Cleanup › Clean with AI: run the user's Claude Code or Codex with Osin's tools, follow along, then
/// review what it proposes and move the chosen items to the Trash.
struct AICleanView: View {
    @Environment(AgentRunner.self) private var runner
    @Environment(AIProposalsModel.self) private var proposals
    @AppStorage(Preferences.Key.aiEnabled) private var enabled = false
    @AppStorage(Preferences.Key.aiProvider) private var providerName = AgentRunner.Provider.claude.rawValue
    @State private var notes = ""

    var body: some View {
        Group {
            if runner.isRunning {
                running
            } else if let proposal = proposals.proposal {
                // Also proposals from the user's own sessions, even with runs turned off here.
                AIProposalReview(proposal: proposal)
            } else if !enabled {
                intro
            } else {
                start
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if enabled, !runner.detected {
                await runner.detect()
            }
        }
    }

    // MARK: Off

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IconTile(systemName: "sparkles", tint: Theme.accent, size: 52)
                Text("Let your AI find what to clean").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                Text(
                    // swiftlint:disable:next line_length
                    "Osin can run Claude Code or Codex, if you use one, to look through your home folder like you would ask it in a chat, and propose what to remove."
                )
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    point(
                        "lock.shield",
                        "The AI gets only Osin's tools: folder names and sizes, and what Osin knows about them. No file contents, no terminal, no web."
                    )
                    point(
                        "hand.raised",
                        "It can only propose. You review every item, and what you choose goes to the Trash, restorable from History."
                    )
                    point(
                        "network",
                        // swiftlint:disable:next line_length
                        "Folder names and sizes are sent to Anthropic or OpenAI through your own Claude Code or Codex, with the CLI's usual instruction files (CLAUDE.md, AGENTS.md), and count toward your plan's usage. Osin never signs in or keeps a token."
                    )
                }
                .padding(18)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
                Button("Turn On Clean with AI") {
                    enabled = true
                    Task { await runner.detect() }
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ready

    private var provider: AgentRunner.Provider {
        let chosen = AgentRunner.Provider(rawValue: providerName) ?? .claude
        return runner.installed[chosen] != nil ? chosen : (runner.installed.keys.sorted { $0.rawValue < $1.rawValue }.first ?? chosen)
    }

    @ViewBuilder private var start: some View {
        if !runner.detected {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for Claude Code and Codex…").foregroundStyle(Theme.text2)
            }
        } else if runner.installed.isEmpty {
            VStack(spacing: 12) {
                IconTile(systemName: "terminal", tint: Theme.text3, size: 44)
                Text("Claude Code or Codex is needed").font(.system(size: 17, weight: .semibold))
                Text("Install one of them and sign in from Terminal (claude or codex), then check again. Osin uses your own sign-in.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: 420)
                Button("Check Again") { Task { await runner.detect() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Clean with AI").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    if case let .failed(message) = runner.phase {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.poorText)
                    } else if case .finished(nil) = runner.phase {
                        Label("The AI finished without proposing anything.", systemImage: "info.circle").foregroundStyle(Theme.text2)
                    }
                    if runner.installed.count > 1 {
                        SegmentedPicker(
                            options: runner.installed.keys.sorted { $0.rawValue < $1.rawValue }.map { (
                                $0,
                                LocalizedStringResource(stringLiteral: $0.title)
                            ) },
                            selection: Binding(get: { provider }, set: { providerName = $0.rawValue })
                        )
                    } else {
                        Text("Uses \(provider.title)").foregroundStyle(Theme.text2)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything to keep or focus on? (optional)").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text2)
                        TextField(
                            "For example: don't touch the weather-api project; I don't use Docker any more",
                            text: $notes,
                            axis: .vertical
                        )
                        .lineLimit(2 ... 5)
                        .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 12) {
                        Button("Start") { runner.start(provider, notes: notes) }
                            .buttonStyle(PrimaryButtonStyle(large: true))
                            .keyboardShortcut(.defaultAction)
                        Text("Takes a few minutes. You can keep working meanwhile.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                if case let .running(startedAt) = runner.phase {
                    Text("\(provider.title) is looking around · started \(startedAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                Button("Stop") { runner.stop() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(runner.steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: step
                                    .kind == .tool ? "magnifyingglass" : (step.kind == .note ? "info.circle" : "text.bubble"))
                                    .foregroundStyle(step.kind == .tool ? Theme.accent : Theme.text3)
                                    .frame(width: 18)
                                Text(step.text)
                                    .foregroundStyle(step.kind == .message ? Theme.text : Theme.text2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(step.id)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: runner.steps.count) { _, _ in
                    if let last = runner.steps.last {
                        withAnimation(Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

/// The proposal: grouped items with reasons, each with a checkbox, and Move to Trash.
private struct AIProposalReview: View {
    @Environment(AIProposalsModel.self) private var proposals
    @Environment(AgentRunner.self) private var runner
    let proposal: CleanupProposal

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Proposed by \(sourceName)").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        Text(proposal.summary.isEmpty ? String(localized: "Here is what the AI suggests removing.") : proposal.summary)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let moved = proposals.movedBytes, moved > 0 {
                        Label(
                            "Moved \(Format.storage(moved)) to the Trash. Empty the Trash to free the space.",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(Theme.goodText)
                    }
                    if !proposals.failures.isEmpty {
                        Label(
                            "Some items stayed. They are still listed below, so you can try again.",
                            systemImage: "exclamationmark.circle"
                        )
                        .foregroundStyle(Theme.text2)
                        ForEach(proposals.failures) { failure in
                            Text(verbatim: "\(failure.url.lastPathComponent): \(failure.localizedReason)").font(.caption)
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    ForEach(proposals.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    row(item)
                                    if item.id != group.items.last?.id {
                                        Divider().overlay(Theme.border).padding(.leading, 44)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.storage(proposals.selectedBytes)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    Text("\(proposals.selectedItems.count) items to the Trash (restorable)").font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                Button(proposal.items.isEmpty ? "Done" : "Discard") {
                    proposals.discard()
                    runner.reset()
                }
                .buttonStyle(SecondaryButtonStyle(large: true))
                .disabled(proposals.isTrashing)
                if !proposal.items.isEmpty {
                    Button("Move to Trash") { Task { await proposals.moveSelectedToTrash() } }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .disabled(proposals.selectedItems.isEmpty || proposals.isTrashing)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Theme.surface)
        }
    }

    private var sourceName: String {
        switch proposal.source {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: String(localized: "your AI session")
        }
    }

    private func row(_ item: CleanupProposal.Item) -> some View {
        let included = !proposals.excluded.contains(item.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(get: { included }, set: { _ in proposals.toggle(item.id) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(proposals.isTrashing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).fontWeight(.semibold)
                    if let advice = item.advice.flatMap(FolderGuide.Advice.init(rawValue:)) {
                        Text(SpaceColors.adviceText(advice)).font(.system(size: 11)).foregroundStyle(SpaceColors.tint(
                            for: advice,
                            skipped: false
                        ))
                    }
                }
                Text(item.reason).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let app = proposals.blockedBy[item.path] {
                    Label("Quit \(app) first, or it stays", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Theme.fairText)
                }
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(Format.storage(item.bytes)).monospacedDigit().fontWeight(.semibold)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "magnifyingglass").frame(width: 22, height: 22)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(Text("Show in Finder"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(included ? 1 : 0.55)
    }
}
