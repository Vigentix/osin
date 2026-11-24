# Osin

**An honest, open-source health monitor and cleaner for macOS.**

Osin lives in your menu bar. It shows how your Mac is doing (CPU, memory pressure, disk, battery, network, processes) and reclaims disk space with one **Smart Scan → Review → Clean** flow.

> **Status:** pre-alpha (milestone M0). Nothing useful to install yet. Follow along in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Promises

- **No surprise deletions.** Only regenerable caches are deleted directly. Everything else goes to the Trash and can be restored. Nothing outside the open-source [rules](docs/PRD.md#67-declarative-cleanup-rules) is ever touched.
- **Honest about RAM.** No placebo "Free RAM" button. Osin shows memory pressure and tells you which app to quit.
- **Private.** No telemetry. The only network call is an optional update check.
- **Light.** Target: < 50 MB RAM and < 0.5% CPU in the background.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel
- Building: Xcode 16+ and Homebrew

## Build from source

```sh
git clone https://github.com/vigentix/osin.git
cd osin
make bootstrap   # installs XcodeGen, SwiftLint, SwiftFormat; generates Osin.xcodeproj
make open        # opens Xcode — run the "Osin" scheme
```

Other tasks:

| Command | What it does |
|---|---|
| `make test` | Run `OsinCore` unit tests |
| `make build` | Debug build, unsigned |
| `make build-release` | Universal release build, unsigned |
| `make lint` / `make format` | SwiftFormat + SwiftLint |

`Osin.xcodeproj` is generated from [`project.yml`](project.yml) and is not committed.

## Project layout

```
Osin/                 SwiftUI app (menu bar, dashboard, settings)
Packages/OsinCore/    UI-free core: metrics, health score, rules, scanner, cleaner
docs/                 PRD, roadmap, architecture decision records
```

## Docs

- [Product requirements](docs/PRD.md)
- [Roadmap](docs/ROADMAP.md)
- [Architecture decisions](docs/adr/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a cleanup rule for your favourite tool will be the easiest first contribution once the rule engine lands (M3).

## License

[GPL-3.0](LICENSE)
