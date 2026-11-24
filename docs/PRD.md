# Osin — Product Requirements (v0.1 MVP)

> Status: Draft · Codename: **Osin** (final name decided before public release)
> License: GPL-3.0 · Repo: `vigentix/osin`

## 1. Summary

Osin is an open-source macOS menu bar app that shows the Mac's health (CPU, memory, disk, battery, network, processes) and reclaims disk space with a single **Smart Scan → Review → Clean** flow. It is honest about memory, never deletes permanently by default, and sends no telemetry.

## 2. Principles

1. **Safe by default.** Only regenerable caches are deleted directly; everything else goes to the Trash and can be restored. Nothing outside declared rule paths is ever touched.
2. **Honest.** No placebo "Free RAM" numbers. Show what actually matters (memory pressure, swap) and explain trade-offs.
3. **Light.** The app that optimises your Mac must not cost much itself: < 50 MB RAM, < 0.5% CPU in background.
4. **Private.** No telemetry, no network except the optional update check.
5. **Open.** Cleanup rules are declarative data files the community can extend through PRs.

## 3. Target users

- Mac users whose disk keeps filling up and who want a trustworthy, free CleanMyMac/iStat alternative.
- Developers (Xcode, Node, Docker, Homebrew users), who generate the most reclaimable junk and are the most likely open-source adopters.

## 4. Platform & distribution

| Item | Decision |
|---|---|
| Stack | Swift 6 + SwiftUI, native APIs (no Electron/Tauri) |
| Min OS | macOS 14 Sonoma; Liquid Glass on macOS 26 via `#available` |
| Arch | Universal binary (Apple Silicon + Intel) |
| Sandbox | **No** (outside Mac App Store) |
| Distribution | GitHub Releases (DMG) + Sparkle updates; Homebrew cask once notarized |
| Signing | Unsigned for early pre-releases; Developer ID + notarization before v0.1 public (M6) |
| Localisation | English (default) + Vietnamese via String Catalog (`.xcstrings`) |

## 5. App shape

- **Menu bar app** (LSUIElement). Dock icon hidden by default, toggle in Settings.
- **Popover** for at-a-glance status and the one-click scan.
- **Main window (Dashboard)** for detail, reports and history.
- **Settings** window following the standard macOS layout.

## 6. Features — MVP

### 6.1 Health monitoring

| Metric | Details | Source (planned) |
|---|---|---|
| CPU | Total, per core, P-core/E-core split on Apple Silicon, load average | `host_processor_info`, `sysctl hw.perflevel*` |
| Memory | Pressure level, used / wired / compressed / app, swap used | `host_statistics64` (`vm_statistics64`), `kern.memorystatus_vm_pressure_level`, `vm.swapusage` |
| Disk | Capacity, available (incl. purgeable), read/write throughput | `URLResourceValues.volumeAvailableCapacityForImportantUsage`, IOKit `IOBlockStorageDriver` stats |
| Battery | %, charging state, health (max/design capacity), cycle count | `IOPSCopyPowerSourcesInfo`, IORegistry `AppleSmartBattery` |
| Network | Upload / download throughput | `getifaddrs` + `if_data` |
| Processes | Top N by CPU and by memory footprint | `proc_listpids`, `proc_pid_rusage` (`ri_phys_footprint`) |
| Thermal | Nominal / fair / serious / critical | `ProcessInfo.thermalState` |

**Sampling:** 2 s while popover or window is visible; 30 s in background.
**History:** 7 days in SQLite/SwiftData with downsampling (raw 1 h → per-minute 24 h → per-15-min 7 d).

### 6.2 Health Score (0–100)

Transparent weighted score; tapping it shows each component's deduction.

| Component | Weight |
|---|---|
| Disk free space | 30 |
| Memory pressure + swap | 30 |
| Sustained CPU load | 15 |
| Thermal state | 10 |
| Battery health | 15 (redistributed proportionally on desktops without battery) |

Weights and thresholds live in a config file and will be tuned after real use.

### 6.3 Smart Scan (one click)

A single scan covering three areas:

1. **Disk:** evaluates every cleanup rule and reports reclaimable size per group.
2. **Memory:** lists apps with the largest footprint and estimated savings if quit.
3. **Health issues:** low disk, high swap, battery degradation, thermal throttling.

**Flow:** `Smart Scan` → live progress (groups stream in) → report (total GB, groups, drill down to files) → `Clean` → result screen (freed GB, **Undo**, **Show in Trash**). The scan can be cancelled at any time. Later scans may reuse results for unchanged directories when that is faster.

### 6.4 Cleanup tiers

| Tier | Default | Rules (MVP) |
|---|---|---|
| **Safe** | Pre-checked | `~/Library/Caches/*`, `~/Library/Logs/*`, browser caches, Xcode `DerivedData`, old Xcode `Archives`, unavailable simulators (`xcrun simctl delete unavailable`), Homebrew / npm / pnpm / yarn / pip / CocoaPods / Gradle caches, Trash |
| **Review** | Shown, unchecked | `node_modules` in projects untouched > 90 days, Downloads older than 30 days, `.dmg`/`.pkg` installers, old Xcode archives, old iOS device backups, unavailable simulators, Empty Trash |
| **Never** | Always excluded | `~/Documents`, `~/Desktop`, Photos library, Mail data, iCloud Drive, anything outside declared rule paths |

**Large files:** files > 1 GB are listed for manual review only, never auto-selected.

### 6.5 Removal semantics

Each rule declares an `action`:

| Action | Used for | Reversible | Frees space immediately |
|---|---|---|---|
| `delete` | Safe-tier **regenerable** caches (`~/Library/Caches`, DerivedData, npm/brew/pip/… caches, logs) | No (tools regenerate them) | Yes |
| `trash` | Review tier, large files, Downloads, installers, backups | Yes (Undo / Show in Trash) | No, until Trash is emptied |
| `builtin` | Swift-implemented actions (`simctl delete unavailable`, Empty Trash) | No, warned explicitly | Yes |

- `delete` is allowed **only** on rules with `tier: safe` and `regenerable: true`. The validator rejects any other combination.
- **Empty Trash** is a separate, unchecked item labelled "cannot be undone".
- `trash` uses `FileManager.trashItem(at:resultingItemURL:)` and records the resulting URL so the item can be restored.
- Every operation goes to an append-only history log: path, size, rule id, action, timestamp, resulting URL.
- The result screen shows two lines: **"Freed X GB"** (delete + builtin) and **"Y GB moved to Trash (restorable)"** with *Undo* and *Empty Trash* buttons.

### 6.6 Memory assistance (honest RAM)

- Primary indicator: **memory pressure** (green/yellow/red), plus swap and compressed memory.
- Suggests "Quit *App* to free ≈ X GB" with one-click `NSRunningApplication.terminate()`. Force quit requires a second confirmation.
- `purge` is an **advanced, opt-in** action that requires an admin password and comes with an explanation that its effect is temporary.

### 6.7 Declarative cleanup rules

Rules ship inside `OsinCore` as one ordered JSON array (`Packages/OsinCore/Sources/OsinCore/Rules/rules.json`).
They contain **paths and patterns only, never commands**. Earlier rules claim items first.

```json
{
  "id": "xcode.derived-data",
  "name": "Xcode DerivedData",
  "detail": "Build intermediates and indexes. Xcode rebuilds them on the next build.",
  "tier": "safe", "action": "delete", "regenerable": true,
  "paths": ["~/Library/Developer/Xcode/DerivedData/*"],
  "minAgeDays": 0
}
```

A rule can instead `find` directories by name below some roots (used for `node_modules`), with a maximum depth.

The rule engine must:

- Expand `~` only, with no environment variables or shell expansion.
- Resolve symlinks and reject any target that escapes the rule's allowed root.
- Always apply the **Never** tier as a global deny-list after rule matching.
- Skip files that are open or locked, and report them instead.

Remote rule updates are out of scope for MVP.

### 6.8 Permissions

- **User-space only.** No privileged helper daemon in the MVP.
- **Full Disk Access** is optional. Onboarding explains why it is needed and links to System Settings. Without it, protected locations are skipped and the report shows them as "needs access".
- Root-only actions (`purge`, system caches, TM snapshots) ask for the admin password per action through Authorization Services.

### 6.9 Background & notifications

- Launch at login via `SMAppService.mainApp`, off by default and offered during onboarding.
- Notifications (thresholds configurable):
  - disk free < 10%
  - memory pressure red for > 1 min
  - battery health < 80%
  - weekly "≈ X GB reclaimable" nudge (opt-in)
- **No scheduled auto-clean.**

### 6.10 Onboarding (first run)

1. Welcome and the three promises: no permanent deletes, no telemetry, honest RAM.
2. Full Disk Access (optional, skippable).
3. Launch at login and notification permission.

### 6.11 Privacy & updates

No analytics or crash reporting SDKs. Sparkle checks a GitHub-hosted appcast; the check can be disabled entirely.

## 7. UX

### 7.1 Visual direction — hybrid

- Native chrome: sidebar, toolbar, Settings, SF Symbols, system colours, Liquid Glass on macOS 26.
- Signature elements: an animated **Health Score ring**, one brand accent colour, and bold numeric typography (SF Pro Rounded for scores, SF Mono for live numbers).

### 7.2 Menu bar item

The default is the app glyph with a health-coloured dot. Optionally it can also show 1–3 live metrics as text or a mini sparkline.

### 7.3 Popover (~360 × 520)

1. Header: Health Score ring + one-line status ("All good" / "Disk almost full").
2. 2 × 2 tiles: CPU, Memory pressure, Disk, Battery, each with a 60 s sparkline.
3. Action card: "≈ 12.4 GB reclaimable" + **Smart Scan** button.
4. Top 3 resource-hungry processes, each with a Quit button.
5. Footer: Open Dashboard · Settings · Quit Osin.

### 7.4 Dashboard sidebar

Overview (score breakdown, 1 h / 24 h charts) · Smart Scan · Storage (groups + large files) · Memory · Processes · Battery · History (cleanup log with Undo).

### 7.5 Motion

Motion is restrained, with three signature moments:

1. The score ring animates in when the popover opens.
2. Scan groups reveal progressively during a scan.
3. The freed-GB counter counts up after a clean.

All other transitions are springs of ≤ 250 ms. Reduce Motion is respected, and nothing loops indefinitely while the app runs in the background.

## 8. Architecture

```
osin/
├── Packages/OsinCore/        # Swift Package, no UI dependency, fully unit-tested
│   ├── Metrics/              # samplers (CPU, Memory, Disk, Battery, Network, Process, Thermal)
│   ├── Health/               # score engine + config
│   ├── Cleanup/              # rules, protected paths, scanner, cleaner, built-ins, log
│   ├── Rules/rules.json      # bundled rules
│   └── Storage/              # metrics history (SQLite/SwiftData)
├── Osin/                     # SwiftUI app: MenuBarExtra, popover, dashboard, settings, onboarding
└── docs/
```

- Swift 6 strict concurrency. Samplers are actors that publish via `AsyncStream`, and UI state uses `@Observable`.
- A CLI (`osin scan`, `osin clean --safe`) and a widget in v2 will reuse `OsinCore`.

## 9. Definition of done (v0.1)

- [ ] Osin memory footprint < 50 MB; background CPU < 0.5% (measured with Instruments on M1).
- [ ] Smart Scan of a typical home directory completes in < 30 s on M1.
- [ ] Fixture-based tests prove:
  - no file outside rule paths is touched
  - symlinks cannot escape allowed roots
  - the Never tier is always excluded
- [ ] Every `trash` action in the current session can be undone; `delete` only ever hits regenerable safe-tier caches (enforced by validator + tests).
- [ ] EN + VI strings complete; VoiceOver labels on all controls; Reduce Motion respected.
- [ ] Universal build passes CI; DMG notarized (or documented unsigned workaround for pre-releases).

## 10. Open questions

1. Final product name, decided before public release.

## 11. Out of scope (v2+)

Docker prune · Time Machine local snapshots · weekly reclaimable nudge · CLI · widgets · temperature / fan / GPU (SMC) · app uninstaller with leftovers · duplicate finder · disk treemap · privileged helper daemon · remote rule updates.
