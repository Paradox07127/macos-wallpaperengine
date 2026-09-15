#if !LITE_BUILD
import Foundation
import JavaScriptCore
import os

enum WPESceneScriptContainmentDefaults {
    static let maximumConcurrentEvaluations = 4

    /// Four serial VM lanes bound dispatch fan-out while preserving each VM's ordering.
    /// Re-size only from an independent Release trace; authored binding count alone does
    /// not predict per-frame script cost.
    static let batchWorkerWidth = 4

    // There is deliberately NO cap on script instances per scene. WPE has none,
    // and a count cap previously failed whole scenes closed, freezing every
    // scripted clock/date/weekday at its authored placeholder. Per-frame cost
    // is bounded by the tick deadline, the governor and the quarantine instead.
}

final class WPESceneScriptBatchDispatcher: Sendable {
    static let processShared = WPESceneScriptBatchDispatcher(
        width: WPESceneScriptContainmentDefaults.batchWorkerWidth
    )

    /// Frame work unit carries the engine's own queue (never a slot index).
    struct Job {
        let queue: DispatchQueue
        let work: @Sendable () -> Void
    }

    /// An engine's lifetime execution slot: a serial queue plus the `JSVirtualMachine`
    /// every context on it is built in. One VM per WORKER, not per context: a
    /// `JSVirtualMachine` owns a GC heap (measured ~1.15 MB), so a VM per script cost
    /// 1104 x 1.15 MB = 1.27 GB across two scenes — more than every GPU texture combined.
    /// Sharing is safe: the lane is serial, JSC serialises contexts sharing a VM, and these
    /// never run concurrently, so the VM lock is uncontended and no parallelism is lost.
    struct Lane: @unchecked Sendable {
        let queue: DispatchQueue
        let virtualMachine: JSVirtualMachine
        fileprivate let slot: Int
        fileprivate let generation: UInt64
        private let invalidateOwner: @Sendable (Int, UInt64) -> Bool

        fileprivate init(
            queue: DispatchQueue,
            virtualMachine: JSVirtualMachine,
            slot: Int,
            generation: UInt64,
            invalidateOwner: @escaping @Sendable (Int, UInt64) -> Bool
        ) {
            self.queue = queue
            self.virtualMachine = virtualMachine
            self.slot = slot
            self.generation = generation
            self.invalidateOwner = invalidateOwner
        }

        /// Retire this exact generation after a confirmed timeout. The
        /// wedged queue/VM stay alive with the quarantined engine, while
        /// future engines reserve a fresh generation for the same slot.
        @discardableResult
        func invalidate() -> Bool {
            invalidateOwner(slot, generation)
        }
    }

    let width: Int
    /// Unchecked because `JSVirtualMachine` carries no Sendable conformance.
    /// The mechanism is the `OSAllocatedUnfairLock` below: records are only
    /// read or replaced inside `state.withLock`, and a record handed out by
    /// `reserveLane` is thereafter owned by that lane's serial queue.
    private final class LaneVMOwnership: @unchecked Sendable {
        /// Read under the dispatcher lock while installed. Once detached,
        /// only the owning queue clears it; returned Lanes hold their own VM.
        var virtualMachine: JSVirtualMachine? = JSVirtualMachine()
    }

    private struct LaneRecord: @unchecked Sendable {
        let queue: DispatchQueue
        let vmOwnership: LaneVMOwnership
        let generation: UInt64
    }

    /// The lock hands out an owning VM reference before retirement can
    /// detach its record. JSC access remains confined to the lane queue.
    private struct LaneReservation: @unchecked Sendable {
        let slot: Int
        let lane: LaneRecord
        let virtualMachine: JSVirtualMachine
    }

    /// Unchecked for the `LaneRecord` above; the same lock is the mechanism —
    /// this struct exists only as that lock's protected state.
    private struct State: @unchecked Sendable {
        var lanes: [LaneRecord?]
        // Keep generations even when a lane has no VM; an old timeout must
        // never evict a new scene's first reservation of the same slot.
        var generations: [UInt64]
        var nextEngineSlot = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(width: Int) {
        precondition(width > 0, "SceneScript batch width must be positive")
        self.width = width
        state = OSAllocatedUnfairLock(initialState: State(
            lanes: Array(repeating: nil, count: width),
            generations: Array(repeating: 0, count: width)
        ))
    }

    deinit {
        releaseLanesForSceneRetirement()
    }

    func reserveLane() -> Lane {
        let reservation = state.withLock { state -> LaneReservation in
            let slot = state.nextEngineSlot
            state.nextEngineSlot = (slot + 1) % width
            let lane = state.lanes[slot] ?? Self.makeLaneRecord(
                slot: slot, generation: state.generations[slot]
            )
            state.lanes[slot] = lane
            // Copy the VM before unlocking: retirement may detach this
            // record and clear its ownership immediately on another queue.
            return LaneReservation(
                slot: slot, lane: lane,
                virtualMachine: lane.vmOwnership.virtualMachine!
            )
        }
        return Lane(
            queue: reservation.lane.queue,
            virtualMachine: reservation.virtualMachine,
            slot: reservation.slot,
            generation: reservation.lane.generation,
            invalidateOwner: { [weak self] slot, generation in
                self?.invalidateLane(slot: slot, generation: generation) ?? false
            }
        )
    }

    private func invalidateLane(slot: Int, generation: UInt64) -> Bool {
        let retired = state.withLock { state -> LaneRecord? in
            guard state.lanes.indices.contains(slot),
                  state.generations[slot] == generation,
                  let lane = state.lanes[slot] else { return nil }
            state.lanes[slot] = nil
            state.generations[slot] &+= 1
            return lane
        }
        guard let retired else { return false }
        Self.releaseOnLane(retired)
        return true
    }

    /// Drop only the dispatcher's ownership. Engines and queued work keep
    /// their original lane alive until it is safe for them to finish.
    /// Called after the scene's script instances have been retired.
    func releaseLanesForSceneRetirement() {
        let retired = state.withLock { state -> [LaneRecord] in
            let lanes = state.lanes.compactMap(\.self)
            for slot in state.lanes.indices {
                state.lanes[slot] = nil
                state.generations[slot] &+= 1
            }
            state.nextEngineSlot = 0
            return lanes
        }
        for lane in retired {
            Self.releaseOnLane(lane)
        }
    }

    private static func releaseOnLane(_ lane: LaneRecord) {
        // Never release a VM under the dispatcher lock or on the render
        // actor: a still-running context can hold that VM's JSLock.
        lane.queue.async {
            // Explicitly clear the reference here. Merely capturing the
            // record is insufficient if this block runs before the caller
            // drops its temporary copy of the retired records.
            lane.vmOwnership.virtualMachine = nil
        }
    }

    #if DEBUG
    var allocatedLaneCountForTesting: Int {
        state.withLock { $0.lanes.compactMap(\.self).count }
    }
    #endif

    private static func makeLaneRecord(slot: Int, generation: UInt64) -> LaneRecord {
        // `.workItem` pops the autorelease pool after EVERY dispatched block. The default
        // (.inherit → "unspecified times, when the thread idles") never fires under a
        // continuous 30 fps tick stream, so per-tick ObjC temporaries (JSValue boxing, audio
        // bridge exception objects) accumulated for the whole session — 6.3 GB sampled on 2955378002.
        LaneRecord(
            queue: DispatchQueue(
                label: "com.livewallpaper.wpe-script-batch.\(slot).\(generation)",
                qos: .userInitiated,
                autoreleaseFrequency: .workItem
            ),
            vmOwnership: LaneVMOwnership(),
            generation: generation
        )
    }

    func submit(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        var buckets: [ObjectIdentifier: (queue: DispatchQueue, work: [@Sendable () -> Void])] = [:]
        buckets.reserveCapacity(width)
        for job in jobs {
            buckets[ObjectIdentifier(job.queue), default: (job.queue, [])].work.append(job.work)
        }
        for (queue, work) in buckets.values {
            queue.async {
                for unit in work {
                    unit()
                }
            }
        }
    }
}

/// Deadline expiry vs admission rejection (only timeout may still own the JSC queue).
enum WPESceneScriptBoundedExecutionResult<Output> {
    case completed(Output)
    case timedOut
    case capacityUnavailable
}

enum WPESceneScriptAdmissionPolicy {
    case failFast
    case waitUntilDeadline
}

/// Bounded fair admission gate (no execution queue — engines keep their own).
/// One FIFO reservation per participant; frame work is fail-fast, setup may wait to deadline.
final class WPESceneScriptExecutionGovernor: @unchecked Sendable {
    static let processShared = WPESceneScriptExecutionGovernor(
        limit: WPESceneScriptContainmentDefaults.maximumConcurrentEvaluations
    )

    private struct State {
        var active = 0
        var nextParticipantID: UInt64 = 0
        var activeParticipantIDs: Set<UInt64> = []
        var waiters: [UInt64] = []
        #if DEBUG
        var peak = 0
        var permitsGranted = 0
        #endif
    }

    private let limit: Int
    private let maximumWaitingParticipants: Int
    private let condition = NSCondition()
    private var state = State()

    init(
        limit: Int,
        maximumWaitingParticipants: Int = 256
    ) {
        precondition(limit > 0, "SceneScript execution limit must be positive")
        precondition(maximumWaitingParticipants > 0, "SceneScript wait queue limit must be positive")
        self.limit = limit
        self.maximumWaitingParticipants = maximumWaitingParticipants
    }

    func makeParticipant() -> Participant {
        condition.lock()
        state.nextParticipantID &+= 1
        let participantID = state.nextParticipantID
        condition.unlock()
        return Participant(governor: self, id: participantID)
    }

    /// Fail-fast admission for events (does not affect frame FIFO fairness).
    func tryAcquireUnreserved(for participant: Participant) -> Permit? {
        precondition(participant.governor === self, "SceneScript participant belongs to another governor")
        condition.lock()
        defer { condition.unlock() }
        let participantID = participant.id
        guard !state.activeParticipantIDs.contains(participantID),
              waiterIndex(for: participantID) == nil,
              state.waiters.count < availablePermitCount else { return nil }
        return grantPermit(to: participantID)
    }

    /// Wait-until-deadline admission; only method that adds waiters (exit always removes).
    func acquire(
        for participant: Participant,
        until deadline: DispatchTime
    ) -> Permit? {
        precondition(participant.governor === self, "SceneScript participant belongs to another governor")
        condition.lock()
        defer { condition.unlock() }
        let participantID = participant.id

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                removeWaiter(for: participantID)
                condition.broadcast()
                return nil
            }

            if !state.activeParticipantIDs.contains(participantID) {
                if let index = waiterIndex(for: participantID) {
                    if waiterCanAcquire(at: index) {
                        state.waiters.remove(at: index)
                        return grantPermit(to: participantID)
                    }
                } else if state.waiters.count < availablePermitCount {
                    return grantPermit(to: participantID)
                } else if state.waiters.count < maximumWaitingParticipants {
                    state.waiters.append(participantID)
                    if let index = waiterIndex(for: participantID),
                       waiterCanAcquire(at: index) {
                        state.waiters.remove(at: index)
                        return grantPermit(to: participantID)
                    }
                } else {
                    return nil
                }
            } else if waiterIndex(for: participantID) == nil {
                guard state.waiters.count < maximumWaitingParticipants else { return nil }
                state.waiters.append(participantID)
            }

            // Recheck monotonic deadline in slices — Date-based wait can go unbounded.
            let waitNanos = min(deadline.uptimeNanoseconds - now, 50_000_000)
            _ = condition.wait(until: Date(
                timeIntervalSinceNow: Double(waitNanos) / 1_000_000_000
            ))
        }
    }

    private var availablePermitCount: Int {
        max(limit - state.active, 0)
    }

    private func waiterIndex(for participantID: UInt64) -> Int? {
        state.waiters.firstIndex(of: participantID)
    }

    private func waiterCanAcquire(at index: Int) -> Bool {
        index < availablePermitCount
    }

    private func grantPermit(to participantID: UInt64) -> Permit {
        precondition(state.active < limit, "SceneScript permit limit exceeded")
        precondition(
            state.activeParticipantIDs.insert(participantID).inserted,
            "SceneScript participant acquired more than one permit"
        )
        state.active += 1
        #if DEBUG
        state.peak = max(state.peak, state.active)
        state.permitsGranted += 1
        #endif
        return Permit(governor: self, participantID: participantID)
    }

    private func removeWaiter(for participantID: UInt64) {
        state.waiters.removeAll { $0 == participantID }
    }

    private func releasePermit(for participantID: UInt64) {
        condition.lock()
        precondition(state.active > 0, "SceneScript permit accounting underflow")
        precondition(
            state.activeParticipantIDs.remove(participantID) != nil,
            "SceneScript participant permit accounting underflow"
        )
        state.active -= 1
        condition.broadcast()
        condition.unlock()
    }

    final class Participant: @unchecked Sendable {
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let id: UInt64

        fileprivate init(governor: WPESceneScriptExecutionGovernor, id: UInt64) {
            self.governor = governor
            self.id = id
        }
    }

    /// Reference-semantic permit; release in engine-queue `defer` (deinit is fail-safe).
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var governor: WPESceneScriptExecutionGovernor?
        private let participantID: UInt64

        fileprivate init(governor: WPESceneScriptExecutionGovernor, participantID: UInt64) {
            self.governor = governor
            self.participantID = participantID
        }

        func release() {
            lock.lock()
            let owner = governor
            governor = nil
            lock.unlock()
            owner?.releasePermit(for: participantID)
        }

        deinit {
            release()
        }
    }

    #if DEBUG
    struct DebugSnapshot: Sendable, Equatable {
        let active: Int
        let peak: Int
        let permitsGranted: Int
        let waitingParticipants: Int
    }

    var debugSnapshot: DebugSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return DebugSnapshot(
            active: state.active,
            peak: state.peak,
            permitsGranted: state.permitsGranted,
            waitingParticipants: state.waiters.count
        )
    }
    #endif
}

enum WPESceneScriptOperation: String, Sendable, CaseIterable {
    case setup
    case tick
    case event
    case userProperties
    case staticTransform
}

enum WPESceneScriptFailClosedReason: Sendable, Equatable {
    case executionTimedOut(operation: WPESceneScriptOperation)
    case capacityUnavailable(operation: WPESceneScriptOperation)
    case createdLayerLimitExceeded(limit: Int)
    case videoCommandLimitExceeded(limit: Int)
    case sharedStateLimitExceeded(limit: Int)
    case timerCallbackLimitExceeded(limit: Int)
    case quarantineLimitReached(limit: Int)
}

/// Load-time count of JS runtimes the renderer would construct (not parser-local static).
struct WPESceneScriptInstanceInventory: Sendable, Equatable {
    let text: Int
    let layer: Int
    let transform: Int

    init(text: Int, layer: Int, transform: Int) {
        precondition(text >= 0 && layer >= 0 && transform >= 0)
        self.text = text
        self.layer = layer
        self.transform = transform
    }

    var total: Int {
        let (textAndLayer, firstOverflow) = text.addingReportingOverflow(layer)
        let (total, secondOverflow) = textAndLayer.addingReportingOverflow(transform)
        return firstOverflow || secondOverflow ? .max : total
    }
}

/// Immutable load identity + first-failure latch (limit+1 rejects all constructors).
final class WPESceneScriptInstanceLimitToken: @unchecked Sendable {
    let generation: Int

    private struct State {
        var preparedInventory: WPESceneScriptInstanceInventory?
        var failureReason: WPESceneScriptFailClosedReason?
        var isRetired = false
    }

    private let resourceBudget: WPESceneScriptSceneResourceBudget
    let executionQuarantine: WPESceneScriptQuarantine
    private let lock = NSLock()
    private var state = State()

    init(
        generation: Int,
        resourceBudget: WPESceneScriptSceneResourceBudget = WPESceneScriptSceneResourceBudget(),
        executionQuarantine: WPESceneScriptQuarantine = .processShared
    ) {
        self.generation = generation
        self.resourceBudget = resourceBudget
        self.executionQuarantine = executionQuarantine
    }

    @discardableResult
    func prepare(_ inventory: WPESceneScriptInstanceInventory) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isRetired, state.preparedInventory == nil else { return false }
        state.preparedInventory = inventory
        return true
    }

    var failureReason: WPESceneScriptFailClosedReason? {
        lock.lock()
        defer { lock.unlock() }
        return state.failureReason
    }

    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isRetired
    }

    func allows(_: WPESceneScriptOperation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !state.isRetired && state.failureReason == nil
    }

    func withConstructionPermission<Instance>(
        _ construct: () throws -> Instance
    ) rethrows -> Instance? {
        lock.lock()
        let permitted = !state.isRetired
            && state.failureReason == nil
            && state.preparedInventory != nil
        lock.unlock()
        guard permitted else { return nil }
        guard executionQuarantine.canConstructRuntime else {
            failClosed(.quarantineLimitReached(
                limit: executionQuarantine.limit
            ))
            return nil
        }
        let instance = try construct()
        return acceptsCompletion() ? instance : nil
    }

    func acceptsCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !state.isRetired && state.failureReason == nil
    }

    /// Completion linearization under failure/retirement lock; must not re-enter token.
    @discardableResult
    func withCompletionPermission(
        _ commit: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isRetired, state.failureReason == nil else { return false }
        try commit()
        return true
    }

    @discardableResult
    func failClosed(_ reason: WPESceneScriptFailClosedReason) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isRetired, state.failureReason == nil else { return false }
        state.failureReason = reason
        return true
    }

    func admitCreatedLayer() -> Bool {
        guard acceptsCompletion() else { return false }
        guard resourceBudget.admitCreatedLayer() == .accepted else {
            failClosed(.createdLayerLimitExceeded(
                limit: WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene
            ))
            return false
        }
        return acceptsCompletion()
    }

    func admitNewSharedStateEntry() -> Bool {
        guard acceptsCompletion() else { return false }
        guard resourceBudget.admitNewSharedStateEntry() == .accepted else {
            failClosed(.sharedStateLimitExceeded(
                limit: WPESceneScriptContainmentDefaults.maximumSharedStateEntries
            ))
            return false
        }
        return acceptsCompletion()
    }

    var resourceSnapshot: WPESceneScriptSceneResourceBudget.Snapshot {
        resourceBudget.snapshot
    }

    func retire() {
        lock.lock()
        state.isRetired = true
        lock.unlock()
    }
}

/// Thread-safe current B2a load identity (retire never clears a newer token).
final class WPESceneScriptLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: WPESceneScriptInstanceLimitToken?

    func begin(generation: Int) -> WPESceneScriptInstanceLimitToken {
        let token = WPESceneScriptInstanceLimitToken(generation: generation)
        lock.lock()
        let previous = current
        previous?.retire()
        current = token
        lock.unlock()
        return token
    }

    func isCurrent(_ token: WPESceneScriptInstanceLimitToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current === token
            && current?.generation == token.generation
            && !token.isRetired
    }

    @discardableResult
    func withCurrentCompletionPermission(
        _ commit: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let token = current else { return false }
        return try token.withCompletionPermission(commit)
    }

    /// Load completion carries its token so a stale load cannot borrow permission.
    @discardableResult
    func withCompletionPermission(
        for token: WPESceneScriptInstanceLimitToken,
        _ commit: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current === token,
              current?.generation == token.generation else { return false }
        return try token.withCompletionPermission(commit)
    }

    func retire(_ token: WPESceneScriptInstanceLimitToken) {
        lock.lock()
        if current === token {
            current = nil
        }
        lock.unlock()
        token.retire()
    }

    func retireCurrent() {
        lock.lock()
        let token = current
        current = nil
        lock.unlock()
        token?.retire()
    }

    var currentFailureReason: WPESceneScriptFailClosedReason? {
        lock.lock()
        defer { lock.unlock() }
        return current?.failureReason
    }
}

#endif
