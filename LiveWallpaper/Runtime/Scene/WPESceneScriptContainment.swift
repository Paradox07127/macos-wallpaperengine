#if !LITE_BUILD
    import Foundation
    import JavaScriptCore
    import os

    /// Conservative containment defaults for community SceneScript (see ResourceBudget for host limits).
    enum WPESceneScriptContainmentDefaults {
        /// Cap on concurrent in-process evaluations (permit held on engine queue).
        static let maximumConcurrentEvaluations = 4

        /// Batch workers (4): heaviest scene ~3.7ms work → ~1ms/bucket vs 16.7ms frame.
        static let batchWorkerWidth = 4

        // There is deliberately NO cap on script instances per scene. WPE has none,
        // and a count cap measured worthless here: 2955378002 runs 676 script
        // bindings for 8.5ms of CPU per frame while 3509243656 runs 185 for 13.5ms.
        // It only ever failed whole scenes closed, freezing every scripted
        // clock/date/weekday at its authored placeholder. Per-frame cost is bounded
        // by the tick deadline, the governor and the quarantine instead.

    }

    /// One GCD job per worker per frame (not per script). Concurrency = worker count;
    /// each engine's context stays on its assigned serial queue for the scene lifetime.
    final class WPESceneScriptBatchDispatcher: Sendable {
        static let processShared = WPESceneScriptBatchDispatcher(
            width: WPESceneScriptContainmentDefaults.batchWorkerWidth
        )

        /// Frame work unit carries the engine's own queue (never a slot index).
        struct Job {
            let queue: DispatchQueue
            let work: @Sendable () -> Void
        }

        /// An engine's lifetime execution slot: a serial queue plus the
        /// `JSVirtualMachine` every context on that queue is built in.
        ///
        /// One VM per WORKER, not per context. A `JSVirtualMachine` owns a GC
        /// heap (measured ~1.15 MB), so a VM per script cost 1104 x 1.15 MB =
        /// 1.27 GB across two scenes — more than every GPU texture combined.
        /// Sharing is safe precisely because the lane is serial: JSC serialises
        /// contexts that share a VM, and these already never run concurrently,
        /// so the VM lock is uncontended and no parallelism is lost.
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
        private struct LaneRecord: @unchecked Sendable {
            let queue: DispatchQueue
            let virtualMachine: JSVirtualMachine
            let generation: UInt64
        }

        /// Unchecked for the `LaneRecord` above; the same lock is the mechanism —
        /// this struct exists only as that lock's protected state.
        private struct State: @unchecked Sendable {
            var lanes: [LaneRecord]
            var nextEngineSlot = 0
        }

        private let state: OSAllocatedUnfairLock<State>

        init(width: Int) {
            precondition(width > 0, "SceneScript batch width must be positive")
            self.width = width
            // `.workItem` pops the autorelease pool after EVERY dispatched block.
            // The default (.inherit → "unspecified times, when the thread idles")
            // never fires under a continuous 30 fps tick stream, so per-tick ObjC
            // temporaries (JSValue boxing in the audio bridge, exception objects)
            // accumulated for the whole session — sampled at 6.3 GB on 2955378002.
            state = OSAllocatedUnfairLock(initialState: State(
                lanes: (0 ..< width).map { Self.makeLaneRecord(slot: $0, generation: 0) }
            ))
        }

        /// Lifetime execution lane for one engine (round-robin at construction).
        func reserveLane() -> Lane {
            let reservation = state.withLock { state -> (Int, LaneRecord) in
                let slot = state.nextEngineSlot
                state.nextEngineSlot = (slot + 1) % width
                return (slot, state.lanes[slot])
            }
            return Lane(
                queue: reservation.1.queue,
                virtualMachine: reservation.1.virtualMachine,
                slot: reservation.0,
                generation: reservation.1.generation,
                invalidateOwner: { [weak self] slot, generation in
                    self?.invalidateLane(slot: slot, generation: generation) ?? false
                }
            )
        }

        private func invalidateLane(slot: Int, generation: UInt64) -> Bool {
            state.withLock { state in
                guard state.lanes.indices.contains(slot),
                      state.lanes[slot].generation == generation else { return false }
                let nextGeneration = generation &+ 1
                state.lanes[slot] = Self.makeLaneRecord(
                    slot: slot,
                    generation: nextGeneration
                )
                return true
            }
        }

        private static func makeLaneRecord(slot: Int, generation: UInt64) -> LaneRecord {
            LaneRecord(
                queue: DispatchQueue(
                    label: "com.livewallpaper.wpe-script-batch.\(slot).\(generation)",
                    qos: .userInitiated,
                    autoreleaseFrequency: .workItem
                ),
                virtualMachine: JSVirtualMachine(),
                generation: generation
            )
        }

        /// Render thread: hand off frame ticks (≤1 dispatch per worker).
        func submit(_ jobs: [Job]) {
            guard !jobs.isEmpty else { return }
            var buckets: [ObjectIdentifier: (queue: DispatchQueue, work: [@Sendable () -> Void])] = [:]
            buckets.reserveCapacity(width)
            for job in jobs {
                buckets[ObjectIdentifier(job.queue), default: (job.queue, [])].work.append(job.work)
            }
            for (queue, work) in buckets.values {
                queue.async {
                    for unit in work { unit() }
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

        /// Stable identity retained by one evaluator/engine.
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

        /// Stable identity for one evaluator.
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
            /// Debug/test-only diagnostic surface.
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

    /// First failure that disables a scene's entire script subsystem.
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

        /// Once before any renderer runtime is constructed; later calls are inert.
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

        var preparedInventory: WPESceneScriptInstanceInventory? {
            lock.lock()
            defer { lock.unlock() }
            return state.preparedInventory
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

        /// Queue-side publish gate (separate from `allows` for late-completion tests).
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

        /// Authorize completion against the exact current token (no re-entry under locks).
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

    /// Thread-safe per-scene snapshot + first-failure latch (B2b primitive).
    ///
    /// TODO: never wired — no production renderer adopts it, so only the
    /// characterization tests exercise it. Adopt it in the script snapshot path
    /// or retire it with `WPESceneScriptClaimedOutcomeSlot`.
    final class WPESceneScriptFailClosedState<Snapshot: Sendable>: @unchecked Sendable {
        private struct State {
            var lastCompleted: Snapshot?
            var failureReason: WPESceneScriptFailClosedReason?
        }

        private let baked: Snapshot
        private let lock = NSLock()
        private var state = State()

        init(baked: Snapshot) {
            self.baked = baked
        }

        var presentedSnapshot: Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return state.lastCompleted ?? baked
        }

        var failureReason: WPESceneScriptFailClosedReason? {
            lock.lock()
            defer { lock.unlock() }
            return state.failureReason
        }

        func allows(_: WPESceneScriptOperation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.failureReason == nil
        }

        /// False if already failed; late results never replace the last stable snapshot.
        @discardableResult
        func publishCompleted(_ snapshot: Snapshot) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.failureReason == nil else { return false }
            state.lastCompleted = snapshot
            return true
        }

        /// First failure wins (deterministic diagnostics).
        @discardableResult
        func failClosed(_ reason: WPESceneScriptFailClosedReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.failureReason == nil else { return false }
            state.failureReason = reason
            return true
        }
    }

    /// Latest-outcome exchange with generation-token claims (stale cannot clear newer).
    ///
    /// TODO: never wired — see `WPESceneScriptFailClosedState`.
    final class WPESceneScriptClaimedOutcomeSlot<Outcome: Sendable>: @unchecked Sendable {
        struct Claim: Sendable, Equatable {
            fileprivate let generation: UInt64
        }

        private struct State {
            var nextGeneration: UInt64 = 0
            var inFlightGeneration: UInt64?
            var latest: Outcome?
        }

        private let lock = NSLock()
        private var state = State()

        var isInFlight: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.inFlightGeneration != nil
        }

        func beginClaim() -> Claim? {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == nil else { return nil }
            state.nextGeneration &+= 1
            state.inFlightGeneration = state.nextGeneration
            return Claim(generation: state.nextGeneration)
        }

        /// Release only matching claim; false if generation is stale.
        @discardableResult
        func reject(_ claim: Claim) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == claim.generation else { return false }
            state.inFlightGeneration = nil
            return true
        }

        /// Publish only for active claim; stale generation is discarded.
        @discardableResult
        func publish(_ outcome: Outcome, for claim: Claim) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == claim.generation else { return false }
            state.inFlightGeneration = nil
            state.latest = outcome
            return true
        }

        func takeLatest() -> Outcome? {
            lock.lock()
            defer { lock.unlock() }
            defer { state.latest = nil }
            return state.latest
        }
    }
#endif
