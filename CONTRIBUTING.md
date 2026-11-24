# Contributing to Osin

Thanks for helping. Osin deletes files on people's machines, so the bar for safety is high. Please read this first.

## Setup

```sh
make bootstrap
make open
```

Before opening a PR:

```sh
make format
make lint
make test
```

CI runs lint, the `OsinCore` tests and a universal release build on every PR.

## Ground rules

1. **Safety first.** Any change to the rule engine, scanner or cleaner must come with tests on fixture directories. A PR that weakens a safety guarantee in [`docs/PRD.md`](docs/PRD.md) §6.5–6.7 will not be merged.
2. **Rules are data.** Cleanup rules hold paths and patterns only, never shell commands. A rule may use `action: delete` only when it is `tier: safe` and the data is truly regenerable. Explain how the tool regenerates it in the PR.
3. **Core stays UI-free.** `OsinCore` must not import SwiftUI or AppKit UI types.
4. **Strings are localized.** User-facing text goes through the String Catalog. Add the Vietnamese translation if you can; otherwise leave it for a maintainer.
5. **No telemetry, no new network calls.**
6. **Big decisions get an ADR** in `docs/adr/`.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.

## Code of Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
