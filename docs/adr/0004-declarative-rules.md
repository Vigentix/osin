# ADR 0004 — Declarative cleanup rules (paths only)

**Status:** Accepted

## Context
New developer tools appear constantly. Community contributions must be easy and safe.

## Decision
Define cleanup rules as bundled JSON data (one ordered array, no third-party YAML parser):
- A rule holds an id, name, tier, path globs and conditions.
- Rules never contain shell commands.
- Command-based actions (simctl, docker) are implemented in Swift as built-in actions.
- The engine resolves symlinks, rejects any root escape and applies a global Never deny-list.

## Consequences
- Adding a rule requires no Swift code, so it is easy to review in a PR.
- Rule files cannot be used to run code.
- Remote rule updates are deferred to v2.
