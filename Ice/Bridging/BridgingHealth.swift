import Foundation

/// Thread-safe passive recorder of private-API (CGS) call failures observed at
/// runtime by the `Bridging` layer. Complements `CapabilityProbe` (active, at
/// launch): this captures failures that happen during normal operation, so a
/// private API that starts failing after an OS update becomes an inspectable
/// signal instead of silent breakage.
final class BridgingHealth {
    static let shared = BridgingHealth()

    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private let logger = Logger(category: "BridgingHealth")

    /// Records one failure of the named CGS API.
    /// - Parameters:
    ///   - api: The CGS function name, e.g. "CGSGetWindowList".
    ///   - detail: A short human-readable detail (typically the error code).
    func record(_ api: String, detail: String) {
        lock.lock()
        let newCount = (failures[api] ?? 0) + 1
        failures[api] = newCount
        lock.unlock()
        logger.error("private API \(api) failed (count \(newCount)): \(detail)")
    }

    /// The number of recorded failures for the named API.
    func failureCount(for api: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failures[api] ?? 0
    }

    /// The total number of recorded failures across all APIs.
    var totalFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures.values.reduce(0, +)
    }

    /// A copy of the current per-API failure counts.
    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    /// Clears all recorded failures.
    func reset() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
    }
}
