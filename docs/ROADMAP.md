# Osin — Roadmap

Each milestone ends with a working, demoable build.

## M0 — Setup
- [x] GPL-3.0, README, CONTRIBUTING, CODE_OF_CONDUCT
- [x] Create GitHub repo `Vigentix/osin` and push
- [x] Xcode project `Osin` via XcodeGen `project.yml` (macOS 14+, universal, LSUIElement)
- [x] Swift Package `OsinCore` with test target (Swift Testing)
- [x] SwiftLint + SwiftFormat config, Makefile, Brewfile
- [x] GitHub Actions: lint (Ubuntu) + core tests + universal build (macOS), green on `main`
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
- [ ] Weekly "reclaimable" nudge (deferred to v2; a quiet background scan now runs after launch)
- [x] Launch at login (`SMAppService`)
- [x] Settings window (thresholds, menu bar metrics, Dock icon, updates)
- [x] Motion: score ring, scan reveal, freed-GB counter; Reduce Motion
- [x] macOS 26: native glass on the popover; custom solid sidebar (the native glass sidebar rendered white in the dark theme)
- [x] Accessibility: labels on icon-only controls, combined tile elements, Reduce Motion
- [x] Complete VI translation

## M6 — Release v0.1
- [x] DMG build script (`scripts/release.sh`) + GitHub Release workflow (draft release on `v*` tags)
- [x] Sparkle integrated; appcast generated when keys are configured (`docs/RELEASING.md`)
- [x] Homebrew cask template (`packaging/homebrew/osin.rb`)
- [x] README with safety guarantees and rule contribution guide
- [ ] Apple Developer ID + notarization (needs the $99/year account; workflow is ready; first-launch steps documented meanwhile)
- [x] Sparkle EdDSA keys + GitHub secrets (0.1.2; update from 0.1.2 to a newer build verified end to end)
- [ ] README screenshots (`make snapshots` renders them)
- [x] Final product name: Osin (kept)
- [x] Tag and publish v0.1.0
- [x] v0.1.1: safety and reliability fixes from three review rounds
- [x] Homebrew tap `Vigentix/homebrew-tap`

## v0.2 — Keep Awake
- [x] Keep the Mac awake (IOPM assertion, released automatically if Osin quits): screen on, display may sleep, or lock now
- [x] Until stopped, timer, until a time, until a process ends (PID + start time), optional maximum
- [x] Safety stops: low battery, hot, unplugged (optional); notification with the reason
- [x] Popover row and options, menu bar indicator, Overview banner, Settings tab, optional global shortcut
- [x] Warns about lid-close sleep and pending automatic macOS updates
- [x] 0.2.1: App caches keep Osin's own cache and app updates still downloading; those updates are a review item
- [x] 0.2.2: performance pass (Keep Awake ticks every 5 s when nothing shows it, cached process details, rotated cleanup log read off the main thread, coalesced storage measurement, fewer permission checks, menu bar label redrawn only on change, O(depth) scan overlap checks)
- [ ] Lid-closed mode (needs root: `pmset disablesleep`; only with a crash-safe restore)

## v0.3 — Motion and pinned headers
- [x] Motion tokens (one curve, three durations, a light spring); everything respects Reduce Motion
- [x] Condensing pinned headers (System), Overview compact bar, pinned Cleanup tab actions and report group header
- [x] Page transitions, sliding sidebar selection, rolling key numbers, chart draw-in on new data, staggered scan results, Keep Awake options push/pop
- [x] No idle cost: nothing animates or observes while no Osin window is visible

## v0.4 — Chores and watching the house
- [x] Scheduled chores: Safe groups only, off by default, on power and idle, catch up within 24 h; notification + History
- [x] Weekly report (Monday 9:00): freed, score trend, strained moments, top apps, Keep Awake hours, suggestions; "This week" card
- [x] Watch: sustained CPU and memory growth per app, one alert per app per day, Quit / Ignore / Open Activity
- [x] Record when each app was last seen running (for the uninstaller)

## v0.4.1 — Lighter dashboard
- [x] Live dot pulses with Core Animation; live metrics update in place (dashboard open: ~20% CPU to under 1%)

## v0.5 — Deeper clean
- [x] Safe: developer tool caches (uv, bun, Maven, Terraform plugins, …) and browser / Electron app caches (Chrome, Edge, Brave, Arc, Vivaldi, Slack, Discord, VS Code, Cursor, Claude, …), skipped while the app runs
- [x] Review: Chrome's on-device AI model, websites' offline storage; old AI agent sessions (`~/.claude/projects`, `~/.codex/sessions`, 90 days)
- [x] Docker: build cache (safe), dangling images and unused volumes (review) through the official CLI; optional Colima disk trim
- [x] Cold projects: `node_modules`, `.venv`, `target`, `.next`, `Pods`, … in projects untouched for 30 days (git and files); project folders in Settings
- [x] Unused toolchains: nvm, pyenv and rustup versions that no default or project uses
- [x] New Safe groups are not added to scheduled chores until the user turns them on
- [x] Space Lens: browse what uses space in your home folder (whole disk with Full Disk Access), known-folder descriptions, Trash only

## v0.6 — Clean with AI
- [ ] Runs the user's own Claude Code or Codex (no Osin login, no tokens) with Osin's MCP tools only: no shell, no file contents
- [ ] The AI proposes, the user approves in Osin; everything goes to the Trash and History
- [ ] Live progress, notes for the AI, "Add Osin to Claude Code / Codex"; off by default with a clear privacy notice

## v0.7 — Clean uninstall (Developer ID recommended first)
- [ ] Apps page: drag in or pick from a list (size, last seen); app + `~/Library` leftovers to the Trash via Finder; `/Library` leftovers listed
- [ ] Smart Scan review group: leftovers of apps no longer installed (conservative matching)

## v0.8 — Startup and tidying
- [ ] Startup: user LaunchAgents (disable/enable), system agents and daemons (view; admin prompt to disable), approximate Login Items + System Settings link
- [ ] Tidy Downloads and Desktop: sort or move to the Trash only, preview and Undo

## v2 backlog
Time Machine snapshots · weekly nudge · CLI (`osin scan`, `osin clean --safe`) · Widgets · Temperature / fan / GPU · Duplicate finder · Privileged helper daemon · Remote rule updates
