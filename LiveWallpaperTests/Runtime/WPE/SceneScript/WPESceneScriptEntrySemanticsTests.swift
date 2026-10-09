import Foundation
@testable import LiveWallpaper
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WPESceneScriptEntrySemanticsTests {
    private let governor = WPESceneScriptExecutionGovernor(limit: 4)
    private static let pointer = SIMD2<Double>(0.5, 0.5)

    /// Runs the job on its own engine lane and waits for it to finish.
    private static func run(_ job: WPESceneScriptBatchDispatcher.Job?) -> Bool {
        guard let job else { return false }
        return WPESceneScriptBatchDispatcher.processShared
            .submit([job], trackingCompletion: true)?
            .wait(timeout: .now() + 5) == true
    }

    private static func number(_ shared: WPESharedScriptState, _ key: String) -> Double? {
        shared.get(key) as? Double
    }

    // MARK: X3-01

    @Test("X3-01: a timer a handler registers in a module without update() still gets a frame job")
    func handlerTimerWithoutUpdateGetsFrameJob() throws {
        let layer = try WPELayerScriptInstance(
            script: """
            export function cursorClick() {
                thisLayer.visible = true;
                engine.setTimeout(function () { thisLayer.visible = false; }, 2000);
            }
            """,
            setupBudget: 2,
            tickBudget: 0.5,
            initialVisible: false,
            governor: governor
        )
        let clicked = layer.dispatchCursorEvent(.click, pointerFrame: .neutral, runtimeSeconds: 1)
        #expect(clicked?.own.visible == true)
        let (_, job) = layer.batchTick(runtimeSeconds: 3.5)
        #expect(Self.run(job), "a pending timer would otherwise wait for an unrelated event to fire")
        #expect(layer.takeCompletedBatchOutput()?.own.visible == false)
    }

    @Test("X3-01: once init's only timer has fired, a module without update() stops getting frame jobs")
    func drainedInitTimerStopsFrameJobs() throws {
        let shared = WPESharedScriptState()
        let layer = try WPELayerScriptInstance(
            script: """
            export function init() { engine.setTimeout(function () { shared.fired = 1; }, 0); }
            """,
            shared: shared,
            setupBudget: 2,
            tickBudget: 0.5,
            governor: governor
        )
        let (_, first) = layer.batchTick(runtimeSeconds: 1)
        #expect(Self.run(first))
        #expect(Self.number(shared, "fired") == 1)
        _ = layer.takeCompletedBatchOutput()
        let (_, second) = layer.batchTick(runtimeSeconds: 2)
        #expect(second == nil, "an empty job every frame would mean the timer flag never cleared")
    }

    // MARK: X3-02

    @Test("X3-02: a timer-only frame of a transform without update() keeps init's value")
    func timerOnlyFrameKeepsInitValue() throws {
        let transform = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(v) {
                engine.setTimeout(function () {}, 5000);
                return new Vec3(v.x + 100, v.y, v.z);
            }
            """,
            seed: SIMD3(1, 2, 3),
            canvasSize: SIMD2(1920, 1080),
            setupBudget: 2,
            tickBudget: 0.5,
            governor: governor
        )
        let first = transform.batchTick(pointerPosition: Self.pointer, runtimeSeconds: 1)
        #expect(first.value == SIMD3(101, 2, 3))
        #expect(Self.run(first.job))
        let second = transform.batchTick(pointerPosition: Self.pointer, runtimeSeconds: 2)
        #expect(second.value == SIMD3(101, 2, 3), "nil here snaps the layer back to its baked transform")
    }

    // MARK: X3-04

    private static let frametimeScript = """
    export function mediaTimelineChanged(event) { shared.eventFrametime = engine.frametime; }
    export function update(value) { shared.frametime = engine.frametime; return value; }
    """
    private static let timeline = WPESceneMediaEvent.timelineChanged(WPESceneMediaTimeline(position: 1, duration: 8))

    @Test("X3-04: a text media event between frames neither sees nor eats the frame's frametime")
    func textEventKeepsFrameTime() throws {
        let shared = WPESharedScriptState()
        let text = try WPESceneScriptInstance(
            script: Self.frametimeScript, initialValue: "v", shared: shared, governor: governor
        )
        _ = text.tickString(runtimeSeconds: 1)
        _ = text.tickString(runtimeSeconds: 1.25)
        text.dispatchMediaEvent(Self.timeline, runtimeSeconds: 1.375)
        #expect(Self.number(shared, "eventFrametime") == 0.25)
        _ = text.tickString(runtimeSeconds: 1.5)
        #expect(Self.number(shared, "frametime") == 0.25)
    }

    @Test("X3-04: a layer media event between frames neither sees nor eats the frame's frametime")
    func layerEventKeepsFrameTime() throws {
        let shared = WPESharedScriptState()
        let layer = try WPELayerScriptInstance(
            script: Self.frametimeScript, shared: shared, setupBudget: 2, tickBudget: 0.5, governor: governor
        )
        _ = layer.tick(runtimeSeconds: 1)
        _ = layer.tick(runtimeSeconds: 1.25)
        #expect(Self.run(layer.batchMediaEvents([Self.timeline], runtimeSeconds: 1.375)))
        #expect(Self.number(shared, "eventFrametime") == 0.25)
        _ = layer.tick(runtimeSeconds: 1.5)
        #expect(Self.number(shared, "frametime") == 0.25)
    }

    @Test("X3-04: a transform media event between frames neither sees nor eats the frame's frametime")
    func transformEventKeepsFrameTime() async throws {
        let shared = WPESharedScriptState()
        let soloGovernor = WPESceneScriptExecutionGovernor(limit: 1)
        let transform = try WPEDynamicTransformScriptInstance(
            script: Self.frametimeScript, seed: .zero, canvasSize: SIMD2(1920, 1080), shared: shared,
            setupBudget: 2, tickBudget: 0.5, governor: soloGovernor
        )
        _ = transform.tick(pointerPosition: Self.pointer, runtimeSeconds: 1)
        _ = transform.tick(pointerPosition: Self.pointer, runtimeSeconds: 1.25)
        transform.liveDispatchMediaEvents([Self.timeline], runtimeSeconds: 1.375)
        // The async batch holds the only permit until it finishes; a probe acquiring it proves the event ran.
        let probe = soloGovernor.makeParticipant()
        var idle = false
        for _ in 0 ..< 1000 where !idle {
            if let permit = soloGovernor.tryAcquireUnreserved(for: probe) {
                permit.release()
                idle = true
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(idle)
        #expect(Self.number(shared, "eventFrametime") == 0.25)
        _ = transform.tick(pointerPosition: Self.pointer, runtimeSeconds: 1.5)
        #expect(Self.number(shared, "frametime") == 0.25)
    }

    // MARK: X3-05 / X3-06

    private static let dxProperty = """
    export var scriptProperties = createScriptProperties()
        .addSlider({name: 'dx', value: 0, min: -100, max: 100})
        .finish();
    """

    @Test("X3-05: the static origin evaluator hands update() a native Vec3")
    func staticEvaluatorPassesVec3() {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1920, canvasHeight: 1080, governor: governor)
        let value = evaluator.resolveVec3(
            script: Self.dxProperty + """
            export function update(value) { return value.add(new Vec3(scriptProperties.dx, 0, 0)); }
            """,
            properties: ["dx": .number(5)],
            seed: SIMD3(10, 20, 30)
        )
        #expect(value == SIMD3(15, 20, 30))
    }

    @Test("X3-06: the static origin evaluator runs init() before update()")
    func staticEvaluatorRunsInit() {
        let evaluator = WPETransformScriptEvaluator(canvasWidth: 1920, canvasHeight: 1080, governor: governor)
        let value = evaluator.resolveVec3(
            script: Self.dxProperty + """
            let base;
            export function init(v) { base = v; return v; }
            export function update(v) { v.x = base.x + scriptProperties.dx; return v; }
            """,
            properties: ["dx": .number(5)],
            seed: SIMD3(10, 20, 30)
        )
        #expect(value == SIMD3(15, 20, 30))
    }

    // MARK: X3-17

    @Test("X3-17: a quarantined transform update() leaves cursor handlers and destroy() running")
    func quarantinedUpdateKeepsOtherEntryPoints() async throws {
        let shared = WPESharedScriptState()
        let transform = try WPEDynamicTransformScriptInstance(
            script: """
            export function update(value) { shared.u = (shared.u || 0) + 1; throw 1; }
            export function cursorClick() { shared.c = (shared.c || 0) + 1; }
            export function destroy() { shared.d = 1; }
            """,
            seed: .zero,
            canvasSize: SIMD2(1920, 1080),
            shared: shared,
            setupBudget: 2,
            tickBudget: 0.5,
            governor: governor
        )
        // Probes are spaced by the real monotonic clock, so reaching quarantine takes ~probeLimit seconds.
        let attempts = WPEScriptFaultPolicy.backoffFrames.count + WPEScriptFaultPolicy.quarantineProbeLimit
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(40)
        var runtime = 0.0
        while Int(Self.number(shared, "u") ?? 0) < attempts, clock.now < deadline {
            runtime += 1.0 / 30.0
            _ = transform.tick(pointerPosition: Self.pointer, runtimeSeconds: runtime)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Int(Self.number(shared, "u") ?? 0) == attempts)

        let click = WPELayerScriptCursorInvocation(event: .click, pointerFrame: .neutral, runtimeSeconds: runtime)
        #expect(Self.run(transform.enqueueCursorEvents([click])), "quarantining update() must not reject clicks")
        #expect(Self.number(shared, "c") == 1)
        #expect(transform.destroy())
        #expect(Self.number(shared, "d") == 1)
    }

    // MARK: U04-02

    @Test("U04-02: a live-value snapshot refresh copies only the registered read-fan keys")
    func liveSnapshotRefreshFollowsReadFanKeys() throws {
        let shared = WPESharedScriptState()
        let layer = try WPELayerScriptInstance(
            script: """
            var fanned = new Vec3(1, 2, 3);
            var unread = new Vec3(0, 0, 0);
            export function init(value) { shared.fanned = fanned; shared.unread = unread; return value; }
            export function update() { fanned.x += 1; unread.x += 1; }
            """,
            shared: shared, setupBudget: 2, tickBudget: 0.5, governor: governor
        )
        _ = layer.tick(runtimeSeconds: 1)
        #expect(shared.liveSnapshotCount == 0, "with no read fan registered no live value may be snapshotted")

        shared.setReadFanKeys(["fanned"])
        _ = layer.tick(runtimeSeconds: 2)
        #expect(shared.liveSnapshotCount == 1, "only the registered key is snapshotted")
        #expect((shared.get("fanned") as? [String: Any])?["x"] as? Double == 3)
    }

    // MARK: X3-14

    @Test("X3-14: getTransformMatrix composes the parent chain, live values and this entry's assignment")
    func transformMatrixComposesParentChain() throws {
        let shared = WPESharedScriptState(layers: [
            WPESceneScriptLayerInfo(
                id: "1", name: "Root", size: SIMD2(100, 100), origin: SIMD2(100, 50),
                angles: SIMD3(0, 0, .pi / 2), index: 0, parentName: nil
            ),
            WPESceneScriptLayerInfo(
                id: "2", name: "Child", size: SIMD2(10, 10), origin: SIMD2(10, 0),
                scale: SIMD3(2, 3, 1), index: 1, parentName: "Root", parentID: "1"
            ),
        ])
        shared.publishLayerTransforms(origins: ["1": SIMD3(200, 50, 0)], scales: [:], angles: [:])
        let layer = try WPELayerScriptInstance(
            script: """
            function fmt(m) {
                return [m[0], m[1], m[4], m[5], m[12], m[13]]
                    .map(function (v) { return Math.round(v * 1000) / 1000; }).join(',');
            }
            export function update() {
                shared.before = fmt(thisLayer.getTransformMatrix().m);
                thisLayer.origin = new Vec3(20, 0, 0);
                shared.after = fmt(thisLayer.getTransformMatrix().m);
            }
            """,
            shared: shared, setupBudget: 2, tickBudget: 0.5,
            ownLayerName: "Child", ownObjectID: "2", governor: governor
        )
        _ = layer.tick(runtimeSeconds: 1)
        // World = T(live root) · Rz(90°) · T(child) · S(2, 3, 1).
        #expect(shared.get("before") as? String == "0,2,-3,0,200,60")
        #expect(shared.get("after") as? String == "0,2,-3,0,200,70")
    }
}
