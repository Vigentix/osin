# ADR 0007 — `OsinCore` Swift Package separate from UI

**Status:** Accepted

## Context
A future CLI and widgets will need the same metrics and cleaning logic. The safety logic must also be heavily unit-tested.

## Decision
Put the samplers, health engine, rule engine, scanner, cleaner and storage in the `OsinCore` package, which has no SwiftUI dependency. The app target holds only UI.

## Consequences
The core is testable without UI, and building a CLI or widget later costs little.
