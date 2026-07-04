import Combine
import Foundation

/// Overall health of the private-API layer.
enum HealthStatus: Equatable {
    /// All active probes healthy and no runtime failures recorded.
    case healthy
    /// One or more capabilities probed unhealthy, and/or runtime failures were recorded.
    case degraded(capabilities: [Capability], recentFailures: Int)
}

/// The watchdog: combines the active `CapabilityProbe` and the passive
/// `BridgingHealth` recorder into a single observable `HealthStatus`, re-evaluated
/// on a periodic timer and on demand. When a private API breaks after an OS update,
/// the status flips to `.degraded` so the UI and logs report it instead of the app
/// silently misbehaving.
@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var status: HealthStatus = .healthy

    private weak var appState: AppState?
    private var timer: Timer?
    private let logger = Logger(category: "HealthMonitor")

    /// The watchdog re-evaluation interval, in seconds.
    private let interval: TimeInterval = 60

    init(appState: AppState?) {
        self.appState = appState
    }

    /// Starts the watchdog: an immediate evaluation followed by periodic re-evaluation.
    func performSetup() {
        evaluate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Re-computes `status` from the active probe and passive failure counts.
    /// - Parameters:
    ///   - probe: Source of capability probe results (injectable for tests).
    ///   - failures: Source of the total runtime failure count (injectable for tests).
    func evaluate(
        probe: () -> [ProbeResult] = { CapabilityProbe.run() },
        failures: () -> Int = { BridgingHealth.shared.totalFailures }
    ) {
        let unhealthy = probe().filter { !$0.healthy }.map(\.capability)
        let failureCount = failures()
        let newStatus: HealthStatus = (unhealthy.isEmpty && failureCount == 0)
            ? .healthy
            : .degraded(capabilities: unhealthy, recentFailures: failureCount)
        if newStatus != status {
            logger.info("health status changed: \(String(describing: newStatus))")
        }
        status = newStatus
    }
}
