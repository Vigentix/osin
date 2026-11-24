# Osin — Roadmap

Each milestone ends with a working, demoable build.

## M0 — Setup
- [x] GPL-3.0, README, CONTRIBUTING, CODE_OF_CONDUCT
- [ ] Create GitHub repo `vigentix/osin` and push
- [x] Xcode project `Osin` via XcodeGen `project.yml` (macOS 14+, universal, LSUIElement)
- [x] Swift Package `OsinCore` with test target (Swift Testing)
- [x] SwiftLint + SwiftFormat config, Makefile, Brewfile
- [x] GitHub Actions: lint + core tests + universal build (not yet run on GitHub)
- [x] String Catalog (EN + VI) scaffold

## M1 — Metrics + menu bar
- [x] Samplers: CPU (incl. P/E cores), Memory (pressure, swap, compressed), Disk (space, I/O), Battery, Network, Processes, Thermal
- [x] Adaptive sampling (2 s visible / 30 s background)
- [x] Health Score engine + config + unit tests
- [x] `MenuBarExtra` with health dot
- [x] Optional live text metrics in the menu bar (moved to M5 Settings)
- [x] Popover: score ring, 2×2 tiles with sparklines, network, top 3 processes, footer
- [x] Perf check (Debug build, M1): 24 MB footprint, 0.13% CPU in background

## M2 — Dashboard
- [x] Main window with sidebar navigation
- [x] Overview (score breakdown, 1 h / 24 h / 7 d charts with Swift Charts, health checks)
- [x] Memory, Processes (quit / force-quit with confirm), Battery screens
- [x] Metrics history store with downsampling (7 days, SQLite)

## M3 — Scanner (dry-run)
- [x] Rule schema + loader + validator (paths only, no commands; `delete` only if safe + regenerable)
- [x] Bundled MVP rules (safe / review tiers)
- [x] Global Never deny-list
- [x] Symlink-escape protection
- [x] Async scanner with progress stream + cancellation
- [x] Report UI: groups, sizes, file drill-down, large files (> 1 GB)
- [x] Full Disk Access detection; "needs access" markers
- [x] Fixture-based safety test suite

## M4 — Clean
- [x] Actions: `delete` (regenerable safe caches) / `trash` (with recorded resulting URLs) / `builtin`
- [x] Undo (restore) for current session
- [x] Append-only history log + History screen
- [x] Built-in actions (unavailable simulators, Empty Trash) in Review tier with warnings
- [ ] Docker prune built-in (deferred: needs reliable size parsing)
- [x] Memory suggestions ("Quit X to free ≈ Y GB")
- [x] Advanced: `purge` via admin auth (opt-in) — moved to M5 Settings
- [x] Result screen: "Freed X GB" vs "Y GB in Trash" + Empty Trash (irreversible warning)

## M5 — Polish
- [x] Onboarding (3 steps)
- [x] Notifications (disk, memory pressure, battery) with cooldowns
- [ ] Weekly "reclaimable" nudge (deferred: needs background scans)
- [x] Launch at login (`SMAppService`)
- [x] Settings window (thresholds, menu bar metrics, Dock icon, updates)
- [x] Motion: score ring, scan reveal, freed-GB counter; Reduce Motion
- [x] Liquid Glass on macOS 26 via native chrome (sidebar, toolbar, popover); content cards stay solid per HIG
- [x] Accessibility: labels on icon-only controls, combined tile elements, Reduce Motion
- [x] Complete VI translation

## M6 — Release v0.1
- [ ] Apple Developer ID + notarization
- [ ] DMG build script + GitHub Release workflow
- [ ] Sparkle appcast
- [ ] Homebrew cask
- [ ] README with screenshots, safety guarantees, rule contribution guide
- [ ] Final product name

## v2 backlog
CLI (`osin scan`, `osin clean --safe`) · Widgets · Temperature / fan / GPU · App uninstaller + leftovers · Duplicate finder · Disk treemap · Privileged helper daemon · Remote rule updates
