#if !LITE_BUILD
import Foundation

extension WPESceneScriptContainmentDefaults {
    static let maximumCreatedLayersPerScene = 64
    static let maximumVideoCommandsPerEvaluation = 256
    static let maximumSharedStateEntries = 1024
    static let maximumQuarantinedEngines = 16
}

/// Owns the scene-wide host-bridge counters. Evaluators share this through the
/// immutable load token instead of maintaining one counter per script family.
final class WPESceneScriptSceneResourceBudget: @unchecked Sendable {
    enum Admission: Sendable, Equatable {
        case accepted
        case limitExceeded
    }

    private struct State {
        var createdLayers = 0
        var sharedStateEntries = 0
    }

    private let createdLayerLimit: Int
    private let sharedStateEntryLimit: Int
    private let lock = NSLock()
    private var state = State()

    init(
        createdLayerLimit: Int = WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene,
        sharedStateEntryLimit: Int = WPESceneScriptContainmentDefaults.maximumSharedStateEntries
    ) {
        precondition(createdLayerLimit >= 0 && sharedStateEntryLimit >= 0)
        self.createdLayerLimit = createdLayerLimit
        self.sharedStateEntryLimit = sharedStateEntryLimit
    }

    func admitCreatedLayer() -> Admission {
        lock.lock()
        defer { lock.unlock() }
        guard state.createdLayers < createdLayerLimit else { return .limitExceeded }
        state.createdLayers += 1
        return .accepted
    }

    func admitNewSharedStateEntry() -> Admission {
        lock.lock()
        defer { lock.unlock() }
        guard state.sharedStateEntries < sharedStateEntryLimit else { return .limitExceeded }
        state.sharedStateEntries += 1
        return .accepted
    }

    struct Snapshot: Sendable, Equatable {
        let createdLayers: Int
        let sharedStateEntries: Int
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            createdLayers: state.createdLayers,
            sharedStateEntries: state.sharedStateEntries
        )
    }
}

/// Per-evaluation quota for the only unbounded one-shot payload emitted by a
/// layer script. The engine resets it immediately before each JS entry point.
final class WPESceneScriptEvaluationResourceBudget: @unchecked Sendable {
    private let sceneToken: WPESceneScriptInstanceLimitToken?
    private let videoCommandLimit: Int
    private var videoCommandCount = 0

    init(
        sceneToken: WPESceneScriptInstanceLimitToken?,
        videoCommandLimit: Int = WPESceneScriptContainmentDefaults.maximumVideoCommandsPerEvaluation
    ) {
        precondition(videoCommandLimit >= 0)
        self.sceneToken = sceneToken
        self.videoCommandLimit = videoCommandLimit
    }

    func beginEvaluation() {
        videoCommandCount = 0
    }

    func admitVideoCommand() -> Bool {
        guard sceneToken?.acceptsCompletion() ?? true else { return false }
        guard videoCommandCount < videoCommandLimit else {
            sceneToken?.failClosed(.videoCommandLimitExceeded(limit: videoCommandLimit))
            return false
        }
        videoCommandCount += 1
        return true
    }

    #if DEBUG
    var admittedVideoCommandCount: Int {
        videoCommandCount
    }
    #endif
}

/// Process-wide cap on retained timed-out JSC engines (cannot kill while(true) in-process).
final class WPESceneScriptQuarantine: @unchecked Sendable {
    static let processShared = WPESceneScriptQuarantine(
        limit: WPESceneScriptContainmentDefaults.maximumQuarantinedEngines
    )

    private struct State {
        var nextReservationID: UInt64 = 0
        var activeReservationIDs: Set<UInt64> = []
        var quarantinedEngines: [UInt64: AnyObject] = [:]
    }

    let limit: Int
    private let lock = NSLock()
    private var state = State()

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    var canConstructRuntime: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.quarantinedEngines.count < limit
    }

    var isQuarantineFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.quarantinedEngines.count >= limit
    }

    func reserve() -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        guard state.quarantinedEngines.count + state.activeReservationIDs.count < limit else {
            return nil
        }
        state.nextReservationID &+= 1
        let id = state.nextReservationID
        state.activeReservationIDs.insert(id)
        return Reservation(owner: self, id: id)
    }

    private func complete(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.activeReservationIDs.remove(id) != nil
    }

    /// Only the executing lane may acknowledge completion after a timeout.
    /// Release the retained engine outside the registry lock, on that lane.
    private func executionDidFinish(_ id: UInt64) -> Bool {
        lock.lock()
        let wasActive = state.activeReservationIDs.remove(id) != nil
        let engine = state.quarantinedEngines.removeValue(forKey: id)
        lock.unlock()
        let removed = wasActive || engine != nil
        withExtendedLifetime(engine) {}
        return removed
    }

    private func quarantine(_ engine: AnyObject, reservationID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state.activeReservationIDs.remove(reservationID) != nil else { return false }
        precondition(state.quarantinedEngines.count < limit, "SceneScript quarantine overflow")
        state.quarantinedEngines[reservationID] = engine
        return true
    }

    struct Snapshot: Sendable, Equatable {
        let activeReservations: Int
        let quarantinedEngines: Int
        let limit: Int
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            activeReservations: state.activeReservationIDs.count,
            quarantinedEngines: state.quarantinedEngines.count,
            limit: limit
        )
    }

    final class Reservation: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: WPESceneScriptQuarantine?
        private var isQuarantined = false
        private let id: UInt64

        fileprivate init(owner: WPESceneScriptQuarantine, id: UInt64) {
            self.owner = owner
            self.id = id
        }

        @discardableResult
        func complete() -> Bool {
            lock.lock()
            // Dropping a watchdog/reservation is not evidence that JS has
            // returned. Keep timed-out engines until the lane confirms it.
            guard !isQuarantined else { lock.unlock(); return false }
            let registry = owner
            owner = nil
            lock.unlock()
            return registry?.complete(id) ?? false
        }

        /// Late watchdogs never retain a finished evaluation. Preserve the
        /// owner after quarantine so the actual lane can later release it.
        @discardableResult
        func quarantine(_ engine: AnyObject) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isQuarantined, let owner,
                  owner.quarantine(engine, reservationID: id) else { return false }
            isQuarantined = true
            return true
        }

        /// Distinct from cancellation/deinit: callers must have returned
        /// from execution, or have rejected the work before dispatching it.
        fileprivate func executionDidFinish() -> Bool {
            lock.lock()
            let registry = owner
            owner = nil
            lock.unlock()
            return registry?.executionDidFinish(id) ?? false
        }

        deinit {
            complete()
        }
    }
}

final class WPESceneScriptExecutionSafetyReservation: @unchecked Sendable {
    private let reservation: WPESceneScriptQuarantine.Reservation
    private let sceneToken: WPESceneScriptInstanceLimitToken?

    private init(
        reservation: WPESceneScriptQuarantine.Reservation,
        sceneToken: WPESceneScriptInstanceLimitToken?
    ) {
        self.reservation = reservation
        self.sceneToken = sceneToken
    }

    static func reserve(
        sceneToken: WPESceneScriptInstanceLimitToken?
    ) -> WPESceneScriptExecutionSafetyReservation? {
        let quarantine = sceneToken?.executionQuarantine ?? .processShared
        guard let reservation = quarantine.reserve() else {
            // Only retained timed-out engines latch the scene closed (active = transient).
            if quarantine.isQuarantineFull {
                sceneToken?.failClosed(.quarantineLimitReached(
                    limit: quarantine.limit
                ))
            }
            return nil
        }
        return WPESceneScriptExecutionSafetyReservation(
            reservation: reservation,
            sceneToken: sceneToken
        )
    }

    func complete() {
        // Every dispatched caller invokes this in its worker-lane defer;
        // admission failures call it before any work is dispatched.
        // Reclaiming ownership never changes the scene's fail-closed token.
        _ = reservation.executionDidFinish()
    }

    @discardableResult
    func quarantine(
        _ engine: AnyObject,
        operation: WPESceneScriptOperation
    ) -> Bool {
        guard reservation.quarantine(engine) else { return false }
        sceneToken?.failClosed(.executionTimedOut(operation: operation))
        return true
    }
}

/// Per-evaluator async slot the frame watchdog probes (no per-tick GCD timer).
final class WPESceneScriptAsyncExecutionSafety: @unchecked Sendable {
    struct Overrun: Sendable, Equatable {
        let operation: WPESceneScriptOperation
        let elapsed: TimeInterval
    }

    private struct State {
        var reservation: WPESceneScriptExecutionSafetyReservation?
        var operation: WPESceneScriptOperation?
        var startedAtUptimeNanos: UInt64?
    }

    private let lock = NSLock()
    private var state = State()

    func begin(
        sceneToken: WPESceneScriptInstanceLimitToken?,
        operation: WPESceneScriptOperation
    ) -> WPESceneScriptExecutionSafetyReservation? {
        guard let reservation = WPESceneScriptExecutionSafetyReservation.reserve(
            sceneToken: sceneToken
        ) else { return nil }
        lock.lock()
        guard state.reservation == nil else {
            lock.unlock()
            reservation.complete()
            return nil
        }
        state.reservation = reservation
        state.operation = operation
        state.startedAtUptimeNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        return reservation
    }

    func complete(_ reservation: WPESceneScriptExecutionSafetyReservation) {
        lock.lock()
        guard state.reservation === reservation else {
            lock.unlock()
            reservation.complete()
            return
        }
        state = State()
        lock.unlock()
        reservation.complete()
    }

    func quarantineIfOverdue(
        budget: TimeInterval,
        engine: AnyObject
    ) -> Overrun? {
        lock.lock()
        guard let reservation = state.reservation,
              let operation = state.operation,
              let started = state.startedAtUptimeNanos else {
            lock.unlock()
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- started) / 1_000_000_000
        guard elapsed > max(budget, 0) else {
            lock.unlock()
            return nil
        }
        state = State()
        lock.unlock()
        guard reservation.quarantine(engine, operation: operation) else { return nil }
        return Overrun(operation: operation, elapsed: elapsed)
    }
}
#endif
