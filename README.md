<p align="center">
  <img src="docs/images/icon.png" width="112" height="112" alt="">
</p>

<h1 align="center">Osin</h1>

<p align="center">
  <b>An honest health monitor and cleaner for your Mac.</b><br>
  Lives in the menu bar. Free, open source, no telemetry.
</p>

<p align="center">
  <a href="https://github.com/Vigentix/osin/releases/latest"><img src="https://img.shields.io/github/v/release/Vigentix/osin?label=release&color=6B5AF7" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple&logoColor=white" alt="macOS 14 or later">
  <a href="https://github.com/Vigentix/osin/actions/workflows/ci.yml"><img src="https://github.com/Vigentix/osin/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Vigentix/osin?color=blue" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-you-get">What you get</a> ·
  <a href="#safety-guarantees">Safety</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
  <img src="docs/images/overview-light.png" alt="Osin Overview: a health score of 78 because the disk is 90% full, 14.52 GB that can be cleaned safely, live CPU, memory, disk, network and battery, the heaviest apps and a storage breakdown">
</picture>

Osin tells you how your Mac is doing in plain language, frees disk space without guesswork, and keeps the Mac awake while it works for you. One **Smart Scan → Review → Clean** flow finds what is safe to remove, shows you exactly what it found, and only deletes data that rebuilds itself. Everything else goes to the Trash, where you can restore it.

It also refuses to play the "free up RAM" game. Unused memory is wasted memory, so Osin watches memory pressure, the signal macOS itself uses, and tells you which app to quit when pressure is actually high.

## Install

With [Homebrew](https://brew.sh):

```sh
brew tap vigentix/tap
brew trust vigentix/tap      # recent Homebrew versions ask you to trust third-party taps
brew install --cask osin
```

Or download `Osin-x.y.z.dmg` from [Releases](https://github.com/Vigentix/osin/releases/latest) and drag Osin to Applications.

Requires macOS 14 Sonoma or later, on Apple Silicon or Intel. English and Vietnamese.

<details>
<summary><b>First launch: macOS says it cannot verify Osin</b></summary>

<br>

Releases are not notarized yet, so macOS blocks the first launch:

1. Open Osin once and close the warning.
2. Go to **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to Osin and confirm with your password.

On macOS 15 and later, right-click › Open no longer bypasses this warning. To skip it entirely, remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Osin.app
```

</details>

## What you get

<table>
  <tr>
    <td width="58%" valign="top">
      <h3>Health at a glance</h3>
      <p>Click the menu bar icon for a health score with the reason behind it ("Disk almost full"), CPU, memory pressure, disk, battery and network, plus the apps using the most memory. Clean in one click or jump to the dashboard.</p>
      <p>The icon's dot turns yellow or red when something needs attention. CPU, memory and network can also be shown as live text in the menu bar.</p>
      <p>Optional notifications when the disk is almost full, memory pressure stays critical, or the battery is wearing out. Osin never cleans on its own unless you schedule chores.</p>
    </td>
    <td width="42%" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/popover-dark.png">
        <img src="docs/images/popover-light.png" width="330" alt="Menu bar popover: health score, Clean button, CPU, memory, disk and battery tiles, network speed and heaviest apps">
      </picture>
    </td>
  </tr>
</table>

### Keep Awake while your Mac works

Leave a build, a download, a backup or a long script running without the Mac falling asleep. Choose to keep the screen on, or lock it right away while everything keeps running, and decide for how long: until you stop it, on a timer, until a time such as 7:00, or **until a command or app finishes**: pick `rsync`, `xcodebuild` or `python3 train.py` from the list and the Mac may sleep again once it ends.

<table>
  <tr>
    <td width="58%" valign="top">
      <p>Safety rules stop it when the battery runs low or the Mac gets hot, and you can limit it to when the power adapter is connected. You get a notification when it ends, with the reason.</p>
      <p>Keep Awake only prevents idle sleep. Closing the lid still sleeps the Mac (unless an external display is connected), and no app can block a forced restart. If a macOS update is waiting to install automatically, Osin warns you that the Mac may restart overnight.</p>
      <p>Turn it on from the menu bar, or set a global shortcut in Settings.</p>
    </td>
    <td width="42%" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/keepawake-dark.png">
        <img src="docs/images/keepawake-light.png" width="330" alt="Keep Awake options: keep the screen unlocked or lock it, keep the display on, and choose until you stop, a timer, a time of day or until a command finishes">
      </picture>
    </td>
  </tr>
</table>

### Chores, a weekly report and a watchful eye

<table>
  <tr>
    <td width="58%" valign="top">
      <p><b>Scheduled chores</b> clear caches and logs every day, week or month (off until you turn it on in Settings › Chores). They run only while the Mac is plugged in and you have been away for five minutes, catch up within a day if the Mac was asleep, and never touch the Trash, simulators or Downloads. You get a notification with what was freed, and every item is in History.</p>
      <p><b>A weekly report</b> arrives on Monday morning: average health and how it changed, what Osin cleaned, how long memory was strained or the disk ran low, the busiest apps, Keep Awake hours and what to do next.</p>
      <p><b>Watch</b> tells you when an app stays above 80% CPU for five minutes or grows by 2 GB in half an hour, at most once a day per app, with buttons to quit it or ignore it from then on.</p>
    </td>
    <td width="42%" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/weekly-report-dark.png">
        <img src="docs/images/weekly-report-light.png" width="330" alt="Weekly report: average health 84, up 5, with a trend of eight weeks, space freed, scheduled cleanups, Keep Awake hours, memory strain, the busiest apps and a suggestion">
      </picture>
    </td>
  </tr>
</table>

### Smart Scan you can read before you click

Osin looks where space actually goes on a developer's Mac:

- **Caches:** Xcode DerivedData and device support files, app caches and logs, package-manager and developer-tool caches (npm, pnpm, Gradle, Cargo, uv, Bun, Maven, Yarn, pip…), and the page and script caches of browsers and desktop apps such as Chrome, Edge, Brave, Arc, Slack and VS Code. Browser and app caches wait until that app is closed.
- **Docker:** the build cache, untagged images and unused volumes, through the `docker` command itself. Afterwards Osin can trim Colima's virtual disk so macOS gets the space back.
- **Cold projects:** `node_modules`, `.venv`, `target`, `.next`, `Pods` and similar folders, in projects with no commits or edits for 30 days. Add your own project folders in Settings.
- **Leftovers:** Node, Python and Rust versions no default or project uses, Claude Code and Codex sessions untouched for 90 days, Chrome's on-device AI model, websites' offline storage, app updates that were downloaded but not installed, installers and old files in Downloads, unavailable simulators and the Trash.

Results are split into **Safe to clean** (selected for you) and **Needs your review** (never selected unless you choose), with every item listed and sizes measured on disk.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/cleanup-dark.png">
  <img src="docs/images/cleanup-light.png" alt="Smart Scan report: safe groups such as Xcode DerivedData, app caches, developer tool caches, browser caches (part of it waiting for Chrome to close) and Docker's build cache are selected; cold projects, installers, unavailable simulators and Empty Trash wait for review">
</picture>

### Space Lens: see where the rest went

For everything no rule knows about, Space Lens measures your home folder (about a minute) and shows it as a treemap and a list you can drill into. Well-known folders come with a plain explanation, such as "uv cache: rebuilt automatically" or "Docker's virtual disk: clean Docker in Smart Scan, then trim". Anything that is safe to remove can go to the Trash from there; system folders and protected locations cannot. Folders macOS guards are skipped unless Osin has Full Disk Access.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/space-lens-dark.png">
  <img src="docs/images/space-lens-light.png" alt="Space Lens: a treemap of the home folder with Developer, Library and .colima as the largest blocks, and a list with sizes and explanations">
</picture>

### Activity that groups apps with their helpers

Browser tabs, language servers and build services are counted with the app they belong to, so the numbers match what you can actually quit. Sort by memory or CPU, inspect the largest processes of an app, and quit it from the same place. System processes are listed but never offered for quitting.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/activity-dark.png">
  <img src="docs/images/activity-light.png" alt="Activity: apps grouped with their helper processes, CPU and memory bars, and an inspector showing Xcode's memory over time and its largest processes">
</picture>

### History for the last hour, day and week

CPU per core, memory pressure with its breakdown, disk throughput, network and battery charge, stored locally for seven days and downsampled so the database stays small.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/system-dark.png">
  <img src="docs/images/system-light.png" alt="System: one-hour charts for CPU with per-core bars, memory pressure with app, wired, compressed and cached memory, disk read and write, network download and upload, and battery charge">
</picture>

<sub>Screenshots use built-in demo data (`make screenshots`), not a real Mac.</sub>

## Safety guarantees

Osin removes files on your Mac, so these rules are enforced in code and covered by tests that run against throwaway folders:

1. **Only regenerable caches are deleted.** Everything else goes to the Trash and can be restored from the result screen or from History.
2. **Nothing outside the [rules](Packages/OsinCore/Sources/OsinCore/Rules/rules.json) is touched.** Rules are data (paths and patterns, never commands) and are limited to your home folder.
3. **Protected locations are never cleaned:** Documents, Desktop, Pictures, Movies, Music, Mail, iCloud Drive, Messages, Keychains, Safari data, `.ssh`, system folders, and any folder that contains them.
4. **Symlinks are never followed**, and every item is checked again right before it is removed.
5. **Unavailable simulators, Empty Trash and Docker images or volumes cannot be undone.** They are never preselected, and Osin warns you before running them.
6. **Every action is logged** in `~/Library/Application Support/Osin/cleanup-log.jsonl`.
7. **Scheduled chores only run Safe groups you ticked**, never irreversible ones, and only while you are away from the Mac. New groups stay off until you turn them on.
8. **Apps are never cleaned while open:** browser and app caches wait until the app is closed, and cold projects are checked again right before cleaning.

Osin runs in user space: no privileged helper, no kernel extension. Full Disk Access is optional and only lets the scan reach folders macOS protects, such as old device backups. The one admin action, `purge` in Settings › Advanced, asks for your password every time and explains why its effect is temporary.

## Privacy

No accounts, no analytics, no crash reporting. Metrics history and the cleanup log stay on your Mac. The only network request is the update check, which you can turn off in Settings.

## Build from source

```sh
git clone https://github.com/Vigentix/osin.git
cd osin
make bootstrap   # installs XcodeGen, SwiftLint, SwiftFormat; generates Osin.xcodeproj
make open        # opens Xcode, then run the "Osin" scheme
```

| Command | What it does |
|---|---|
| `make test` | `OsinCore` unit and integration tests |
| `make build` / `make build-release` | Debug build / universal release build (unsigned) |
| `make lint` / `make format` | SwiftFormat + SwiftLint |
| `make l10n-check` | Fails if a UI string is missing from the String Catalog |
| `make snapshots` | Renders every screen with your live data to `build/snapshots` (Debug only) |
| `make screenshots` | Renders the README screenshots with demo data to `docs/images` |
| `scripts/release.sh 0.1.0` | DMG + Sparkle ZIP; see [docs/RELEASING.md](docs/RELEASING.md) |

```
Osin/                 SwiftUI app: menu bar, dashboard, Smart Scan, settings, onboarding
Packages/OsinCore/    UI-free core: metrics sampler, health score, history, rules, scanner, cleaner
docs/                 PRD, roadmap, architecture decisions, release guide, README images
packaging/homebrew/   Homebrew cask
```

Design decisions are recorded in [docs/adr](docs/adr), and what comes next is in the [roadmap](docs/ROADMAP.md).

## Contributing

Bug reports, rule ideas and translations are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Adding a cleanup rule for a tool you use is a good first contribution: rules are plain JSON and the safety checks run on every rule.

## License

[GPL-3.0](LICENSE)
