import XCTest
@testable import Ice

/// Documents a Tahoe finding: the low-level menu-bar-item *discovery* works
/// in-process (this passes), even though the running app's Menu Bar Layout UI
/// surfaces no items on macOS 26. That gap is app-layer (manager → image cache →
/// LayoutBar), not discovery, and is the subject of the P1 investigation.
///
/// Keeping this green guards the discovery path while we fix the app layer.
final class MenuBarItemDiscoveryTests: XCTestCase {
    func testActiveSpaceMenuBarItemsAreDiscovered() {
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        XCTAssertFalse(
            items.isEmpty,
            "getMenuBarItems(activeSpaceOnly: true) returned no items on this OS build"
        )
    }
}
