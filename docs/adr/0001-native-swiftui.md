# ADR 0001 — Native Swift + SwiftUI

**Status:** Accepted

## Context
Osin monitors system resources and helps reduce memory pressure. It needs low-level APIs (Mach, IOKit, sysctl, libproc) and must have a tiny footprint.

## Decision
Build with Swift 6 + SwiftUI. Do not use Electron or Tauri.

## Consequences
- The app uses about 30–60 MB of RAM and calls system APIs directly with no bridging layer.
- Web design skills are used only to produce mockups, which are then reimplemented in SwiftUI.
- Contributors need Xcode and Swift knowledge.
