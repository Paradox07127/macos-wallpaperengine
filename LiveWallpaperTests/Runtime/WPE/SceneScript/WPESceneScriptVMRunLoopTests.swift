#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// A hang here parks the main thread inside `JSLock::lock` for good: run with a wall-clock kill.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPESceneScriptLaneRunLoopTests {
    @Test("A quarantined looping init never parks the main thread that reserved its lane")
    func mainThreadReservationSurvivesLoopingInit() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 4)
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let token = WPESceneScriptInstanceLimitToken(generation: 9060, executionQuarantine: WPESceneScriptQuarantine(limit: 2))
        #expect(token.prepare(.init(text: 0, layer: 0, transform: 1)))
        let store = WPESharedScriptState(sceneScriptLoadToken: token)
        // Reserved here on main, as the `.main` display render actor backing does.
        let instance = try WPEDynamicTransformScriptInstance(script: """
                                                             let garbage = [];
                                                             export function init() { while(true) { garbage = [{}, {}, new Array(64)]; } }
                                                             """, seed: .zero, canvasSize: SIMD2(64, 64), shared: store, setupBudget: 0.2,
                                                             governor: governor, batchDispatcher: dispatcher, initializationMode: .deferred)
        #expect(throws: WPESceneScriptError.executionTimedOut) { try instance.initializePreparedScript() }
        let pumpStarted = Date()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        #expect(Date().timeIntervalSince(pumpStarted) < 10)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPETransformEvaluatorRunLoopTests {
    @Test("A quarantined runaway static transform never parks the main thread that built the evaluator")
    func mainThreadEvaluatorSurvivesRunawayScript() {
        let evaluator = WPETransformScriptEvaluator(
            canvasWidth: 64, canvasHeight: 64, evaluationBudget: 0.2,
            governor: WPESceneScriptExecutionGovernor(limit: 4)
        )
        // Exponential recursion: no loop keyword, so it passes the static-resolvability filter.
        let script = """
        function spin(n) { const a = [{}, {}]; return n <= 0 ? a.length : spin(n - 1) + spin(n - 1); }
        export function update(value) { spin(64); return value; }
        """
        #expect(WPETransformScriptEvaluator.isStaticallyResolvable(script))
        let evaluationStarted = Date()
        #expect(evaluator.resolveVec3(script: script, properties: [:], seed: .zero) == nil)
        #expect(Date().timeIntervalSince(evaluationStarted) >= 0.2, "the script never ran, so nothing was quarantined")
        let pumpStarted = Date()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        #expect(Date().timeIntervalSince(pumpStarted) < 10)
    }
}
#endif
