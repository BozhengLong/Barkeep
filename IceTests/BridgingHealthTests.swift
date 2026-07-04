import XCTest
@testable import Ice

final class BridgingHealthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BridgingHealth.shared.reset()
    }

    func testRecordIncrementsPerApiCount() {
        BridgingHealth.shared.record("CGSGetWindowList", detail: "err -1")
        BridgingHealth.shared.record("CGSGetWindowList", detail: "err -1")
        BridgingHealth.shared.record("CGSGetScreenRectForWindow", detail: "err -2")
        XCTAssertEqual(BridgingHealth.shared.failureCount(for: "CGSGetWindowList"), 2)
        XCTAssertEqual(BridgingHealth.shared.failureCount(for: "CGSGetScreenRectForWindow"), 1)
    }

    func testTotalFailuresSumsAllApis() {
        BridgingHealth.shared.record("A", detail: "x")
        BridgingHealth.shared.record("B", detail: "y")
        BridgingHealth.shared.record("A", detail: "z")
        XCTAssertEqual(BridgingHealth.shared.totalFailures, 3)
    }

    func testResetClearsCounts() {
        BridgingHealth.shared.record("A", detail: "x")
        BridgingHealth.shared.reset()
        XCTAssertEqual(BridgingHealth.shared.totalFailures, 0)
        XCTAssertEqual(BridgingHealth.shared.failureCount(for: "A"), 0)
    }

    func testSnapshotReflectsRecordedCounts() {
        BridgingHealth.shared.record("A", detail: "x")
        BridgingHealth.shared.record("A", detail: "x")
        XCTAssertEqual(BridgingHealth.shared.snapshot(), ["A": 2])
    }

    func testConcurrentRecordsAreCountedSafely() {
        let iterations = 1000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            BridgingHealth.shared.record("C", detail: "x")
        }
        XCTAssertEqual(BridgingHealth.shared.failureCount(for: "C"), iterations)
    }
}
