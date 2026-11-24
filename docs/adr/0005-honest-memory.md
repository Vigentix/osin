# ADR 0005 — Honest memory management

**Status:** Accepted

## Context
macOS manages RAM itself. A "Free RAM" button that runs `purge` is largely a placebo: freed RAM is refilled within seconds and dropping file cache can slow the system.

## Decision
- Use memory pressure as the primary indicator, together with swap and compressed memory.
- Offer actionable suggestions such as quitting heavy apps.
- Keep `purge` as an opt-in advanced action that requires admin authorisation and shows an explanation of its temporary effect.

## Consequences
Osin is differentiated by trust, at the cost of showing a less flashy "GB freed" number for RAM.
