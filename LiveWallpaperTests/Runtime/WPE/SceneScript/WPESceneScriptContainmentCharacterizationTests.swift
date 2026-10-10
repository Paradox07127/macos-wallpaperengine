import Foundation
@testable import LiveWallpaper
import Testing

struct WPESceneScriptContainmentCharacterizationTests {
    @Test("Containment defaults are conservative and explicitly policy-bound")
    func containmentDefaultsAreConservative() {
        #expect((1 ... 8).contains(WPESceneScriptContainmentDefaults.maximumConcurrentEvaluations))
        #expect(WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene <= 128)
        #expect(WPESceneScriptContainmentDefaults.maximumVideoCommandsPerEvaluation <= 512)
        #expect(WPESceneScriptContainmentDefaults.maximumSharedStateEntries <= 2048)
        #expect(WPESceneScriptContainmentDefaults.maximumQuarantinedEngines <= 32)
    }

    @Test("B2b failure before completion permission produces zero side effects")
    func failureBeforeCompletionPermissionRejectsCommit() {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 401)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        #expect(token.failClosed(.executionTimedOut(operation: .tick)))
        var sideEffects = 0

        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(!state.withCompletionPermission(for: token) { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("B2b completion holding permission linearizes before concurrent fail-close")
    func completionPermissionLinearizesConcurrentFailure() throws {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 402)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        let commitBlocker = RR10ControlledBlocker()
        let queue = DispatchQueue(
            label: "com.livewallpaper.tests.rr10-completion-linearization",
            attributes: .concurrent
        )
        let commitAccepted = RR10LockedValue<Bool?>(nil)
        let failureAccepted = RR10LockedValue<Bool?>(nil)
        let sideEffects = RR10LockedValue(0)
        let order = RR10LockedValue<[String]>([])
        let failureStarted = DispatchSemaphore(value: 0)
        let failureFinished = DispatchGroup()
        failureFinished.enter()
        defer { commitBlocker.release() }

        queue.async {
            let accepted = state.withCompletionPermission(for: token) {
                commitBlocker.run()
                sideEffects.modify { $0 += 1 }
                order.modify { $0.append("commit") }
            }
            commitAccepted.set(accepted)
            commitBlocker.markFinished()
        }
        try #require(commitBlocker.waitUntilEntered())

        let reason = WPESceneScriptFailClosedReason.executionTimedOut(operation: .tick)
        queue.async {
            failureStarted.signal()
            failureAccepted.set(token.failClosed(reason))
            order.modify { $0.append("fail") }
            failureFinished.leave()
        }
        try #require(failureStarted.wait(timeout: .now() + 2) == .success)
        commitBlocker.release()
        try #require(commitBlocker.waitUntilFinished())
        try #require(failureFinished.wait(timeout: .now() + 2) == .success)

        #expect(commitAccepted.value == true)
        #expect(failureAccepted.value == true)
        #expect(sideEffects.value == 1)
        #expect(order.value == ["commit", "fail"])
        #expect(token.failureReason == reason)
        #expect(!commitBlocker.hitHardDeadline)
    }

    @Test("B2b retired and superseded identities receive zero completion effects")
    func retiredAndSupersededCompletionIsRejected() {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 403)
        #expect(old.prepare(.init(text: 0, layer: 1, transform: 0)))
        let replacement = state.begin(generation: 404)
        #expect(replacement.prepare(.init(text: 0, layer: 1, transform: 0)))
        var sideEffects = 0

        #expect(!state.withCompletionPermission(for: old) { sideEffects += 1 })
        state.retire(replacement)
        #expect(!state.withCompletionPermission(for: replacement) { sideEffects += 1 })
        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("Rejected ticks cannot publish over a current outcome-slot claim")
    func rejectedTicksCannotPublishOverCurrentClaim() throws {
        // Existing event output is still drainable, but cannot certify a rejected
        // tick. A stale publish must neither revive that claim nor overwrite output.
        let slot = WPESceneScriptOutcomeSlot<Int>()
        slot.publishEvent(7)
        let rejected = try #require(slot.beginTick())
        #expect(slot.rejectTick(rejected))
        #expect(!slot.didComplete(rejected))
        #expect(slot.takeLatest() == 7)
        let current = try #require(slot.beginTick())
        #expect(!slot.publishTick(8, for: rejected))
        #expect(!slot.didComplete(current))
        #expect(slot.publishTick(9, for: current))
        #expect(slot.didComplete(current))
        #expect(!slot.didComplete(rejected))
        #expect(slot.takeLatest() == 9)
    }

    // MARK: - Production primitive behavior

    @Test("B2a a script-heavy scene constructs every runtime — there is no count cap")
    func sceneRuntimeInventoryHasNoInstanceCap() throws {
        let state = WPESceneScriptLoadState()
        let heavy = WPESceneScriptInstanceInventory(text: 300, layer: 200, transform: 176)
        #expect(heavy.total == 676)
        let accepted = state.begin(generation: 1)
        #expect(accepted.prepare(heavy))
        var attempts = 0
        for _ in 0 ..< heavy.total {
            _ = try #require(accepted.withConstructionPermission { attempts += 1 })
        }
        #expect(attempts == 676)
        #expect(accepted.failureReason == nil)
    }

    @Test("Re-preparing an already-prepared load is still refused")
    func sceneRuntimeInventoryRejectsSecondPrepare() throws {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 1)
        #expect(token.prepare(.init(text: 4, layer: 4, transform: 4)))
        #expect(!token.prepare(.init(text: 1, layer: 0, transform: 0)))
    }

    @Test("Retired interleaved load cannot prepare construct or publish into fresh load")
    func sceneRuntimeLateCompletionAndLifecycleReset() throws {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 1)
        #expect(old.prepare(.init(text: 1, layer: 0, transform: 0)))
        let fresh = state.begin(generation: 2)
        #expect(!state.isCurrent(old))
        #expect(!old.prepare(.init(text: 0, layer: 1, transform: 0)))
        var oldAttempts = 0
        _ = old.withConstructionPermission { oldAttempts += 1 }
        #expect(oldAttempts == 0)
        #expect(!old.acceptsCompletion())
        #expect(fresh.prepare(.init(text: 0, layer: 0, transform: 1)))
        #expect(state.isCurrent(fresh))
        state.retire(fresh)
        #expect(!state.isCurrent(fresh))
        #expect(!fresh.acceptsCompletion())
    }

    @Test("Permit release is idempotent and deinit is a fail-safe")
    func permitLifetimeIsSafe() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let participant = governor.makeParticipant()
        let explicit = try #require(governor.tryAcquireUnreserved(for: participant))
        #expect(governor.tryAcquireUnreserved(for: participant) == nil)

        explicit.release()
        explicit.release()
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif

        var failSafe: WPESceneScriptExecutionGovernor.Permit?
        do {
            let acquired = try #require(
                governor.tryAcquireUnreserved(for: participant)
            )
            failSafe = acquired
        }
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        failSafe = nil
        #expect(failSafe == nil)
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
    }

    @Test("Global governor holds N permits until workers really return")
    func globalGovernorBoundsWorkers() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 2
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.limit-two",
                attributes: .concurrent
            )
        )
        let first = RR10ControlledBlocker()
        let second = RR10ControlledBlocker()
        let third = RR10ControlledBlocker()
        let firstParticipant = governor.makeParticipant()
        let secondParticipant = governor.makeParticipant()
        let thirdParticipant = governor.makeParticipant()
        var firstStarted = false
        var secondStarted = false
        var thirdStarted = false
        defer {
            first.release()
            second.release()
            third.release()
            if firstStarted {
                _ = first.waitUntilFinished()
            }
            if secondStarted {
                _ = second.waitUntilFinished()
            }
            if thirdStarted {
                _ = third.waitUntilFinished()
            }
        }

        firstStarted = harness.trySchedule(
            first.run,
            participant: firstParticipant,
            onFinish: first.markFinished
        )
        secondStarted = harness.trySchedule(
            second.run,
            participant: secondParticipant,
            onFinish: second.markFinished
        )
        #expect(firstStarted)
        #expect(secondStarted)
        try #require(first.waitUntilEntered())
        try #require(second.waitUntilEntered())

        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        let thirdAdmittedWhileFull = harness.trySchedule(
            {},
            participant: thirdParticipant,
            onFinish: {}
        )
        #expect(!thirdAdmittedWhileFull)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 2)

        first.release()
        try #require(first.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif

        thirdStarted = harness.trySchedule(
            third.run,
            participant: thirdParticipant,
            onFinish: third.markFinished
        )
        #expect(thirdStarted)
        try #require(third.waitUntilEntered())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif

        second.release()
        third.release()
        try #require(second.waitUntilFinished())
        try #require(third.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 0,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 3)
        #expect(!first.hitHardDeadline)
        #expect(!second.hitHardDeadline)
        #expect(!third.hitHardDeadline)
    }

    @Test("Blocking deadline removes opportunistic and blocking waiters")
    func mixedAdmissionDeadlineLeavesNoOrphan() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let blocking = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))

        #expect(governor.acquire(for: blocking, until: .now() + 0.01) == nil)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 1,
                peak: 1,
                permitsGranted: 1,
                waitingParticipants: 0
            ))
        #endif

        heldPermit.release()
        let recovered = try #require(governor.tryAcquireUnreserved(for: blocking))
        recovered.release()
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Occupied running permit refuses further admission until the worker returns")
    func occupiedPermitRefusesAdmissionUntilWorkerReturns() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 1
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.scene-timeout",
                attributes: .concurrent
            )
        )
        let blocker = RR10ControlledBlocker()
        let workerParticipant = governor.makeParticipant()
        let rejectedParticipant = governor.makeParticipant()
        var started = false
        defer {
            blocker.release()
            if started {
                _ = blocker.waitUntilFinished()
            }
        }

        started = harness.trySchedule(
            blocker.run,
            participant: workerParticipant,
            onFinish: blocker.markFinished
        )
        #expect(started)
        try #require(blocker.waitUntilEntered())

        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        let rejectedAdmitted = harness.trySchedule(
            {},
            participant: rejectedParticipant,
            onFinish: {}
        )
        #expect(!rejectedAdmitted)

        blocker.release()
        try #require(blocker.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
        #expect(!blocker.hitHardDeadline)
    }

}

private final class RR10PermitWorkerHarness: @unchecked Sendable {
    private let governor: WPESceneScriptExecutionGovernor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = 0

    init(governor: WPESceneScriptExecutionGovernor, queue: DispatchQueue) {
        self.governor = governor
        self.queue = queue
    }

    var workersStarted: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func trySchedule(
        _ work: @escaping @Sendable () -> Void,
        participant: WPESceneScriptExecutionGovernor.Participant,
        onFinish: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let permit = governor.tryAcquireUnreserved(for: participant) else { return false }
        lock.lock()
        started += 1
        lock.unlock()
        queue.async {
            defer {
                permit.release()
                onFinish()
            }
            _ = participant
            work()
        }
        return true
    }
}

private final class RR10ControlledBlocker: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var released = false
    private var didHitHardDeadline = false

    init() {
        completion.enter()
    }

    var hitHardDeadline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didHitHardDeadline
    }

    func run() {
        entered.signal()
        guard releaseSemaphore.wait(timeout: .now() + 2) == .success else {
            lock.lock()
            didHitHardDeadline = true
            lock.unlock()
            return
        }
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }

    func markFinished() {
        completion.leave()
    }

    func waitUntilFinished() -> Bool {
        completion.wait(timeout: .now() + 2) == .success
    }
}

private final class RR10LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func modify(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

@Suite("SceneScript batch queue autorelease drain")
struct WPESceneScriptBatchAutoreleaseTests {

    final class PoolProbe: NSObject {
        nonisolated(unsafe) static var live = 0
        static let lock = NSLock()
        override init() {
            super.init()
            Self.lock.withLock { Self.live += 1 }
        }
        deinit { Self.lock.withLock { Self.live -= 1 } }
    }

    final class LaneReleaseProbe {
        let deinitSignal: DispatchSemaphore

        init(deinitSignal: DispatchSemaphore) {
            self.deinitSignal = deinitSignal
        }

        deinit { deinitSignal.signal() }
    }

    @Test("A busy worker still drains each job's autoreleased objects", .timeLimit(.minutes(1)))
    func busyWorkerDrainsPerJob() async throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let queue = dispatcher.reserveLane().queue
        dispatcher.submit([.init(queue: queue, work: {
            _ = Unmanaged.passRetained(PoolProbe()).autorelease()
        })])
        // Keep the worker continuously busy so its thread never goes idle —
        // the only drain we may rely on is the per-work-item one.
        for _ in 0..<40 {
            dispatcher.submit([.init(queue: queue, work: { usleep(1500) })])
        }
        try await Task.sleep(for: .milliseconds(30))
        let alive = PoolProbe.lock.withLock { PoolProbe.live }
        #expect(alive == 0, "autoreleased job temporaries must drain per work item, got \(alive) alive")
    }

    @Test("A worker lane reuses one JSVirtualMachine; separate workers keep separate ones")
    func laneSharesOneVirtualMachinePerWorker() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let lanes = (0 ..< 4).map { _ in dispatcher.reserveLane() }

        // Round-robin: lanes 0 and 2 are the same worker, 1 and 3 the other.
        #expect(lanes[0].queue === lanes[2].queue)
        #expect(lanes[0].virtualMachine === lanes[2].virtualMachine,
                "one worker must reuse its VM instead of paying a GC heap per engine")
        #expect(lanes[1].virtualMachine === lanes[3].virtualMachine)
        #expect(lanes[0].virtualMachine !== lanes[1].virtualMachine,
                "distinct workers run concurrently — sharing a VM would serialise them")
    }

    @Test("Invalidating a wedged lane replaces only its exact generation")
    func invalidatingLaneRotatesGeneration() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let wedged = dispatcher.reserveLane()

        #expect(wedged.invalidate())
        let replacement = dispatcher.reserveLane()
        #expect(replacement.queue !== wedged.queue)
        #expect(replacement.virtualMachine !== wedged.virtualMachine)
        #expect(!wedged.invalidate(), "a stale timeout must not evict the healthy replacement")

        let sameReplacement = dispatcher.reserveLane()
        #expect(sameReplacement.queue === replacement.queue)
        #expect(sameReplacement.virtualMachine === replacement.virtualMachine)
    }

    @Test("A setup starved behind a blocked lane rotates the lane for the next scene")
    func starvedSetupRecoversOnFreshLaneGeneration() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let blockedLane = dispatcher.reserveLane()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        dispatcher.submit([.init(queue: blockedLane.queue, work: {
            blockerStarted.signal()
            releaseBlocker.wait()
        })])
        #expect(blockerStarted.wait(timeout: .now() + 1) == .success)
        defer { releaseBlocker.signal() }

        let quarantine = WPESceneScriptQuarantine(limit: 4)
        let failedToken = WPESceneScriptInstanceLimitToken(
            generation: 1,
            executionQuarantine: quarantine
        )
        #expect(failedToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        #expect(throws: WPESceneScriptError.executionTimedOut) {
            _ = try WPESceneScriptInstance(
                script: "export function update(value) { return value; }",
                initialValue: "blocked",
                shared: WPESharedScriptState(sceneScriptLoadToken: failedToken),
                setupBudget: 0.02,
                governor: WPESceneScriptExecutionGovernor(limit: 4),
                batchDispatcher: dispatcher
            )
        }

        let recoveredToken = WPESceneScriptInstanceLimitToken(
            generation: 2,
            executionQuarantine: quarantine
        )
        #expect(recoveredToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        let recovered = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-ok'; }",
            initialValue: "fresh",
            shared: WPESharedScriptState(sceneScriptLoadToken: recoveredToken),
            setupBudget: 0.5,
            governor: WPESceneScriptExecutionGovernor(limit: 4),
            batchDispatcher: dispatcher
        )
        #expect(recovered.tickString() == "fresh-ok")
    }

    @Test("Dropping a lane-owned engine never destroys it on a blocked caller lane")
    func laneReleaseHandoffIsNonBlocking() {
        let lane = DispatchQueue(label: "test.wpe-script-lane-release")
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let didDeinitialize = DispatchSemaphore(value: 0)
        lane.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        #expect(blockerStarted.wait(timeout: .now() + 1) == .success)

        var holder: WPESceneScriptLaneRelease<LaneReleaseProbe>? =
            WPESceneScriptLaneRelease(
                value: LaneReleaseProbe(deinitSignal: didDeinitialize),
                queue: lane
            )
        holder = nil
        _ = holder // Keep the explicit lifetime transition visible to the optimizer.
        #expect(didDeinitialize.wait(timeout: .now() + 0.02) == .timedOut)

        releaseBlocker.signal()
        #expect(didDeinitialize.wait(timeout: .now() + 1) == .success)
    }
}

@Suite("SceneScript timer containment", .serialized)
struct WPESceneScriptTimerContainmentTests {
    @Test("More due timers than the per-advance callback limit explicitly fail the scene closed")
    func callbackLimitFailsClosed() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 801)
        #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))
        let shared = WPESharedScriptState(sceneScriptLoadToken: token)
        let instance = try WPESceneScriptInstance(
            script: """
            var callbacks = 0;
            for (var i = 0; i < 1100; i++) {
                engine.setTimeout(function () { callbacks += 1; }, 1000);
            }
            export function update(value) { return String(callbacks); }
            """,
            initialValue: "stable",
            shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 1),
            batchDispatcher: WPESceneScriptBatchDispatcher(width: 1)
        )

        #expect(instance.tickString(runtimeSeconds: 0) == "0")
        #expect(instance.tickString(runtimeSeconds: 2) == "0")
        #expect(token.failureReason == .timerCallbackLimitExceeded(
            limit: 1_024
        ))
    }

    @Test("A retired load generation never executes or publishes its pending timer")
    func retiredGenerationDoesNotFireTimer() throws {
        let loadState = WPESceneScriptLoadState()
        let oldToken = loadState.begin(generation: 901)
        #expect(oldToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        let shared = WPESharedScriptState(sceneScriptLoadToken: oldToken)
        let old = try WPESceneScriptInstance(
            script: """
            engine.setTimeout(function () { shared.staleTimerPublished = true; }, 10);
            export function update(value) { return 'old'; }
            """,
            initialValue: "stable",
            shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 1),
            batchDispatcher: WPESceneScriptBatchDispatcher(width: 1)
        )

        let freshToken = loadState.begin(generation: 902)
        #expect(freshToken.prepare(.init(text: 0, layer: 0, transform: 0)))
        #expect(old.tickString(runtimeSeconds: 1) == "stable")
        #expect(shared.get("staleTimerPublished") == nil)
        #expect(oldToken.isRetired)
        #expect(freshToken.failureReason == nil)
    }
}

#if !LITE_BUILD
import LiveWallpaperCore
import LiveWallpaperProWPE

extension WPESceneScriptContainmentCharacterizationTests {
    private static func lightHostScene(lightOrigin: [String: Any]) -> [String: Any] {
        [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [
                ["id": 7, "name": "Lamp", "light": "lpoint", "color": "1 1 1", "origin": lightOrigin],
                [
                    "id": 8,
                    "name": "Child",
                    "type": "image",
                    "image": "models/util/solidlayer.json",
                    "parent": 7,
                    "color": "0 0 1",
                    "alpha": 1,
                    "visible": true,
                ],
            ],
        ]
    }

    @MainActor
    @Test("A keyframed light that parents a layer keeps its origin animation and frame demand")
    func animatedLightHostKeepsOriginAnimation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = try JSONSerialization.data(withJSONObject: Self.lightHostScene(lightOrigin: [
            "value": "0 0 0",
            "animation": [
                "c0": [["frame": 0, "value": 0], ["frame": 30, "value": 32]],
                "c1": [["frame": 0, "value": 0], ["frame": 30, "value": 16]],
                "c2": [["frame": 0, "value": 0], ["frame": 30, "value": 0]],
                "options": ["fps": 30, "length": 30, "mode": "loop", "wraploop": true],
            ],
        ]), options: [.sortedKeys])
        try scene.write(to: root.appendingPathComponent("scene.json"))
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": "light-host-fixture",
            "type": "scene",
            "file": "scene.json",
        ], options: [.sortedKeys])
        try project.write(to: root.appendingPathComponent("project.json"))
        let fixture = FrameDemandFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: "light-host-fixture",
                cacheRelativePath: "wpe-cache/light-host-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        #expect(renderer.dynamicOriginAnimations["7"] != nil, "the light's keyframes must move its children")
        #expect(renderer.frameDemand.contains(.animations))
    }

    @Test("A light's script-resolved origin survives the ancestor-transform merge")
    func lightAncestorKeepsScriptResolvedOrigin() throws {
        let data = try JSONSerialization.data(withJSONObject: Self.lightHostScene(lightOrigin: [
            "value": "1 2 0",
            "script": "export function update(value) { value.x = 40; value.y = 50; return value; }",
        ]))
        let document = try WPESceneDocumentParser.parse(data: data)
        let host = try #require(document.transformHostObjects.first { $0.id == "7" })
        let light = try #require(document.lightObjects.first { $0.id == "7" })
        #expect(host.localOrigin == SIMD3<Double>(40, 50, 0))
        #expect(light.localOrigin != host.localOrigin, "fixture must keep the light's baked origin distinct")

        let transforms = WPEMetalSceneRenderer.ancestorLocalTransforms(in: document)
        #expect(transforms["7"]?.origin == host.localOrigin)
    }
}
#endif
