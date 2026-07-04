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
