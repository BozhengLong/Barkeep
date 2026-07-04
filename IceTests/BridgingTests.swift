import XCTest
@testable import Ice   // internal module name stays "Ice" (target not renamed in P0)

/// Seed of the P1 stability harness: verify the private-API Bridging layer
/// returns sane values on the CURRENT macOS build. If Apple changes SkyLight
/// behavior in a future build, these assertions fail loudly instead of the
/// app silently misbehaving.
final class BridgingTests: XCTestCase {

    /// There is always at least one on-screen window (the menu bar itself).
    func testOnScreenWindowCountIsPositive() {
        XCTAssertGreaterThan(Bridging.onScreenWindowCount, 0,
            "CGSGetOnScreenWindowCount returned 0 — private-API contract broke on this OS build")
    }

    /// The menu bar has status items, so the private menu-bar window list is non-empty.
    func testMenuBarItemWindowListIsNonEmpty() {
        let ids = Bridging.getWindowList(option: .menuBarItems)
        XCTAssertFalse(ids.isEmpty,
            "CGSGetProcessMenuBarWindowList returned no windows — the core discovery API broke")
    }

    /// Every menu-bar window id must resolve to a real on-screen frame.
    func testMenuBarWindowsHaveFrames() {
        let ids = Bridging.getWindowList(option: .menuBarItems)
        for id in ids.prefix(5) {
            let frame = Bridging.getWindowFrame(for: id)
            XCTAssertNotNil(frame, "getWindowFrame(for: \(id)) was nil")
            if let f = frame { XCTAssertGreaterThan(f.width, 0) }
        }
    }
}
