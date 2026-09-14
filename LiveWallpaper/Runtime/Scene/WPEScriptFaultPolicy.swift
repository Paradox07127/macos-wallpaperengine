#if !LITE_BUILD
import Foundation

enum WPEScriptFaultVerdict: Equatable {
    case backoff(skippedFrames: Int)
    /// Backoff exhausted; retry at most once per `probeInterval`.
    case probing
    /// Same signature failed `quarantineProbeLimit` probes and the entry point
    /// never succeeded once — stop attempting it for this engine's lifetime.
    case quarantined
}

/// Keyed by entry point only, not the exception message: a timestamped Error would never reach quarantine.
struct WPEScriptFaultPolicy {
    /// Attempts skipped after the 1st, 2nd and 3rd consecutive failure.
    static let backoffFrames: [Int] = [1, 8, 64]
    /// Minimum spacing of retries once backoff is exhausted.
    static let probeInterval: TimeInterval = 1.0
    /// Failed probes before hard quarantine; only for entry points that never succeeded.
    static let quarantineProbeLimit = 12

    private struct FaultState {
        var failureCount = 0
        var skipRemaining = 0
        var nextProbeAt: Double?
        var probeFailures = 0
        var isQuarantined = false
    }

    private var faults: [String: FaultState] = [:]
    private var succeededEntryPoints: Set<String> = []

    /// Uptime seconds; the engines' shared `now` source for `at:` arguments.
    static func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// One call per would-be attempt: a `false` during backoff consumes one
    /// skipped frame. Always `true` for an entry point with no recorded fault.
    mutating func shouldAttempt(entryPoint: String, at now: Double) -> Bool {
        guard var state = faults[entryPoint] else { return true }
        if state.isQuarantined { return false }
        if state.skipRemaining > 0 {
            state.skipRemaining -= 1
            faults[entryPoint] = state
            return false
        }
        if let nextProbeAt = state.nextProbeAt { return now >= nextProbeAt }
        return true
    }

    @discardableResult
    mutating func recordFailure(entryPoint: String, at now: Double) -> WPEScriptFaultVerdict {
        var state = faults[entryPoint] ?? FaultState()
        state.failureCount += 1
        if state.failureCount <= Self.backoffFrames.count {
            state.skipRemaining = Self.backoffFrames[state.failureCount - 1]
            state.nextProbeAt = nil
            faults[entryPoint] = state
            return .backoff(skippedFrames: state.skipRemaining)
        }
        state.probeFailures += 1
        if state.probeFailures >= Self.quarantineProbeLimit,
           !succeededEntryPoints.contains(entryPoint) {
            state.isQuarantined = true
            faults[entryPoint] = state
            return .quarantined
        }
        state.nextProbeAt = now + Self.probeInterval
        faults[entryPoint] = state
        return .probing
    }

    /// Any success clears the entry point's fault state and permanently exempts
    /// it from hard quarantine (it degrades to 1 Hz probing instead).
    mutating func recordSuccess(entryPoint: String) {
        succeededEntryPoints.insert(entryPoint)
        faults.removeValue(forKey: entryPoint)
    }
}
#endif
