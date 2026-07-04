import Foundation

/// A private-API capability that Barkeep depends on. Each maps to a `Bridging` call
/// that must return sane values, or the app silently shows nothing.
enum Capability: String, CaseIterable {
    case onScreenWindowList
    case menuBarWindowList
    case windowFrame
    case activeSpace
}

/// The health of one capability on the current OS build.
struct ProbeResult {
    let capability: Capability
    let healthy: Bool
    let detail: String
}

/// Actively verifies the private SkyLight/CGS APIs Barkeep relies on return sane
/// values on the CURRENT macOS build. Converts silent private-API drift into a loud,
/// inspectable signal. Only touches `Bridging`'s public API (no raw CGS here).
enum CapabilityProbe {
    /// The OS version/build string that probe results are stamped against.
    static var osBuild: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Runs each capability's check and returns per-capability results.
    /// - Parameter checks: Capability -> closure returning (healthy, detail). Injectable for tests.
    ///   A capability with no check is reported unhealthy (fail-closed).
    static func run(checks: [Capability: () -> (Bool, String)] = defaultChecks) -> [ProbeResult] {
        Capability.allCases.map { capability in
            guard let check = checks[capability] else {
                return ProbeResult(capability: capability, healthy: false, detail: "no check registered")
            }
            let (healthy, detail) = check()
            return ProbeResult(capability: capability, healthy: healthy, detail: detail)
        }
    }

    /// The real checks against `Bridging`. Each returns (healthy, human-readable detail).
    static var defaultChecks: [Capability: () -> (Bool, String)] {
        [
            .onScreenWindowList: {
                let count = Bridging.getWindowList(option: .onScreen).count
                return (count > 0, "\(count) on-screen windows")
            },
            .menuBarWindowList: {
                let count = Bridging.getWindowList(option: .menuBarItems).count
                return (count > 0, "\(count) menu bar windows")
            },
            .windowFrame: {
                guard let windowID = Bridging.getWindowList(option: .onScreen).first else {
                    return (false, "no on-screen window to sample")
                }
                guard let frame = Bridging.getWindowFrame(for: windowID) else {
                    return (false, "getWindowFrame returned nil for \(windowID)")
                }
                return (frame.width > 0 && frame.height > 0, "frame \(Int(frame.width))x\(Int(frame.height))")
            },
            .activeSpace: {
                let space = Bridging.activeSpaceID
                return (space != 0, "activeSpaceID=\(space)")
            },
        ]
    }

    /// Whether every capability probes healthy right now.
    static var isHealthy: Bool {
        run().allSatisfy(\.healthy)
    }

    /// Logs each probe result, stamped with the OS build. Healthy -> info, unhealthy -> error.
    static func logReport(_ results: [ProbeResult] = run()) {
        let logger = Logger(category: "CapabilityProbe")
        for result in results {
            let message = "[\(osBuild)] \(result.capability.rawValue): \(result.healthy ? "OK" : "UNHEALTHY") — \(result.detail)"
            if result.healthy {
                logger.info(message)
            } else {
                logger.error(message)
            }
        }
    }
}
