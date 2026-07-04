# Per-Item Persistence on Tahoe — Design

_Date: 2026-07-04 · Status: approved (direction approved in conversation; sections not line-reviewed by user)_

## Problem

On macOS 26 (Tahoe), the entire menu bar is rendered by Control Center, so every
third-party item reports namespace `com.apple.controlcenter` and usually a generic
title like `Item-0`. Barkeep's identity model (`MenuBarItemInfo` = bundle id + title)
therefore cannot tell most third-party items apart.

Barkeep has **no persisted per-item hidden state at all**: hidden = physically left of
the hidden-section divider (a Barkeep `NSStatusItem`). Cross-restart memory relies
entirely on macOS restoring status item positions. On Tahoe this is unreliable — the
result is that after Barkeep restarts, the hidden/visible assignment of third-party
items can be wrong.

The exact failure mode has **not** been systematically reproduced yet (known
limitation + sporadic observation). Diagnosis is therefore Phase 0 of this work.

## Scope and constraints (from clarifying questions)

- **Primary scenario**: Barkeep itself restarts while the system keeps running.
  Mac reboot/login is best-effort bonus, not a requirement.
- **Constraints**: single process, no new permissions, minimal private API
  (existing bridging SPI level is the ceiling).
- **Safety rule**: an item whose identity can't be resolved must end up VISIBLE.
  Failure may over-show, never wrongly hide.

## Key insight

When Barkeep quits, third-party item windows are not destroyed (they belong to
Control Center / their owning apps). So `CGWindowID` should be stable across a
Barkeep restart — making it a strong primary identity signal for the primary
scenario. (Must be confirmed in Phase 0.) The suspected failure point is divider
re-insertion position on relaunch, which shifts the "left of divider = hidden"
classification wholesale.

## Architecture

Two phases; one new component plus small hook points.

### Phase 0 — Diagnostic harness

`Ice/Utilities/LayoutDiagnostics.swift`, a static `dump(label:appState:)` that
appends a timestamped block to `/tmp/barkeep_diag.txt` (project rule: no os_log for
diagnostics). Gated by a defaults flag `LayoutDiagnosticsEnabled`, default off,
kept in the codebase long-term.

Each dump records:
- one line per menu bar item window: `windowID | title | ownerName | ownerPID |
  frame | on-screen order | current section classification` (section from
  `itemCache`, dumped after cache rebuild);
- Barkeep's own control items: windowID, frame, and raw
  `StatusItemDefaults[.preferredPosition]` values;
- the raw window order from `Bridging.getWindowList(option: [.menuBarItems, .activeSpace])`.

Trigger points (one-line calls): after first `cacheItemsIfNeeded` on launch
(`post-launch-cache`), in `applicationWillTerminate` (`will-terminate`), and on
cache rebuilds (`cache-rebuilt`).

Experiment protocol (manual, Xcode ⌘R): set a known layout → dump A; quit → dump B;
relaunch → dump C. Compare B↔C for: windowID stability, divider landing position vs
preferred position, third-party order drift.

Exit criteria — answer three questions and set Phase 1 matcher weighting:
1. Are third-party windowIDs stable across Barkeep restart?
2. Is the divider re-inserted where preferred position says?
3. Does relative item order drift?

If windowIDs are stable and the failure is divider misplacement, windowID is the
primary matcher and fingerprints are secondary (thin implementation). If windowIDs
turn out unstable, fingerprints are promoted to primary (thicker implementation,
same architecture).

### Phase 1 — Layout snapshot + restore

New `MenuBarItemPersistenceManager` (single file, owned by `AppState`):
- **Write**: subscribes to `$itemCache`, debounces 1 s, persists a snapshot to
  `Defaults` key `MenuBarItemLayoutSnapshotV1`.
- **Read**: once per session, after the first successful cache build on launch,
  matches reality against the snapshot and corrects section membership using the
  existing `move(item:to:)` machinery.

Existing code changes are limited to: `AppState` wiring, launch-sequence trigger,
`applicationWillTerminate` final write, and diagnostic dump calls. No changes to
existing caching/moving logic.

## Snapshot data model

```swift
struct MenuBarLayoutSnapshot: Codable {
    var capturedAt: Date
    var visible: [ItemSnapshot]       // left-to-right on-screen order per section
    var hidden: [ItemSnapshot]
    var alwaysHidden: [ItemSnapshot]
}

struct ItemSnapshot: Codable {
    var windowID: CGWindowID     // primary signal (Barkeep-restart scenario)
    var info: String             // "namespace:title" — reliable pre-Tahoe, weak on Tahoe
    var iconFingerprint: String? // perceptual hash of icon bitmap, secondary signal
    var width: CGFloat           // auxiliary signal
}
```

- Scope: managed third-party items only. Excludes Barkeep's control items,
  `immovableItems` (Clock/Siri/BentoBox), and `nonHideableItems`.
- Temp-shown items need no special handling: snapshots read `itemCache`, which
  already records them in their home section (`uncheckedCacheItems`).
- Icon fingerprint: perceptual hash (downscale to 16×16, grayscale threshold bit
  string) — tolerant of light/dark and tint changes, unlike exact pixel hashes.
  Computed via the existing capture pipeline; `nil` if capture fails (never blocks
  a snapshot write). Cost control: fingerprints are recomputed only when the
  windowID set changes; pure reorders reuse existing fingerprints.
- Write skips: never write while the cache is empty (protects the good snapshot
  from error-path `itemCache.clear()`); never write while a restore is running.
- `applicationWillTerminate` performs one final synchronous write.

## Restore flow and matching

Runs once per session (`hasRestoredThisSession` guard): after first successful
cache with the hidden control item present → `waitForItemsToStopMoving` → restore.

Matching is three greedy passes over (snapshot entries × current managed items),
each pass only touching unmatched items:

| Pass | Signal | Hit condition |
|------|--------|---------------|
| 1 | `windowID` | exact equality (expected ~100% for primary scenario) |
| 2 | `info` | bidirectionally unique: info occurs exactly once in the snapshot AND exactly once among current items (Tahoe `Item-0` swarms auto-skip; pre-Tahoe and genuinely-titled items land here) |
| 3 | icon fingerprint | Hamming distance ≤ threshold (initial: ≤ 10% of hash bits, i.e. 25 of 256; tuned against Phase 0 captures) AND bidirectional best unique match |

Unmatched current items are left where they are; unmatched snapshot entries are
dropped. Net effect is fail-visible.

Correction:
- For each matched item, compare snapshot section vs current section (from
  `itemCache`). If different, `move(item:to:)`: hidden →
  `.leftOfItem(hiddenControlItem)`, alwaysHidden →
  `.leftOfItem(alwaysHiddenControlItem)`, visible → `.rightOfItem(hiddenControlItem)`.
- **Section membership only — intra-section ordering is NOT restored** (cosmetic;
  cost/risk of drag-based reordering is not worth it).
- Sequential, awaited one by one. Per-item failure (existing `EventError`
  timeouts): log, skip, continue. No retry, no rollback.
- Afterwards trigger `cacheItemsIfNeeded`, then release the snapshot-write lock so
  the new reality becomes the new snapshot.

Guards:
- Immovable/non-hideable items are never snapshotted, so never moved.
- User drag during restore: existing move-conflict detection fails that item's
  move → skip path; never fight the user.
- Login-launch (items appearing gradually): benign degradation only — unmatched
  items untouched, snapshot not overwritten until restore completes + debounce.
  Re-running restore when new windowIDs appear within the first N seconds is
  explicitly future work, out of scope.
- Logging: new `Logger` category `persistence`; when the diagnostics flag is on,
  match results and per-move outcomes also go to `/tmp/barkeep_diag.txt`.

## Testing

Unit tests (existing `IceTests` target):
- The matcher is extracted as a pure function (snapshot entries + current item
  descriptors in, match results out; no real windows). Tests: windowID hits;
  info bidirectional-uniqueness rules (`Item-0` swarms must all miss, unique
  titles must hit); fingerprint threshold behavior (ambiguous → no match);
  mixed scenarios where misses produce no move commands; stale snapshot entries
  silently dropped.
- Perceptual hash: synthetic bitmap fixtures — same glyph under different
  tint/appearance within threshold, different glyphs beyond it.
- Snapshot codec round-trip, including `iconFingerprint: nil` and
  missing-field tolerance.
- Write-decision function (empty cache → no write; restoring → no write).

Manual acceptance (real menu bar can't run in CI; reuses the Phase 0 protocol):
1. Main path: hide 2-3 third-party items → stop → ⌘R → hidden set fully restored;
   diag file shows 100% match.
2. Edges: new item appeared while Barkeep was off (must land visible); hidden
   item's app quit while Barkeep was off (no residue, no mis-hide).
3. Adversarial: manual drag during restore → single-item skip, no fighting.

Acceptance criteria (scope A): with no system restart, after a Barkeep restart the
section membership of managed items is restored 100%; any failure may only
over-show, never wrongly hide.

## Build/test commands

```bash
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' \
  -only-testing:IceTests test CODE_SIGNING_ALLOWED=NO
```
