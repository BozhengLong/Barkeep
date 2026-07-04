# Phase 0 Findings — Per-Item Persistence Diagnostics

_Date: 2026-07-04 · Data: /tmp/barkeep_diag.txt (two sessions, one clean quit + relaunch cycle) · Hardware: macOS 26 Tahoe, Control Center pid 766_

## The three Phase 0 questions

**Q1 — Are third-party windowIDs stable across a Barkeep restart? YES, 100%.**
will-terminate (15:21:26) vs first post-relaunch cache (15:22:06): all 24
third-party windowIDs identical (165, 13750, 16397, 23201, 147, 3982, 135, 1125,
163, 71, 67, 36, 69, 38, 218, 211, 27000, 181, 6839, 27621, 27047, 156, 39, 37).
Only Barkeep's own control items got new IDs (SItem 28035→28070, HItem
28037→28072) — expected, they're destroyed on quit and recreated on launch.

**Q2 — Does the divider land where preferredPosition says? YES (this run).**
HItem re-inserted at the identical frame (-4061, width 5016);
preferredPosition[HItem]=559 unchanged across the restart.

**Q3 — Does relative item order drift across restart? NO.**
Raw window order and all frames pixel-identical across the quit/relaunch
boundary; section classifications identical. Hidden items stayed hidden.

## Revised failure-mode understanding (the important part)

Cross-restart persistence was NOT broken in this experiment. The instability
users experience comes from **within-session** failures:

1. **Mass reclassification during divider animation.** 15:05:18 → 15:05:24
   (6 s apart): nearly every item flipped visible→hidden because the cache was
   rebuilt while HItem was mid-resize (2740 wide at x=-2875 → 5016 wide at
   x=-4013). Any snapshot written from such a transient state would poison
   persistence. Post-relaunch drag at 15:22:27 shows the same effect (HItem
   preferredPosition 559→591, several right-side items reclassified hidden).

2. **Move verification false-timeout.** User dragging an item in the Layout
   pane gets "Operation timed out for Item-0" — but the raw window order proves
   the move SUCCEEDED (wid 6839 relocated at 15:05:18; wid 147 at 15:22:27).
   The post-move verification (`waitForFrameChange` / `itemHasCorrectPosition`
   path in MenuBarItemManager) fails to observe the change on Tahoe.

3. **Info-keyed lookups collide.** ~14 of 24 items share info
   `(com.apple.controlcenter, "Item-0")`. Any in-session logic that matches by
   `info` — `ItemCache.section(for:)`, `firstIndex(matching:)` in the temp-show
   return path — can pick the wrong item. Confirmed user-visible bug: clicking
   a hidden item in the Ice Bar temp-shows it, and it then stays visible
   permanently (return-move loses track of the item).

4. **Transient items churn windowIDs.** AudioVideoModule (screen recording
   indicator) got a new windowID on each appearance (27487 → 27501). Stable
   items keep their IDs within and across Barkeep restarts; transient
   system indicators do not.

5. **(Separate bug, recorded) Layout pane renders white-on-white.** After
   relaunch the layout bar background renders white with white template icons
   (averageColor fallback picks up a light wallpaper), and several item images
   are missing entirely. Tracked in HANDOFF as a session bug, not persistence.

## Decisions for Phase 1

- **Matcher weighting confirmed**: windowID-primary (Pass 1), info uniqueness
  (Pass 2), fingerprint fallback (Pass 3) with Hamming threshold 25/256. No
  change to the designed matcher.
- **Snapshot write-gate must be stronger than "cache not empty".** Add: only
  persist a snapshot when the cache classification is stable across two
  consecutive rebuilds (identical windowID→section mapping), to avoid
  persisting mid-animation states.
- **Restore is blocked on the move-verification bug.** The restore path drives
  `move(item:to:)`; today that machinery falsely times out (finding 2) even
  when moves succeed. Fix the verification before (or as part of) the restore
  task, otherwise restore will report failures and/or retry moves that already
  happened.
- **Priority shift**: findings 2 and 3 are user-visible session bugs with the
  same identity root cause and are prerequisites for reliable restore. They
  move ahead of the snapshot/restore tasks in execution order.
