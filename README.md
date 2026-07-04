# Barkeep

A macOS 26 (Tahoe)-only menu-bar manager, forked from [Ice](https://github.com/jordanbaird/Ice) (GPL-3.0 — see `LICENSE` / `NOTICE.md`). As a GPL-3.0 derivative, Barkeep's source is offered under GPL-3.0 if distributed.

Goal: be *more stable on the newest macOS* than Bartender.

## Download
Grab **Barkeep-v0.1.0-macos.zip** from [Releases](https://github.com/BozhengLong/Barkeep/releases/latest), unzip, and move `Barkeep.app` to `/Applications`.

Barkeep is **ad-hoc signed, not Apple-notarized**, so macOS Gatekeeper blocks the first launch. Bypass it once:
- Right-click `Barkeep.app` → **Open** → **Open** in the dialog, **or**
- `xattr -dr com.apple.quarantine /Applications/Barkeep.app`

Then grant **Accessibility** + **Screen Recording** in System Settings → Privacy & Security, and relaunch (Screen Recording only takes effect on the next launch). Prefer to build it yourself? See **Build** below.

## Known limitations
macOS 26 (Tahoe) renders the whole menu bar through a single system process
(Control Center), so every item — including third-party ones — reports the same
owner and often no distinct title. Barkeep works around this to hide/show items
and to render the bar with correct icons, but **per-item state may not persist
reliably across app restarts**: it can't always tell two otherwise-identical
third-party items apart by identity. Hiding and showing work within a session;
remembering exactly which items were hidden across relaunches is not fully solved
yet. (This is the same hard problem that led Bartender to add a dedicated helper
process on Tahoe.)

## Requirements
- macOS 26 (Tahoe), Xcode 26+, Apple Silicon.

## Build (no signing needed to verify compilation)
```bash
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Test
```bash
xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' \
  -only-testing:IceTests test CODE_SIGNING_ALLOWED=NO
```
`CODE_SIGNING_ALLOWED=NO` is required for local test runs: the project still
carries upstream Ice's `DEVELOPMENT_TEAM`, which you can't sign as. On Apple
Silicon the linker applies an ad-hoc signature, which is enough to run unit tests.

## Run the app
Open `Ice.xcodeproj` in Xcode → select the **Ice** target → **Signing & Capabilities**
→ set **Team** to your personal Apple ID (replaces upstream's team) → ⌘R.
Then grant **Accessibility** + **Screen Recording** in System Settings → Privacy & Security
and relaunch.

## Layout
- `Ice/Bridging/` — the ONLY place private SkyLight/CGS APIs may appear.
- `IceTests/` — XCTest target; `BridgingTests` guards the private-API contract per OS build
  (the seed of the P1 stability harness).

## Notes
- Internal Xcode target/scheme stays named "Ice"; the product name is Barkeep and
  the bundle id is `com.spidey0o0zheng.Barkeep`. Deployment target stays macOS 14
  (the legacy window-capture API Barkeep relies on is unavailable when targeting 26).
- Forked from Ice by Jordan Baird. See `NOTICE.md`.
