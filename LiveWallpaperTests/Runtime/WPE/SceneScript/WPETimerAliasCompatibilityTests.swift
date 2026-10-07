#if !LITE_BUILD
import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Existing timer alias surface characterization", .serialized)
struct WPETimerAliasCharacterizationTests {
    @Test("Host exposes engine timers without a bare timeout in all runtime families", arguments: ["text", "layer", "transform"])
    func currentHostSurface(family: String) throws {
        #expect(try TimerAliasFixture.surface(family: family) == "function|function|undefined")
    }

    @Test("An authored timer alias remains legitimate and is not rewritten")
    func authoredAliasSurvives() throws {
        let instance = try WPESceneScriptInstance(script: """
        function setTimeout(callback, delay) { return engine.setTimeout(callback, delay); }
        var fires = 0;
        setTimeout(function () { fires += 1; }, 10);
        export function update() { return String(fires); }
        """, initialValue: "seed", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(instance.tickString(runtimeSeconds: 0) == "0")
        #expect(instance.tickString(runtimeSeconds: 0.01) == "1")
    }
}

@MainActor
@Suite("Desired native bare timeout boundary", .serialized)
struct WPENativeTimerSurfaceTests {
    @Test("The nil-scheduler sandbox and baseclasses do not restore a bare timeout stub")
    func staticSandboxKeepsBareTimeoutAbsent() throws {
        let context = try #require(JSContext())
        WPESceneScriptInstance.installSandbox(in: context)
        WPESceneScriptBaseclasses.install(in: context)
        let surface = context.evaluateScript("""
        [typeof engine.setTimeout, typeof engine.setInterval, typeof setTimeout,
         typeof setInterval, typeof clearTimeout, typeof clearInterval].join('|')
        """)?.toString()
        #expect(surface == "function|function|undefined|function|function|function")
    }

    @Test("An unsupported bare call cannot continue init or schedule work, while update still runs")
    func failedBareInitDoesNotContinueButUpdateRuns() throws {
        let shared = WPESharedScriptState()
        let instance = try WPEDynamicTransformScriptInstance(script: """
                                                             export function init(value) {
                                                                 setTimeout(function () { shared.timerFired = true; }, 10);
                                                                 shared.afterBareCall = true;
                                                                 return value;
                                                             }
                                                             export function update(value) {
                                                                 shared.updates = Number(shared.updates || 0) + 1;
                                                                 return value;
                                                             }
                                                             """, seed: SIMD3(1, 2, 3), canvasSize: SIMD2(64, 64), shared: shared,
                                                             governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("afterBareCall") == nil)
        _ = instance.tick(pointerPosition: .zero, runtimeSeconds: 0)
        _ = instance.tick(pointerPosition: .zero, runtimeSeconds: 0.02)
        #expect(shared.get("updates") as? Double == 2)
        #expect(shared.get("afterBareCall") == nil)
        #expect(shared.get("timerFired") == nil)
    }
}

@MainActor
private enum TimerAliasFixture {
    static func surface(family: String) throws -> String? {
        let shared = WPESharedScriptState()
        let source = """
        export function init(value) {
            shared.timerSurface = [typeof engine.setTimeout, typeof engine.setInterval, typeof setTimeout].join('|');
            return value;
        }
        """
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        switch family {
        case "text":
            let instance = try WPESceneScriptInstance(script: source, initialValue: "seed", shared: shared, governor: governor)
            return withExtendedLifetime(instance) { shared.get("timerSurface") as? String }
        case "layer":
            let instance = try WPELayerScriptInstance(script: source, shared: shared, governor: governor)
            return withExtendedLifetime(instance) { shared.get("timerSurface") as? String }
        default:
            let instance = try WPEDynamicTransformScriptInstance(script: source, seed: .zero, canvasSize: SIMD2(64, 64),
                                                                 shared: shared, governor: governor)
            return withExtendedLifetime(instance) { shared.get("timerSurface") as? String }
        }
    }
}
#endif
