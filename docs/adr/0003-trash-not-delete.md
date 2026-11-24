# ADR 0003 — Delete only regenerable caches; everything else goes to Trash

**Status:** Accepted

## Context
Deleting the wrong file is the biggest risk for a cleaner app. However, moving items to the Trash does not free space until the Trash is emptied, so a Trash-only design fails the core job of "my disk is full". The "Empty Trash" action is itself a permanent delete.

## Decision
Each rule declares one action:
- `delete`: permanent. Allowed only for rules marked `tier: safe` and `regenerable: true` (caches, logs, DerivedData, package manager caches). The validator enforces this.
- `trash`: `FileManager.trashItem(at:resultingItemURL:)` with the resulting URL recorded so Undo works. Used for the Review tier, large files, Downloads, installers and backups.
- `builtin`: Swift-implemented commands (simctl, Docker, TM snapshots). Always in the Review tier with an irreversible warning.

"Empty Trash" is a separate, unchecked item that warns it cannot be undone. The result screen separates "Freed X GB" from "Y GB in Trash (restorable)".

## Consequences
- Space is reclaimed immediately for the common case.
- Personal or ambiguous files remain restorable.
- Losing a cache costs at most one slower rebuild.
- The safety guarantee shifts to the validator plus the fixture tests that check every `delete` rule targets regenerable data only.
