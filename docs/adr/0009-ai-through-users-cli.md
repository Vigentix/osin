# ADR 0009 — AI through the user's own CLI, with Osin's tools only

**Status:** Accepted

## Context
Rules find known caches, but much of a full disk is things no rule names. Users get better results asking Claude Code or Codex to look around, but those agents have a shell and can delete anything. Signing in to Anthropic or OpenAI from Osin would mean holding tokens and depending on login flows that third-party apps may not be allowed to offer.

## Decision
- Osin ships an MCP server in its own binary (`Osin --mcp`) with read-only tools (overview, folder sizes, folder descriptions, Smart Scan, Docker usage) and one write tool, `propose_cleanup`, that only saves a proposal.
- "Clean with AI" runs the user's installed `claude` or `codex` headless, with every built-in tool switched off and only Osin's MCP server configured (no shell, file access, web, plugins, hooks or user config). Versions that cannot be locked down this way are not used.
- Proposals are validated (home folder only, no symlinks, no protected places, same identity) and reviewed in Osin. Approved items go to the Trash through the same checks as Space Lens.
- Off by default, with a notice that folder names and sizes go to Anthropic or OpenAI through the user's CLI.

## Consequences
Osin holds no credentials and the AI cannot remove anything. The CLIs still send their own instruction files (`CLAUDE.md`, `AGENTS.md`; Codex 0.166 has no switch to skip its global one), which the privacy notice says. Usage counts toward the user's own plan. Lockdown depends on CLI flags, so the flags are checked before each run and must be re-verified when the CLIs change.
