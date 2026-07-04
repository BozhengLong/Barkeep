# Tahoe Per-Item Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After Barkeep restarts (system stays up), every managed third-party menu bar item returns to the section (visible/hidden/always-hidden) it was in before quit.

**Architecture:** Phase 0 adds a file-based diagnostic dumper to confirm the failure mode. Phase 1 adds a `MenuBarItemPersistenceManager` that snapshots the section layout to UserDefaults on every cache change (windowID + perceptual icon hash + info per item) and, once per launch, matches reality against the snapshot with a three-pass matcher (windowID → unique info → icon fingerprint) and moves misplaced items back using the existing `move(item:to:)` machinery. Unmatched items are never moved (fail-visible).

**Tech Stack:** Swift 5 / AppKit / Combine / XCTest. No new dependencies, no new permissions.

**Spec:** `docs/superpowers/specs/2026-07-04-per-item-persistence-design.md`

## Global Constraints

- Deployment target stays **14.0**.
- Build/test always with `CODE_SIGNING_ALLOWED=NO`.
- Never `open` the built `.app` from the shell — GUI runs happen via Xcode ⌘R (ask the human to do them).
- Diagnostics write to `/tmp/barkeep_diag.txt`, NOT os_log (`log show` is unreliable for this app).
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 70): new files under `Ice/` and `IceTests/` are picked up automatically — do NOT edit `project.pbxproj`.
- Tests use **XCTest** (`import XCTest`), target `IceTests`.
- Fail-visible rule: an item that can't be confidently matched must NOT be moved.
- Build command:
  `xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test command:
  `xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' -only-testing:IceTests test CODE_SIGNING_ALLOWED=NO`

---

### Task 1: Phase 0 — LayoutDiagnostics harness

**Files:**
- Create: `Ice/Utilities/LayoutDiagnostics.swift`
- Modify: `Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift` (end of `cacheItemsIfNeeded`, ~line 355 after `uncheckedCacheItems` succeeds)
- Modify: `Ice/Main/AppDelegate.swift` (add `applicationWillTerminate`)

**Interfaces:**
- Produces: `LayoutDiagnostics.dump(label: String, appState: AppState)` (`@MainActor`), `LayoutDiagnostics.isEnabled: Bool` (defaults key `"LayoutDiagnosticsEnabled"`), `LayoutDiagnostics.formatItemLine(windowID:title:ownerName:ownerPID:frame:orderIndex:section:) -> String` (pure, testable).

- [ ] **Step 1: Write the failing test**

Create `IceTests/LayoutDiagnosticsTests.swift`:

```swift
import XCTest
@testable import Ice

final class LayoutDiagnosticsTests: XCTestCase {
    func testFormatItemLineContainsAllFields() {
        let line = LayoutDiagnostics.formatItemLine(
            windowID: 42,
            title: "Item-0",
            ownerName: "Control Center",
            ownerPID: 500,
            frame: CGRect(x: 100, y: 0, width: 32, height: 24),
            orderIndex: 3,
            section: "hidden"
        )
        XCTAssertTrue(line.contains("42"))
        XCTAssertTrue(line.contains("Item-0"))
        XCTAssertTrue(line.contains("Control Center"))
        XCTAssertTrue(line.contains("500"))
        XCTAssertTrue(line.contains("100"))
        XCTAssertTrue(line.contains("#3"))
        XCTAssertTrue(line.contains("hidden"))
    }

    func testFormatItemLineHandlesNilTitleAndOwner() {
        let line = LayoutDiagnostics.formatItemLine(
            windowID: 7,
            title: nil,
            ownerName: nil,
            ownerPID: 1,
            frame: .zero,
            orderIndex: 0,
            section: nil
        )
        XCTAssertTrue(line.contains("<nil>"))
        XCTAssertTrue(line.contains("<uncached>"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Test command from Global Constraints, filtered if desired with `-only-testing:IceTests/LayoutDiagnosticsTests`.
Expected: FAIL — `LayoutDiagnostics` not defined.

- [ ] **Step 3: Implement LayoutDiagnostics**

Create `Ice/Utilities/LayoutDiagnostics.swift`:

```swift
//
//  LayoutDiagnostics.swift
//  Ice
//

import Cocoa

/// File-based menu bar layout dumper for diagnosing Tahoe persistence issues.
///
/// Appends timestamped blocks to /tmp/barkeep_diag.txt. Off by default; enable with:
/// `defaults write <bundle id> LayoutDiagnosticsEnabled -bool YES`
@MainActor
enum LayoutDiagnostics {
    private static let filePath = "/tmp/barkeep_diag.txt"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "LayoutDiagnosticsEnabled")
    }

    /// Formats a single item line. Pure; unit-tested.
    nonisolated static func formatItemLine(
        windowID: CGWindowID,
        title: String?,
        ownerName: String?,
        ownerPID: pid_t,
        frame: CGRect,
        orderIndex: Int,
        section: String?
    ) -> String {
        let f = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height)))"
        return "#\(orderIndex) wid=\(windowID) title=\(title ?? "<nil>") owner=\(ownerName ?? "<nil>") pid=\(ownerPID) frame=\(f) section=\(section ?? "<uncached>")"
    }

    /// Dumps the full current layout state under the given label.
    static func dump(label: String, appState: AppState) {
        guard isEnabled else {
            return
        }

        var lines = ["", "===== [\(Date.now)] \(label) ====="]

        // Raw window order as the window server reports it.
        let rawIDs = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
        lines.append("raw window order: \(rawIDs)")

        // One line per item, in window list order, with cached section when known.
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let cache = appState.itemManager.itemCache
        for (index, item) in items.enumerated() {
            let section: String? = cache.section(for: item).map { name in
                switch name {
                case .visible: "visible"
                case .hidden: "hidden"
                case .alwaysHidden: "alwaysHidden"
                }
            }
            lines.append(formatItemLine(
                windowID: item.windowID,
                title: item.title,
                ownerName: item.ownerName,
                ownerPID: item.ownerPID,
                frame: item.frame,
                orderIndex: index,
                section: section
            ))
        }

        // Control item preferred positions as stored in defaults.
        for identifier in ControlItem.Identifier.allCases {
            let position: CGFloat? = StatusItemDefaults[.preferredPosition, identifier.rawValue]
            lines.append("preferredPosition[\(identifier.rawValue)]=\(position.map(String.init(describing:)) ?? "<nil>")")
        }

        appendToFile(lines.joined(separator: "\n") + "\n")
    }

    /// Appends raw text to the diagnostics file (also used by the persistence
    /// manager to log match/move outcomes).
    static func appendText(_ text: String) {
        guard isEnabled else {
            return
        }
        appendToFile(text.hasSuffix("\n") ? text : text + "\n")
    }

    private static func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        if let handle = FileHandle(forWritingAtPath: filePath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(filePath: filePath))
        }
    }
}
```

Note: if `ControlItem.Identifier` is not `CaseIterable`, add the conformance in `Ice/MenuBar/ControlItem/ControlItem.swift` (`enum Identifier: String, CaseIterable`).

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS (both tests).

- [ ] **Step 5: Hook the dump call sites**

In `Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift`, at the end of `cacheItemsIfNeeded()` (inside the `do` block, right after `uncheckedCacheItems(...)`):

```swift
            if let appState {
                LayoutDiagnostics.dump(label: "cache-rebuilt", appState: appState)
            }
```

In `Ice/Main/AppDelegate.swift`, add a new delegate method after `applicationDidFinishLaunching`:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        guard let appState else {
            return
        }
        LayoutDiagnostics.dump(label: "will-terminate", appState: appState)
    }
```

- [ ] **Step 6: Build**

Run the Build command. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Ice/Utilities/LayoutDiagnostics.swift IceTests/LayoutDiagnosticsTests.swift Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift Ice/Main/AppDelegate.swift Ice/MenuBar/ControlItem/ControlItem.swift
git commit -m "feat: file-based layout diagnostics for Tahoe persistence debugging"
```

---

### Task 2: Phase 0 — run the experiment, record findings (CHECKPOINT, human-in-the-loop)

**Files:**
- Create: `docs/superpowers/specs/2026-07-04-per-item-persistence-phase0-findings.md`

**Interfaces:**
- Produces: written answers to the three Phase 0 questions; a decision on matcher weighting (windowID-primary vs fingerprint-primary) and the fingerprint Hamming threshold.

- [ ] **Step 1: Enable diagnostics and ask the human to run the protocol**

```bash
defaults write $(defaults read /Users/spidey0o0zheng/workspace/Barkeep/Ice/Resources/Info.plist CFBundleIdentifier 2>/dev/null || echo "com.jordanbaird.Ice") LayoutDiagnosticsEnabled -bool YES
rm -f /tmp/barkeep_diag.txt
```

(If the bundle id lookup fails, find it: `grep -A1 PRODUCT_BUNDLE_IDENTIFIER Ice.xcodeproj/project.pbxproj | head -4`.)

Ask the human to: ⌘R in Xcode → hide 2–3 third-party items via cmd-drag or the Layout pane → quit Barkeep (⌘Q or stop in Xcode) → ⌘R again → wait 10 s → stop.

- [ ] **Step 2: Analyze the dump**

Read `/tmp/barkeep_diag.txt`. Compare the `will-terminate` block with the first `cache-rebuilt` block after relaunch:
1. Are third-party windowIDs identical across the restart?
2. Did the control items land at their stored `preferredPosition`?
3. Did third-party relative order change?
4. Do the `section=` classifications after relaunch match the ones before quit? (This is the bug reproducing — or not.)

- [ ] **Step 3: Write findings doc**

Create `docs/superpowers/specs/2026-07-04-per-item-persistence-phase0-findings.md` with: the four answers, raw evidence excerpts, and the decision: matcher primary signal + Hamming threshold to use in Task 5 (default stays windowID-primary, threshold 25/256 unless evidence says otherwise).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-04-per-item-persistence-phase0-findings.md
git commit -m "docs: phase 0 findings for per-item persistence"
```

**STOP after this task and review findings with the human before continuing — if windowIDs turn out stable AND sections already restore correctly, the remaining tasks may shrink to just fixing divider placement.**

---

### Task 3: IconFingerprint + PerceptualHash (pure logic)

**Files:**
- Create: `Ice/Utilities/PerceptualHash.swift`
- Test: `IceTests/PerceptualHashTests.swift`

**Interfaces:**
- Produces:
  - `struct IconFingerprint: Codable, Hashable { let bytes: [UInt8] }` (32 bytes = 256 bits), `func hammingDistance(to other: IconFingerprint) -> Int`, `var hexString: String`, `init?(hexString: String)`
  - `enum PerceptualHash { static func fingerprint(for image: CGImage) -> IconFingerprint? }` — 16×16 grayscale mean-threshold hash.

- [ ] **Step 1: Write the failing tests**

Create `IceTests/PerceptualHashTests.swift`:

```swift
import XCTest
@testable import Ice

final class PerceptualHashTests: XCTestCase {
    /// Draws a 64x64 grayscale image, filling `whiteRect` with white on black.
    private func makeImage(whiteRect: CGRect) -> CGImage {
        let size = 64
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(whiteRect)
        return context.makeImage()!
    }

    func testFingerprintIs32Bytes() {
        let image = makeImage(whiteRect: CGRect(x: 0, y: 0, width: 32, height: 64))
        let fp = PerceptualHash.fingerprint(for: image)
        XCTAssertEqual(fp?.bytes.count, 32)
    }

    func testIdenticalImagesHaveZeroDistance() {
        let a = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 0, y: 0, width: 32, height: 64)))!
        let b = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 0, y: 0, width: 32, height: 64)))!
        XCTAssertEqual(a.hammingDistance(to: b), 0)
    }

    func testDifferentGlyphsExceedThreshold() {
        // Left half white vs right half white: every threshold bit differs.
        let a = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 0, y: 0, width: 32, height: 64)))!
        let b = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 32, y: 0, width: 32, height: 64)))!
        XCTAssertGreaterThan(a.hammingDistance(to: b), 25)
    }

    func testSlightlyShiftedGlyphStaysWithinThreshold() {
        // Same glyph shifted by 2px at 64px scale (< one 16x16 cell) — tolerant.
        let a = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 8, y: 8, width: 40, height: 48)))!
        let b = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 10, y: 8, width: 40, height: 48)))!
        XCTAssertLessThanOrEqual(a.hammingDistance(to: b), 25)
    }

    func testHexRoundTrip() {
        let fp = PerceptualHash.fingerprint(for: makeImage(whiteRect: CGRect(x: 0, y: 0, width: 32, height: 64)))!
        XCTAssertEqual(IconFingerprint(hexString: fp.hexString), fp)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(IconFingerprint(hexString: "zz"))
        XCTAssertNil(IconFingerprint(hexString: "abcd")) // wrong length
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — types not defined.

- [ ] **Step 3: Implement**

Create `Ice/Utilities/PerceptualHash.swift`:

```swift
//
//  PerceptualHash.swift
//  Ice
//

import CoreGraphics
import Foundation

/// A 256-bit perceptual fingerprint of a menu bar icon.
struct IconFingerprint: Codable, Hashable {
    /// 32 bytes = 256 bits, one bit per cell of a 16x16 downsample.
    let bytes: [UInt8]

    /// Number of differing bits between two fingerprints (0...256).
    func hammingDistance(to other: IconFingerprint) -> Int {
        zip(bytes, other.bytes).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    init?(hexString: String) {
        guard hexString.count == 64 else {
            return nil
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }
}

/// Computes perceptual fingerprints for icon images.
///
/// Algorithm: draw the image into a 16x16 8-bit grayscale bitmap on a black
/// background, compute the mean brightness, then emit one bit per pixel
/// (1 = above mean). Tolerant of tint and light/dark appearance changes,
/// unlike exact pixel hashes.
enum PerceptualHash {
    private static let side = 16

    static func fingerprint(for image: CGImage) -> IconFingerprint? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let data = context.data else {
            return nil
        }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)

        var sum = 0
        for i in 0..<(side * side) {
            sum += Int(pixels[i])
        }
        let mean = UInt8(clamping: sum / (side * side))

        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<(side * side) where pixels[i] > mean {
            bytes[i / 8] |= 1 << UInt8(7 - (i % 8))
        }
        return IconFingerprint(bytes: bytes)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS (all six). If `testSlightlyShiftedGlyphStaysWithinThreshold` is flaky around the boundary, adjust the fixture shift (not the algorithm) and note the measured distance in the test comment.

- [ ] **Step 5: Commit**

```bash
git add Ice/Utilities/PerceptualHash.swift IceTests/PerceptualHashTests.swift
git commit -m "feat: 256-bit perceptual icon fingerprint with hamming distance"
```

---

### Task 4: Snapshot data model + Defaults key

**Files:**
- Create: `Ice/MenuBar/MenuBarItems/MenuBarLayoutSnapshot.swift`
- Modify: `Ice/Utilities/Defaults.swift:177` (add key after `iceBarPinnedLocation`)
- Test: `IceTests/MenuBarLayoutSnapshotTests.swift`

**Interfaces:**
- Produces:

```swift
struct MenuBarLayoutSnapshot: Codable, Equatable {
    var capturedAt: Date
    var visible: [ItemSnapshot]
    var hidden: [ItemSnapshot]
    var alwaysHidden: [ItemSnapshot]

    struct ItemSnapshot: Codable, Equatable {
        var windowID: CGWindowID
        var info: String
        var iconFingerprint: String?   // IconFingerprint.hexString
        var width: CGFloat
    }

    func entries() -> [(ItemSnapshot, MenuBarSection.Name)]  // flattened with section
    static func load() -> MenuBarLayoutSnapshot?
    func save()
}
```
- Defaults key: `case menuBarItemLayoutSnapshotV1 = "MenuBarItemLayoutSnapshotV1"`

- [ ] **Step 1: Write the failing tests**

Create `IceTests/MenuBarLayoutSnapshotTests.swift`:

```swift
import XCTest
@testable import Ice

final class MenuBarLayoutSnapshotTests: XCTestCase {
    private func makeSnapshot() -> MenuBarLayoutSnapshot {
        MenuBarLayoutSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000_000),
            visible: [.init(windowID: 1, info: "com.foo:Item-0", iconFingerprint: nil, width: 32)],
            hidden: [
                .init(windowID: 2, info: "com.apple.controlcenter:Item-0", iconFingerprint: String(repeating: "ab", count: 32), width: 28),
                .init(windowID: 3, info: "com.apple.controlcenter:Item-0", iconFingerprint: nil, width: 30),
            ],
            alwaysHidden: []
        )
    }

    func testCodableRoundTrip() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MenuBarLayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testDecodingToleratesMissingFingerprint() throws {
        let json = """
        {"capturedAt":0,"visible":[],"alwaysHidden":[],
         "hidden":[{"windowID":9,"info":"a:b","width":20}]}
        """
        let decoded = try JSONDecoder().decode(MenuBarLayoutSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hidden.first?.windowID, 9)
        XCTAssertNil(decoded.hidden.first?.iconFingerprint)
    }

    func testEntriesFlattensWithSections() {
        let entries = makeSnapshot().entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].1, .visible)
        XCTAssertEqual(entries[1].1, .hidden)
        XCTAssertEqual(entries[2].1, .hidden)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — type not defined.

- [ ] **Step 3: Implement**

Add to `Ice/Utilities/Defaults.swift` after `case iceBarPinnedLocation = "IceBarPinnedLocation"`:

```swift

        // MARK: Item Persistence

        case menuBarItemLayoutSnapshotV1 = "MenuBarItemLayoutSnapshotV1"
```

Create `Ice/MenuBar/MenuBarItems/MenuBarLayoutSnapshot.swift`:

```swift
//
//  MenuBarLayoutSnapshot.swift
//  Ice
//

import CoreGraphics
import Foundation

/// A persisted record of which managed menu bar items were in which section,
/// used to restore section membership after a relaunch on macOS 26 (Tahoe),
/// where item identity by bundle id is unavailable.
struct MenuBarLayoutSnapshot: Codable, Equatable {
    /// A persisted record of a single managed item.
    struct ItemSnapshot: Codable, Equatable {
        /// Primary identity signal; stable while the item's window lives
        /// (i.e. across Barkeep restarts, not across reboots).
        var windowID: CGWindowID
        /// "namespace:title" — fully reliable pre-Tahoe, weak signal on Tahoe.
        var info: String
        /// Perceptual hash of the icon (``IconFingerprint/hexString``).
        var iconFingerprint: String?
        /// Item window width; recorded for diagnostics.
        var width: CGFloat
    }

    var capturedAt: Date
    var visible: [ItemSnapshot]
    var hidden: [ItemSnapshot]
    var alwaysHidden: [ItemSnapshot]

    /// All snapshots paired with their section, in section order.
    func entries() -> [(ItemSnapshot, MenuBarSection.Name)] {
        visible.map { ($0, .visible) }
            + hidden.map { ($0, .hidden) }
            + alwaysHidden.map { ($0, .alwaysHidden) }
    }

    /// Loads the stored snapshot, if any.
    static func load() -> MenuBarLayoutSnapshot? {
        guard let data = Defaults.data(forKey: .menuBarItemLayoutSnapshotV1) else {
            return nil
        }
        return try? JSONDecoder().decode(MenuBarLayoutSnapshot.self, from: data)
    }

    /// Persists the snapshot.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        Defaults.set(data, forKey: .menuBarItemLayoutSnapshotV1)
    }
}
```

Check that `Defaults.set(_:forKey:)` exists in `Ice/Utilities/Defaults.swift`; if the setter is named differently (e.g. only `setObject`), use the existing setter — do not add a duplicate.

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Ice/MenuBar/MenuBarItems/MenuBarLayoutSnapshot.swift Ice/Utilities/Defaults.swift IceTests/MenuBarLayoutSnapshotTests.swift
git commit -m "feat: codable menu bar layout snapshot model"
```

---

### Task 5: Three-pass matcher (pure logic, the core)

**Files:**
- Create: `Ice/MenuBar/MenuBarItems/LayoutSnapshotMatcher.swift`
- Test: `IceTests/LayoutSnapshotMatcherTests.swift`

**Interfaces:**
- Consumes: `MenuBarLayoutSnapshot`, `IconFingerprint` (Tasks 3-4).
- Produces:

```swift
enum LayoutSnapshotMatcher {
    struct ItemDescriptor {
        var windowID: CGWindowID
        var info: String
        var iconFingerprint: IconFingerprint?
        var currentSection: MenuBarSection.Name
    }
    struct Correction: Equatable {
        var windowID: CGWindowID
        var targetSection: MenuBarSection.Name
    }
    static func corrections(
        snapshot: MenuBarLayoutSnapshot,
        currentItems: [ItemDescriptor],
        hammingThreshold: Int
    ) -> [Correction]
}
```

`corrections` returns ONLY matched items whose target section differs from their current section. Default threshold used by callers: 25 (or the Task 2 finding).

- [ ] **Step 1: Write the failing tests**

Create `IceTests/LayoutSnapshotMatcherTests.swift`:

```swift
import XCTest
@testable import Ice

final class LayoutSnapshotMatcherTests: XCTestCase {
    private typealias Item = LayoutSnapshotMatcher.ItemDescriptor
    private typealias Snap = MenuBarLayoutSnapshot.ItemSnapshot

    private func snapshot(
        visible: [Snap] = [], hidden: [Snap] = [], alwaysHidden: [Snap] = []
    ) -> MenuBarLayoutSnapshot {
        MenuBarLayoutSnapshot(capturedAt: .now, visible: visible, hidden: hidden, alwaysHidden: alwaysHidden)
    }

    /// Distinct fingerprints for fixtures: fp(0) and fp(1) differ in 256 bits,
    /// fpNear(base:) differs from fp(base) by exactly 1 bit.
    private func fp(_ fill: UInt8) -> IconFingerprint {
        IconFingerprint(bytes: [UInt8](repeating: fill == 0 ? 0x00 : 0xFF, count: 32))
    }
    private func fpNear(_ base: UInt8) -> IconFingerprint {
        var bytes = fp(base).bytes
        bytes[0] ^= 0b0000_0001
        return IconFingerprint(bytes: bytes)
    }

    // MARK: Pass 1 — windowID

    func testWindowIDMatchProducesCorrection() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30)])
        let items = [Item(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible)]
        XCTAssertEqual(
            LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25),
            [.init(windowID: 10, targetSection: .hidden)]
        )
    }

    func testWindowIDMatchInCorrectSectionProducesNoCorrection() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30)])
        let items = [Item(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, currentSection: .hidden)]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    // MARK: Pass 2 — bidirectionally unique info

    func testUniqueInfoMatches() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "com.foo:Dropbox", iconFingerprint: nil, width: 30)])
        // New windowID (e.g. pre-Tahoe reboot), but unique title.
        let items = [Item(windowID: 99, info: "com.foo:Dropbox", iconFingerprint: nil, currentSection: .visible)]
        XCTAssertEqual(
            LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25),
            [.init(windowID: 99, targetSection: .hidden)]
        )
    }

    func testDuplicateInfoNeverMatches() {
        // The Tahoe swarm: two snapshot entries and two current items all named Item-0.
        let snap = snapshot(hidden: [
            Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30),
            Snap(windowID: 11, info: "cc:Item-0", iconFingerprint: nil, width: 30),
        ])
        let items = [
            Item(windowID: 98, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
            Item(windowID: 99, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
        ]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    func testInfoUniqueInSnapshotButDuplicatedInCurrentDoesNotMatch() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30)])
        let items = [
            Item(windowID: 98, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
            Item(windowID: 99, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
        ]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    // MARK: Pass 3 — fingerprint

    func testFingerprintMatchWithinThreshold() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: fp(0).hexString, width: 30)])
        let items = [Item(windowID: 99, info: "cc:Item-1", iconFingerprint: fpNear(0), currentSection: .visible)]
        XCTAssertEqual(
            LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25),
            [.init(windowID: 99, targetSection: .hidden)]
        )
    }

    func testFingerprintBeyondThresholdDoesNotMatch() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: fp(0).hexString, width: 30)])
        let items = [Item(windowID: 99, info: "cc:Item-1", iconFingerprint: fp(1), currentSection: .visible)]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    func testAmbiguousFingerprintDoesNotMatch() {
        // Two snapshot entries with the same fingerprint competing for one item.
        let snap = snapshot(
            visible: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: fp(0).hexString, width: 30)],
            hidden: [Snap(windowID: 11, info: "cc:Item-0", iconFingerprint: fp(0).hexString, width: 30)]
        )
        let items = [Item(windowID: 99, info: "cc:Item-1", iconFingerprint: fpNear(0), currentSection: .visible)]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    // MARK: Combination and fail-visible

    func testPassesCompose() {
        // Item 1 matches by windowID, item 2 by unique info, item 3 unmatched (stays put).
        let snap = snapshot(hidden: [
            Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30),
            Snap(windowID: 11, info: "com.foo:Dropbox", iconFingerprint: nil, width: 30),
            Snap(windowID: 12, info: "cc:Item-0", iconFingerprint: nil, width: 30),
        ])
        let items = [
            Item(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
            Item(windowID: 97, info: "com.foo:Dropbox", iconFingerprint: nil, currentSection: .visible),
            Item(windowID: 98, info: "cc:Item-0", iconFingerprint: nil, currentSection: .visible),
        ]
        let result = LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25)
        XCTAssertEqual(Set(result), Set([
            .init(windowID: 10, targetSection: .hidden),
            .init(windowID: 97, targetSection: .hidden),
        ]))
    }

    func testWindowIDMatchConsumesEntryBeforeInfoPass() {
        // Entry matched by windowID in pass 1 must not also match another item by info in pass 2.
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "com.foo:Dropbox", iconFingerprint: nil, width: 30)])
        let items = [
            Item(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, currentSection: .hidden),
            Item(windowID: 99, info: "com.foo:Dropbox", iconFingerprint: nil, currentSection: .visible),
        ]
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: items, hammingThreshold: 25).isEmpty)
    }

    func testStaleSnapshotEntriesAreDropped() {
        let snap = snapshot(hidden: [Snap(windowID: 10, info: "cc:Item-0", iconFingerprint: nil, width: 30)])
        XCTAssertTrue(LayoutSnapshotMatcher.corrections(snapshot: snap, currentItems: [], hammingThreshold: 25).isEmpty)
    }
}
```

Note: `Correction` must be `Hashable` for the `Set` comparison in `testPassesCompose` — declare it `struct Correction: Equatable, Hashable`.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `LayoutSnapshotMatcher` not defined.

- [ ] **Step 3: Implement**

Create `Ice/MenuBar/MenuBarItems/LayoutSnapshotMatcher.swift`:

```swift
//
//  LayoutSnapshotMatcher.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Pure matching logic between a persisted layout snapshot and the currently
/// present menu bar items.
///
/// Three greedy passes, each only over still-unmatched participants:
/// 1. windowID equality (primary; stable across Barkeep restarts)
/// 2. bidirectionally unique `info` (pre-Tahoe reliable; Tahoe "Item-0" swarms
///    are skipped automatically because they are not unique)
/// 3. icon fingerprint within a Hamming threshold, bidirectional best unique match
///
/// Anything unmatched is left alone (fail-visible: never wrongly hide).
enum LayoutSnapshotMatcher {
    /// The matcher-relevant description of a currently present item.
    struct ItemDescriptor {
        var windowID: CGWindowID
        var info: String
        var iconFingerprint: IconFingerprint?
        var currentSection: MenuBarSection.Name
    }

    /// A single "move this window to that section" instruction.
    struct Correction: Equatable, Hashable {
        var windowID: CGWindowID
        var targetSection: MenuBarSection.Name
    }

    /// Returns corrections for matched items whose target section differs
    /// from their current section.
    static func corrections(
        snapshot: MenuBarLayoutSnapshot,
        currentItems: [ItemDescriptor],
        hammingThreshold: Int
    ) -> [Correction] {
        var entries = snapshot.entries()
        var items = currentItems
        // windowID -> target section for every match found.
        var matches = [CGWindowID: MenuBarSection.Name]()

        // Pass 1: windowID equality.
        for item in items {
            if let index = entries.firstIndex(where: { $0.0.windowID == item.windowID }) {
                matches[item.windowID] = entries[index].1
                entries.remove(at: index)
            }
        }
        items.removeAll { matches[$0.windowID] != nil }

        // Pass 2: bidirectionally unique info.
        let entryCounts = Dictionary(grouping: entries, by: { $0.0.info })
        let itemCounts = Dictionary(grouping: items, by: \.info)
        for (info, matchingEntries) in entryCounts where matchingEntries.count == 1 {
            guard let matchingItems = itemCounts[info], matchingItems.count == 1 else {
                continue
            }
            matches[matchingItems[0].windowID] = matchingEntries[0].1
            entries.removeAll { $0.0.info == info }
        }
        items.removeAll { matches[$0.windowID] != nil }

        // Pass 3: fingerprint, bidirectional best unique match within threshold.
        let fingerprintedEntries = entries.compactMap { entry -> (IconFingerprint, MenuBarSection.Name)? in
            guard
                let hex = entry.0.iconFingerprint,
                let fingerprint = IconFingerprint(hexString: hex)
            else {
                return nil
            }
            return (fingerprint, entry.1)
        }
        for item in items {
            guard let itemFingerprint = item.iconFingerprint else {
                continue
            }
            // All entries within threshold of this item.
            let candidates = fingerprintedEntries
                .map { (distance: itemFingerprint.hammingDistance(to: $0.0), entry: $0) }
                .filter { $0.distance <= hammingThreshold }
                .sorted { $0.distance < $1.distance }
            // Unique best match required: exactly one candidate, or a strict
            // winner would still be ambiguous about identity — require exactly one.
            guard candidates.count == 1 else {
                continue
            }
            // The entry must also not be within threshold of any OTHER item
            // (bidirectional uniqueness).
            let entryFingerprint = candidates[0].entry.0
            let competingItems = items.filter { other in
                guard let otherFingerprint = other.iconFingerprint else {
                    return false
                }
                return entryFingerprint.hammingDistance(to: otherFingerprint) <= hammingThreshold
            }
            guard competingItems.count == 1 else {
                continue
            }
            matches[item.windowID] = candidates[0].entry.1
        }

        // Emit corrections only where the section actually changed.
        return currentItems.compactMap { item in
            guard
                let target = matches[item.windowID],
                target != item.currentSection
            else {
                return nil
            }
            return Correction(windowID: item.windowID, targetSection: target)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS (all eleven).

- [ ] **Step 5: Commit**

```bash
git add Ice/MenuBar/MenuBarItems/LayoutSnapshotMatcher.swift IceTests/LayoutSnapshotMatcherTests.swift
git commit -m "feat: three-pass snapshot matcher with fail-visible semantics"
```

---

### Task 6: MenuBarItemPersistenceManager — write path

**Files:**
- Create: `Ice/MenuBar/MenuBarItems/MenuBarItemPersistenceManager.swift`
- Modify: `Ice/Main/AppState.swift` (add lazy manager ~line 22 area; add `itemPersistenceManager.performSetup()` in `performSetup()` after `itemManager.performSetup()` at line 193)
- Modify: `Ice/Main/AppDelegate.swift` (extend `applicationWillTerminate` from Task 1)
- Test: `IceTests/MenuBarItemPersistenceManagerTests.swift`

**Interfaces:**
- Consumes: `MenuBarLayoutSnapshot` (Task 4), `PerceptualHash`/`IconFingerprint` (Task 3), `MenuBarItemManager.itemCache` (`@Published`), `ScreenCapture.captureWindow(_:) -> CGImage?`.
- Produces:
  - `@MainActor final class MenuBarItemPersistenceManager: ObservableObject` with `init(appState:)`, `func performSetup()`, `func writeSnapshotNow()`, `var isRestoring: Bool` (internal), `func restoreIfNeeded() async` (stub in this task, implemented in Task 7).
  - `static func shouldWrite(cacheIsEmpty: Bool, isRestoring: Bool) -> Bool` (pure, tested).
  - `AppState.itemPersistenceManager`.

- [ ] **Step 1: Write the failing test**

Create `IceTests/MenuBarItemPersistenceManagerTests.swift`:

```swift
import XCTest
@testable import Ice

final class MenuBarItemPersistenceManagerTests: XCTestCase {
    func testShouldWriteNormally() {
        XCTAssertTrue(MenuBarItemPersistenceManager.shouldWrite(cacheIsEmpty: false, isRestoring: false))
    }

    func testShouldNotWriteWhenCacheEmpty() {
        // Protects the good snapshot from error-path itemCache.clear().
        XCTAssertFalse(MenuBarItemPersistenceManager.shouldWrite(cacheIsEmpty: true, isRestoring: false))
    }

    func testShouldNotWriteWhileRestoring() {
        XCTAssertFalse(MenuBarItemPersistenceManager.shouldWrite(cacheIsEmpty: false, isRestoring: true))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — type not defined.

- [ ] **Step 3: Implement the manager (write path + restore stub)**

Create `Ice/MenuBar/MenuBarItems/MenuBarItemPersistenceManager.swift`:

```swift
//
//  MenuBarItemPersistenceManager.swift
//  Ice
//

import Cocoa
import Combine

/// Persists which managed menu bar items belong to which section, and restores
/// that assignment after a relaunch.
///
/// Needed on macOS 26 (Tahoe), where all third-party items report Control
/// Center as their owner, so identity-by-bundle-id is unavailable and the
/// system's own position restoration is unreliable. See
/// docs/superpowers/specs/2026-07-04-per-item-persistence-design.md.
@MainActor
final class MenuBarItemPersistenceManager: ObservableObject {
    private(set) weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    /// Fingerprints by windowID, recomputed only when the windowID set changes.
    private var fingerprintCache = [CGWindowID: IconFingerprint]()

    /// True while the launch-time restore is running; suspends snapshot writes.
    private(set) var isRestoring = false

    /// True once the launch-time restore has run for this session.
    private(set) var hasRestoredThisSession = false

    /// Hamming threshold for fingerprint matches (see Phase 0 findings).
    static let hammingThreshold = 25

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let itemManager = appState?.itemManager {
            itemManager.$itemCache
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] cache in
                    guard let self else {
                        return
                    }
                    if !hasRestoredThisSession {
                        Task {
                            await self.restoreIfNeeded()
                        }
                    }
                    writeSnapshot(from: cache)
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Pure write-gate; unit-tested.
    nonisolated static func shouldWrite(cacheIsEmpty: Bool, isRestoring: Bool) -> Bool {
        !cacheIsEmpty && !isRestoring
    }

    /// Builds and persists a snapshot from the given cache.
    private func writeSnapshot(from cache: MenuBarItemManager.ItemCache) {
        let managed = snapshottableItems(in: cache)
        guard Self.shouldWrite(cacheIsEmpty: managed.values.allSatisfy(\.isEmpty), isRestoring: isRestoring) else {
            return
        }

        updateFingerprintCache(for: managed.values.flatMap { $0 })

        func itemSnapshots(for section: MenuBarSection.Name) -> [MenuBarLayoutSnapshot.ItemSnapshot] {
            (managed[section] ?? []).map { item in
                MenuBarLayoutSnapshot.ItemSnapshot(
                    windowID: item.windowID,
                    info: item.info.description,
                    iconFingerprint: fingerprintCache[item.windowID]?.hexString,
                    width: item.frame.width
                )
            }
        }

        let snapshot = MenuBarLayoutSnapshot(
            capturedAt: .now,
            visible: itemSnapshots(for: .visible),
            hidden: itemSnapshots(for: .hidden),
            alwaysHidden: itemSnapshots(for: .alwaysHidden)
        )
        snapshot.save()
    }

    /// Synchronous final write for applicationWillTerminate.
    func writeSnapshotNow() {
        guard let appState else {
            return
        }
        writeSnapshot(from: appState.itemManager.itemCache)
    }

    /// The items worth persisting: managed, movable, hideable, not Barkeep's own.
    private func snapshottableItems(in cache: MenuBarItemManager.ItemCache) -> [MenuBarSection.Name: [MenuBarItem]] {
        var result = [MenuBarSection.Name: [MenuBarItem]]()
        for section in MenuBarSection.Name.allCases {
            result[section] = cache.managedItems(for: section).filter { item in
                item.isMovable && item.canBeHidden && item.info.namespace != .ice
            }
        }
        return result
    }

    /// Recomputes fingerprints only when the windowID set changed.
    private func updateFingerprintCache(for items: [MenuBarItem]) {
        let currentIDs = Set(items.map(\.windowID))
        guard currentIDs != Set(fingerprintCache.keys) else {
            return
        }
        var newCache = [CGWindowID: IconFingerprint]()
        for item in items {
            if let cached = fingerprintCache[item.windowID] {
                newCache[item.windowID] = cached
            } else if
                let image = ScreenCapture.captureWindow(item.windowID, option: .boundsIgnoreFraming),
                let fingerprint = PerceptualHash.fingerprint(for: image)
            {
                newCache[item.windowID] = fingerprint
            }
        }
        fingerprintCache = newCache
    }

    /// Launch-time restore. Implemented in the restore-path task.
    func restoreIfNeeded() async {
        hasRestoredThisSession = true
    }
}

// MARK: - Logger
extension Logger {
    static let persistence = Logger(category: "persistence")
}
```

- [ ] **Step 4: Wire into AppState and AppDelegate**

In `Ice/Main/AppState.swift`, after the `itemManager` declaration (line 21-22):

```swift
    /// Manager that persists and restores per-item section assignment.
    private(set) lazy var itemPersistenceManager = MenuBarItemPersistenceManager(appState: self)
```

In `AppState.performSetup()`, after `itemManager.performSetup()`:

```swift
        itemPersistenceManager.performSetup()
```

In `Ice/Main/AppDelegate.swift`, extend `applicationWillTerminate` (added in Task 1):

```swift
    func applicationWillTerminate(_ notification: Notification) {
        guard let appState else {
            return
        }
        appState.itemPersistenceManager.writeSnapshotNow()
        LayoutDiagnostics.dump(label: "will-terminate", appState: appState)
    }
```

- [ ] **Step 5: Run all tests + build**

Run the Test command, then the Build command. Expected: all tests PASS, `BUILD SUCCEEDED`. If `ScreenCapture.captureWindow`'s `option:` label differs, match the real signature at `Ice/Utilities/ScreenCapture.swift:80`.

- [ ] **Step 6: Commit**

```bash
git add Ice/MenuBar/MenuBarItems/MenuBarItemPersistenceManager.swift IceTests/MenuBarItemPersistenceManagerTests.swift Ice/Main/AppState.swift Ice/Main/AppDelegate.swift
git commit -m "feat: persistence manager write path with debounced snapshots"
```

---

### Task 7: Restore path

**Files:**
- Modify: `Ice/MenuBar/MenuBarItems/MenuBarItemPersistenceManager.swift` (replace the `restoreIfNeeded` stub)

**Interfaces:**
- Consumes: `LayoutSnapshotMatcher.corrections` (Task 5), `MenuBarItemManager.move(item:to:)`, `MenuBarItemManager.waitForItemsToStopMoving(timeout:)`, `MenuBarItem.getMenuBarItems(onScreenOnly:activeSpaceOnly:)`, `MenuBarItemInfo.hiddenControlItem` / `.alwaysHiddenControlItem`.
- Produces: working launch-time restore; per-move outcomes logged via `Logger.persistence` and `LayoutDiagnostics.appendText`.

- [ ] **Step 1: Replace the stub**

Replace `func restoreIfNeeded() async { hasRestoredThisSession = true }` with:

```swift
    /// Once per session: match reality against the stored snapshot and move
    /// misplaced items back to their sections. Unmatched items are never
    /// moved (fail-visible).
    func restoreIfNeeded() async {
        guard !hasRestoredThisSession, let appState else {
            return
        }
        let itemManager = appState.itemManager

        // Need a populated cache and the hidden control item to classify against.
        let cache = itemManager.itemCache
        let managed = snapshottableItems(in: cache)
        guard managed.values.contains(where: { !$0.isEmpty }) else {
            return
        }
        guard let snapshot = MenuBarLayoutSnapshot.load() else {
            hasRestoredThisSession = true
            return
        }

        hasRestoredThisSession = true
        isRestoring = true
        defer {
            isRestoring = false
        }

        do {
            try await itemManager.waitForItemsToStopMoving(timeout: .seconds(2))
        } catch {
            Logger.persistence.warning("Restore skipped: items still moving (\(error))")
            return
        }

        // Fingerprints for current items (cache is fresh after updateFingerprintCache).
        let allManaged = managed.values.flatMap { $0 }
        updateFingerprintCache(for: allManaged)

        var descriptors = [LayoutSnapshotMatcher.ItemDescriptor]()
        var itemsByWindowID = [CGWindowID: MenuBarItem]()
        for (section, items) in managed {
            for item in items {
                descriptors.append(LayoutSnapshotMatcher.ItemDescriptor(
                    windowID: item.windowID,
                    info: item.info.description,
                    iconFingerprint: fingerprintCache[item.windowID],
                    currentSection: section
                ))
                itemsByWindowID[item.windowID] = item
            }
        }

        let corrections = LayoutSnapshotMatcher.corrections(
            snapshot: snapshot,
            currentItems: descriptors,
            hammingThreshold: Self.hammingThreshold
        )

        Logger.persistence.info("Restore: \(descriptors.count) items, \(corrections.count) corrections")
        LayoutDiagnostics.appendText("[restore] \(descriptors.count) items, \(corrections.count) corrections: \(corrections)")

        guard !corrections.isEmpty else {
            return
        }

        // Locate the control items to use as move destinations.
        let currentItems = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        guard let hiddenControlItem = currentItems.first(matching: .hiddenControlItem) else {
            Logger.persistence.warning("Restore aborted: hidden control item not found")
            return
        }
        let alwaysHiddenControlItem = currentItems.first(matching: .alwaysHiddenControlItem)

        for correction in corrections {
            guard let item = itemsByWindowID[correction.windowID] else {
                continue
            }
            let destination: MenuBarItemManager.MoveDestination
            switch correction.targetSection {
            case .visible:
                destination = .rightOfItem(hiddenControlItem)
            case .hidden:
                destination = .leftOfItem(hiddenControlItem)
            case .alwaysHidden:
                guard let alwaysHiddenControlItem else {
                    Logger.persistence.warning("Skipping \(item.logString): always-hidden section disabled")
                    continue
                }
                destination = .leftOfItem(alwaysHiddenControlItem)
            }
            do {
                try await itemManager.move(item: item, to: destination)
                Logger.persistence.info("Restored \(item.logString) to \(correction.targetSection.logString)")
                LayoutDiagnostics.appendText("[restore] moved wid=\(item.windowID) -> \(correction.targetSection.logString)")
            } catch {
                // Per spec: log, skip, continue. No retry, no rollback.
                Logger.persistence.error("Failed to restore \(item.logString): \(error)")
                LayoutDiagnostics.appendText("[restore] FAILED wid=\(item.windowID): \(error)")
            }
        }

        // Rebuild the cache so the corrected reality becomes the new snapshot
        // once isRestoring clears.
        await itemManager.cacheItemsIfNeeded()
    }
```

Supporting details:
- `MenuBarItem` arrays: check whether a `first(matching:)` helper exists (used in `cacheItemsIfNeeded` as `firstIndex(matching:)` — `Ice/Utilities/Extensions.swift`). If only `firstIndex(matching:)` exists, use `currentItems.firstIndex(matching: .hiddenControlItem).map { currentItems[$0] }`.
- `MenuBarSection.Name.logString`: check `MenuBarSection.swift`; if there is no `logString`, use `displayString`.
- `item.logString` exists (used throughout `MenuBarItemManager`).

- [ ] **Step 2: Build and run full test suite**

Run the Build command, then the Test command. Expected: `BUILD SUCCEEDED`, all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Ice/MenuBar/MenuBarItems/MenuBarItemPersistenceManager.swift
git commit -m "feat: launch-time restore of per-item section assignment"
```

---

### Task 8: Manual acceptance + docs (CHECKPOINT, human-in-the-loop)

**Files:**
- Modify: `README.md` (Known limitations section, lines 16-21)
- Modify: `.context/HANDOFF.md` (Candidate next work section)

**Interfaces:** none (verification + documentation).

- [ ] **Step 1: Ask the human to run the acceptance protocol**

With diagnostics still enabled:
1. **Main path**: ⌘R → hide 2-3 third-party items → quit → ⌘R → verify the same items are hidden. Check `/tmp/barkeep_diag.txt` `[restore]` lines: corrections applied, no failures.
2. **Edge — new item**: quit Barkeep → launch some new menu-bar app → ⌘R → new item must be visible.
3. **Edge — vanished item**: hide an app's item → quit Barkeep → quit that app → ⌘R → no mis-hides, no errors beyond a dropped snapshot entry.
4. **Adversarial**: during the restore moves, drag an item manually → the conflicting move fails and is skipped, no fighting.

Acceptance: scenario 1 restores 100% of section assignments; failures in any scenario only ever over-show, never wrongly hide.

- [ ] **Step 2: Update README**

Rewrite the Known limitations paragraph (README.md:16-21) to say per-item persistence across Barkeep restarts is now handled via layout snapshots (windowID + icon fingerprint matching); persistence across reboots/logins remains best-effort because windowIDs reset.

- [ ] **Step 3: Update HANDOFF.md**

Move "Cross-app per-item persistence" from "Candidate next work" to "Already fixed" (with one line: snapshot + three-pass matcher, see spec/plan docs). Add any newly observed bugs to the running list.

- [ ] **Step 4: Commit**

```bash
git add README.md .context/HANDOFF.md
git commit -m "docs: per-item persistence shipped; update limitations and handoff"
```

---

## Self-Review Notes

- Spec coverage: Phase 0 harness (Task 1-2), fingerprint (Task 3), snapshot model + write timing (Task 4, 6), matcher with all three passes and fail-visible (Task 5), restore flow with guards (Task 7), manual acceptance criteria (Task 8). Intra-section ordering explicitly NOT restored (spec) — no task does it. Future work (re-running restore for late-appearing items) is explicitly out of scope — no task does it.
- Type consistency verified: `IconFingerprint.hexString`/`init?(hexString:)` used by Tasks 4-7; `MenuBarLayoutSnapshot.entries()` consumed by Task 5; `shouldWrite(cacheIsEmpty:isRestoring:)` defined and tested in Task 6; `corrections(snapshot:currentItems:hammingThreshold:)` consumed by Task 7.
- Known verify-at-implementation-time points are called out inline (ScreenCapture option label, `first(matching:)` helper, `logString` on `Section.Name`, `ControlItem.Identifier: CaseIterable`, `Defaults.set` setter name).
