# Barkeep

A macOS 26 (Tahoe)-only menu-bar manager, forked from [Ice](https://github.com/jordanbaird/Ice) (GPL-3.0 — see `LICENSE` / `NOTICE.md`). As a GPL-3.0 derivative, Barkeep's source is offered under GPL-3.0 if distributed.

Goal: be *more stable on the newest macOS* than Bartender.

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
- Internal Xcode target/scheme stays named "Ice"; only the bundle id
  (`com.spidey0o0zheng.Barkeep`) is changed so far. Display rename (`PRODUCT_NAME`)
  and the deployment-target bump to 26.0 are deferred (see the design doc / P0 plan).
- Forked from Ice by Jordan Baird. See `NOTICE.md`.
