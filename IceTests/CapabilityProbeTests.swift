import XCTest
@testable import Ice

final class CapabilityProbeTests: XCTestCase {
    /// On a healthy machine, every capability the app depends on must probe healthy.
    /// If a future macOS build breaks one of the private APIs, this fails loudly.
    func testAllCapabilitiesHealthyOnThisBuild() {
        let results = CapabilityProbe.run()
        XCTAssertEqual(results.count, Capability.allCases.count)
        let unhealthy = results.filter { !$0.healthy }
        XCTAssertTrue(unhealthy.isEmpty,
            "unhealthy capabilities on build \(CapabilityProbe.osBuild): \(unhealthy.map { "\($0.capability.rawValue)(\($0.detail))" })")
    }

    /// The evaluation logic must report a capability unhealthy when its check fails,
    /// without affecting the others. Verified with injected fakes (no real APIs).
    func testInjectedFailingCheckIsReportedUnhealthy() {
        let checks: [Capability: () -> (Bool, String)] = [
            .onScreenWindowList: { (true, "ok") },
            .menuBarWindowList: { (false, "forced failure") },
            .windowFrame: { (true, "ok") },
            .activeSpace: { (true, "ok") },
        ]
        let results = CapabilityProbe.run(checks: checks)
        let menuBar = results.first { $0.capability == .menuBarWindowList }
        XCTAssertEqual(menuBar?.healthy, false)
        XCTAssertEqual(menuBar?.detail, "forced failure")
        XCTAssertEqual(results.filter { $0.healthy }.count, 3)
    }

    /// A capability with no provided check is reported unhealthy (fail-closed).
    func testMissingCheckFailsClosed() {
        let results = CapabilityProbe.run(checks: [:])
        XCTAssertTrue(results.allSatisfy { !$0.healthy })
    }

    /// OS build stamp is non-empty and contains a digit (e.g. "25F80" / "Version 26.5.1 (Build 25F80)").
    func testOSBuildIsStamped() {
        XCTAssertFalse(CapabilityProbe.osBuild.isEmpty)
        XCTAssertTrue(CapabilityProbe.osBuild.contains { $0.isNumber })
    }
}
