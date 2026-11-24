# ADR 0002 — Distribute outside the Mac App Store, no sandbox

**Status:** Accepted

## Context
The App Sandbox blocks reading or removing other apps' caches, `~/Library/Caches`, Xcode DerivedData and terminating other processes. Those are the core of the product.

## Decision
Ship without the sandbox. Distribute through GitHub Releases (DMG) with Sparkle updates, and through a Homebrew cask once the app is notarized with a Developer ID.

## Consequences
- Osin gets full cleaner capability, but no App Store discovery.
- A Developer ID ($99/yr) is required before the public v0.1. Earlier pre-releases ship unsigned with documented install steps.
