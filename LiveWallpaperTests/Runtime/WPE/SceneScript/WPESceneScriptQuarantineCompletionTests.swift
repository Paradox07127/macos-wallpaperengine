#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

struct WPESceneScriptQuarantineCompletionTests {
    private final class EngineProbe: @unchecked Sendable {
        let onDeinit: @Sendable () -> Void
        init(onDeinit: @escaping @Sendable () -> Void = {}) {
            self.onDeinit = onDeinit
        }

        deinit { onDeinit() }
    }

    private func token(
        _ generation: Int, quarantine: WPESceneScriptQuarantine
    ) -> WPESceneScriptInstanceLimitToken {
        let token = WPESceneScriptInstanceLimitToken(
            generation: generation, executionQuarantine: quarantine
        )
        #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))
        return token
    }

    @Test("Late worker completion releases its engine on the lane without reviving the failed scene")
    func lateCompletionReclaimsOwnership() throws {
        let quarantine = WPESceneScriptQuarantine(limit: 1)
        let failedToken = token(1, quarantine: quarantine)
        let safety = try #require(WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: failedToken))
        let lane = DispatchQueue(label: "test.quarantine-completion")
        let deinitialized = DispatchSemaphore(value: 0)
        var engine: EngineProbe? = EngineProbe {
            dispatchPrecondition(condition: .onQueue(lane))
            deinitialized.signal()
        }
        #expect(try safety.quarantine(#require(engine), operation: .setup))
        engine = nil
        #expect(quarantine.snapshot.quarantinedEngines == 1)
        #expect(!quarantine.canConstructRuntime)
        #expect(deinitialized.wait(timeout: .now()) == .timedOut)

        lane.sync { safety.complete() }
        #expect(deinitialized.wait(timeout: .now() + 1) == .success)
        #expect(quarantine.snapshot.activeReservations == 0)
        #expect(quarantine.snapshot.quarantinedEngines == 0)
        #expect(quarantine.canConstructRuntime)
        #expect(failedToken.failureReason == .executionTimedOut(operation: .setup))
        #expect(!failedToken.acceptsCompletion())
        let nextToken = token(2, quarantine: quarantine)
        let next = try #require(WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: nextToken))
        next.complete()
        safety.complete()
        #expect(quarantine.snapshot.quarantinedEngines == 0)
        #expect(nextToken.acceptsCompletion())
    }

    @Test("Dropping a timed-out reservation cannot release an engine still executing")
    func droppingReservationDoesNotConfirmCompletion() throws {
        let quarantine = WPESceneScriptQuarantine(limit: 1)
        let failedToken = token(1, quarantine: quarantine)
        var safety: WPESceneScriptExecutionSafetyReservation? = try #require(
            WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: failedToken)
        )
        var engine: EngineProbe? = EngineProbe()
        weak var weakEngine = engine
        #expect(try safety?.quarantine(#require(engine), operation: .tick) == true)
        engine = nil
        safety = nil
        #expect(weakEngine != nil)
        #expect(quarantine.snapshot.quarantinedEngines == 1)
        #expect(quarantine.reserve() == nil)
    }

    @Test("A late watchdog cannot quarantine a completed evaluation")
    func completedEvaluationRejectsWatchdog() throws {
        let quarantine = WPESceneScriptQuarantine(limit: 1)
        let sceneToken = token(1, quarantine: quarantine)
        let safety = try #require(WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: sceneToken))
        safety.complete()
        #expect(!safety.quarantine(EngineProbe(), operation: .tick))
        #expect(quarantine.snapshot.activeReservations == 0)
        #expect(quarantine.snapshot.quarantinedEngines == 0)
        #expect(sceneToken.failureReason == nil)
    }

    @Test("Async completion reclaims a watchdog-retired slot without reopening its scene")
    func asyncCompletionAfterWatchdog() throws {
        let quarantine = WPESceneScriptQuarantine(limit: 1)
        let sceneToken = token(1, quarantine: quarantine)
        let execution = WPESceneScriptAsyncExecutionSafety()
        let safety = try #require(execution.begin(sceneToken: sceneToken, operation: .tick))
        #expect(execution.quarantineIfOverdue(budget: 0, engine: EngineProbe()) != nil)
        #expect(quarantine.snapshot.quarantinedEngines == 1)
        let lane = DispatchQueue(label: "test.async-quarantine-completion")
        lane.sync { execution.complete(safety) }
        #expect(quarantine.snapshot.quarantinedEngines == 0)
        #expect(sceneToken.failureReason == .executionTimedOut(operation: .tick))
        #expect(!sceneToken.acceptsCompletion())
    }

    @Test("Concurrent completion and watchdog never strand or double-release a reservation")
    func completionRacesWatchdog() throws {
        let quarantine = WPESceneScriptQuarantine(limit: 1)
        for generation in 0 ..< 100 {
            let sceneToken = token(generation, quarantine: quarantine)
            let safety = try #require(WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: sceneToken))
            let finished = DispatchGroup()
            DispatchQueue.global().async(group: finished) { safety.complete() }
            DispatchQueue.global().async(group: finished) {
                _ = safety.quarantine(EngineProbe(), operation: .tick)
            }
            try #require(finished.wait(timeout: .now() + 1) == .success)
            #expect(quarantine.snapshot.activeReservations == 0)
            #expect(quarantine.snapshot.quarantinedEngines == 0)
        }
    }
}
#endif
