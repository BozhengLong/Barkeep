import XCTest
@testable import Ice

@MainActor
final class HealthMonitorTests: XCTestCase {
    func testHealthyWhenAllProbesHealthyAndNoFailures() {
        let monitor = HealthMonitor(appState: nil)
        let healthyResults = Capability.allCases.map { ProbeResult(capability: $0, healthy: true, detail: "ok") }
        monitor.evaluate(probe: { healthyResults }, failures: { 0 })
        XCTAssertEqual(monitor.status, .healthy)
    }

    func testDegradedWhenAProbeIsUnhealthy() {
        let monitor = HealthMonitor(appState: nil)
        let results: [ProbeResult] = [
            ProbeResult(capability: .onScreenWindowList, healthy: true, detail: "ok"),
            ProbeResult(capability: .menuBarWindowList, healthy: false, detail: "0 windows"),
            ProbeResult(capability: .windowFrame, healthy: true, detail: "ok"),
            ProbeResult(capability: .activeSpace, healthy: true, detail: "ok"),
        ]
        monitor.evaluate(probe: { results }, failures: { 0 })
        XCTAssertEqual(monitor.status, .degraded(capabilities: [.menuBarWindowList], recentFailures: 0))
    }

    func testDegradedWhenRuntimeFailuresPresentEvenIfProbesHealthy() {
        let monitor = HealthMonitor(appState: nil)
        let healthyResults = Capability.allCases.map { ProbeResult(capability: $0, healthy: true, detail: "ok") }
        monitor.evaluate(probe: { healthyResults }, failures: { 5 })
        XCTAssertEqual(monitor.status, .degraded(capabilities: [], recentFailures: 5))
    }

    func testEvaluateUpdatesPublishedStatus() {
        let monitor = HealthMonitor(appState: nil)
        XCTAssertEqual(monitor.status, .healthy) // initial
        let bad = Capability.allCases.map { ProbeResult(capability: $0, healthy: false, detail: "down") }
        monitor.evaluate(probe: { bad }, failures: { 0 })
        if case .degraded(let caps, _) = monitor.status {
            XCTAssertEqual(Set(caps), Set(Capability.allCases))
        } else {
            XCTFail("expected degraded")
        }
    }
}
