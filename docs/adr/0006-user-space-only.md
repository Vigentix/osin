# ADR 0006 — User-space only in MVP

**Status:** Accepted

## Context
A privileged helper daemon (`SMAppService` daemon) adds attack surface and complexity.

## Decision
The MVP runs entirely as the user:
- Full Disk Access is optional.
- Root-only actions request admin authorisation for each action through Authorization Services.
- A helper daemon is deferred to v2.

## Consequences
The attack surface stays small, but users see a few password prompts for advanced actions.
