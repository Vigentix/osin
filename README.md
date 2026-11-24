# Osin

**An honest, open-source health monitor and cleaner for macOS.**

Osin lives in your menu bar. It shows how your Mac is doing (CPU, memory pressure, disk, battery, network, processes) and reclaims disk space with one **Smart Scan → Review → Clean** flow.

> **Status:** v0.1 preview. Builds are not notarized yet; see [Install](#install).

## What it does

- **Menu bar health at a glance:** a health score with the reason behind it ("Disk almost full"), CPU with performance/efficiency cores, memory pressure, disk, battery health and cycles, network, and the apps using the most memory, each with a Quit button. Optional live CPU, memory and network text in the menu bar.
- **Dashboard:** 1 hour / 24 hours / 7 days charts, a plain-language health report, memory breakdown, a sortable process list, battery details, large files.
- **Smart Scan:** finds caches, logs, Xcode and package-manager leftovers, old `node_modules`, installers and old downloads, unavailable simulators and the Trash. You review a report before anything happens.
- **Notifications** when the disk is almost full, memory pressure stays critical, or the battery is wearing out. Osin never cleans on its own.
- English and Vietnamese.

## Safety guarantees

Osin removes files on your Mac, so these rules are enforced in code and covered by tests on throwaway folders:

1. **Only regenerable caches are deleted.** Everything else goes to the Trash and can be restored from the result screen or History.
2. **Nothing outside the [rules](Packages/OsinCore/Sources/OsinCore/Rules/rules.json) is touched.** Rules are data (paths and patterns, never commands), limited to your home folder.
3. **Protected locations are never cleaned:** Documents, Desktop, Pictures, Movies, Music, Mail, iCloud Drive, Messages, Keychains, Safari data, `.ssh`, system folders, and any folder that contains them.
4. **Symlinks are never followed**, and every item is re-checked right before it is removed.
5. **Every action is logged** (`~/Library/Application Support/Osin/cleanup-log.jsonl`).
6. **No telemetry.** The only network request is the optional update check.

Memory is handled honestly: Osin shows memory pressure (the signal that matters) and suggests apps to quit. A `purge` button exists only in Settings › Advanced, with an explanation of why its effect is temporary.

## Install

Download `Osin-x.y.z.dmg` from [Releases](https://github.com/Vigentix/osin/releases) and drag Osin to Applications. Until releases are notarized, open it the first time with right-click › Open (or `xattr -dr com.apple.quarantine /Applications/Osin.app`).

Requires macOS 14 Sonoma or later, Apple Silicon or Intel.

## Build from source

```sh
git clone https://github.com/Vigentix/osin.git
cd osin
make bootstrap   # installs XcodeGen, SwiftLint, SwiftFormat; generates Osin.xcodeproj
make open        # opens Xcode — run the "Osin" scheme
```

| Command | What it does |
|---|---|
| `make test` | `OsinCore` unit and integration tests |
| `make build` / `make build-release` | Debug build / universal release build (unsigned) |
| `make lint` / `make format` | SwiftFormat + SwiftLint |
| `make l10n-check` | Fails if a UI string is missing from the String Catalog |
| `make snapshots` | Renders every screen with live data to `build/snapshots` (Debug only) |
| `scripts/release.sh 0.1.0` | DMG + Sparkle ZIP; see [docs/RELEASING.md](docs/RELEASING.md) |

## Project layout

```
Osin/                 SwiftUI app: menu bar, dashboard, Smart Scan, settings, onboarding
Packages/OsinCore/    UI-free core: metrics sampler, health score, history, rules, scanner, cleaner
docs/                 PRD, roadmap, architecture decisions, release guide
packaging/homebrew/   Homebrew cask
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a cleanup rule for your favourite tool is a good first contribution.

## License

[GPL-3.0](LICENSE)
