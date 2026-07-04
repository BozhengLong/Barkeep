import CoreGraphics
import XCTest
@testable import Ice

/// Regression tests for the macOS 26 (Tahoe) IceBar crash: `NSWindow.windowNumber`
/// can be negative on Tahoe, and `CGWindowID(windowNumber)` (a `UInt32(Int)`
/// conversion) traps on negative/out-of-range values. `CGWindowID(safeWindowNumber:)`
/// must return nil instead of trapping.
final class CGWindowIDSafeInitTests: XCTestCase {
    func testNegativeWindowNumberReturnsNil() {
        XCTAssertNil(CGWindowID(safeWindowNumber: -1))
        XCTAssertNil(CGWindowID(safeWindowNumber: -99999))
    }

    func testZeroReturnsNil() {
        XCTAssertNil(CGWindowID(safeWindowNumber: 0))
    }

    func testPositiveInRangeReturnsValue() {
        XCTAssertEqual(CGWindowID(safeWindowNumber: 42), 42)
        XCTAssertEqual(CGWindowID(safeWindowNumber: Int(UInt32.max)), UInt32.max)
    }

    func testAboveUInt32MaxReturnsNil() {
        XCTAssertNil(CGWindowID(safeWindowNumber: Int(UInt32.max) + 1))
    }
}
