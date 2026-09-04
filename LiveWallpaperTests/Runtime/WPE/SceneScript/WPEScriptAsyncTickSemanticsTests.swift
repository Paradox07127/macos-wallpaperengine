import Foundation
import Testing
@testable import LiveWallpaper


/// Drives the batch tick path the way `renderCurrentFrame` does: take the newest
/// completed value, then hand this frame's work to the workers. Tests must not run
/// a job inline — it has to execute on the engine's own worker queue.
enum WPEBatchTickDriver {
    static func tick(_ instance: WPESceneScriptInstance) -> String {
        let (value, job) = instance.batchTickString()
        submit(job)
        return value
    }

    static func tick(
        _ instance: WPELayerScriptInstance,
        runtimeSeconds: Double? = nil,
        pointerFrame: WPEPointerFrame? = nil
    ) -> WPELayerScriptOutput? {
        let (output, job) = instance.batchTick(
            runtimeSeconds: runtimeSeconds,
            pointerFrame: pointerFrame
        )
        submit(job)
        return output
    }

    static func tick(
        _ instance: WPEDynamicTransformScriptInstance,
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> SIMD3<Double>? {
        let (value, job) = instance.batchTick(
            pointerPosition: pointerPosition,
            runtimeSeconds: runtimeSeconds
        )
        submit(job)
        return value
    }

    private static func submit(_ job: WPESceneScriptBatchDispatcher.Job?) {
        guard let job else { return }
        WPESceneScriptBatchDispatcher.processShared.submit([job])
    }
}

@MainActor
struct WPEScriptAsyncTickSemanticsTests {

    // MARK: - Instrumentation

    private static let counterPreamble = "shared.n = (shared.n || 0) + 1;"

    private static func updateCount(_ shared: WPESharedScriptState) -> Int {
        Int((shared.get("n") as? Double) ?? 0)
    }

    private static func busyLoop(millis: Int) -> String {
        "var __t0 = Date.now(); while (Date.now() - __t0 < \(millis)) {}"
    }

    private static func waitForUpdateCount(
        _ shared: WPESharedScriptState,
        atLeast target: Int,
        timeout: Duration = .seconds(10)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if updateCount(shared) >= target { return true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func quiesce(_ shared: WPESharedScriptState) async throws -> Int {
        var last = updateCount(shared)
        while true {
            try await Task.sleep(for: .milliseconds(120))
            let now = updateCount(shared)
            if now == last { return now }
            last = now
        }
    }

    // MARK: - Lockstep: does async drop a tick even when it keeps up?

    @Test("Lockstep text script: async applies exactly one update() per frame, same values as legacy")
    func textLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            return String(Number(value) + 1);
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: legacyShared
        )
        var legacyValues: [String] = []
        for _ in 1...frames { legacyValues.append(legacy.tickString()) }
        #expect(legacyValues == (1...frames).map(String.init))
        #expect(Self.updateCount(legacyShared) == frames)

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared
        )
        asyncInstance.seedAsyncTick()

        var asyncValues: [String] = []
        for frame in 1...frames {
            asyncValues.append(WPEBatchTickDriver.tick(asyncInstance))
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncValues == legacyValues)
        #expect(asyncValues.last == String(frames))
    }

    @Test("Lockstep transform script: async accumulates once per frame, same values as legacy")
    func transformLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let pointer = SIMD2<Double>(0.5, 0.5)
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            value.y = value.y + 1;
            return value;
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 100),
            shared: legacyShared
        )
        var legacyY: [Double] = []
        for _ in 1...frames { legacyY.append(try #require(legacy.tick(pointerPosition: pointer)).y) }
        #expect(legacyY == (1...frames).map(Double.init))

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 100),
            shared: asyncShared
        )
        asyncInstance.seedAsyncTick(pointerPosition: pointer)

        var asyncY: [Double] = []
        for frame in 1...frames {
            asyncY.append(try #require(WPEBatchTickDriver.tick(asyncInstance, pointerPosition: pointer)).y)
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncY == legacyY)
        #expect(asyncY.last == Double(frames))
    }

    @Test("Lockstep layer script: async accumulates once per frame, same values as legacy")
    func layerLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            return value + 1;
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPELayerScriptInstance(
            script: script,
            shared: legacyShared,
            outputMode: .returnedAlpha(initialValue: 0)
        )
        var legacyAlpha: [Double] = []
        for _ in 1...frames { legacyAlpha.append(try #require(legacy.tick(runtimeSeconds: 1)?.own.alpha)) }
        #expect(legacyAlpha == (1...frames).map(Double.init))

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPELayerScriptInstance(
            script: script,
            shared: asyncShared,
            outputMode: .returnedAlpha(initialValue: 0)
        )
        var applied = try #require(asyncInstance.tick(runtimeSeconds: 1)?.own.alpha)

        var asyncAlpha: [Double] = []
        for frame in 1...frames {
            if let fresh = WPEBatchTickDriver.tick(asyncInstance, runtimeSeconds: 1)?.own.alpha { applied = fresh }
            asyncAlpha.append(applied)
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncAlpha == legacyAlpha)
        #expect(asyncAlpha.last == Double(frames))
    }

    // MARK: - Contention: the frame path outruns the engine

    @Test("Frames outrunning the engine: async swallows ticks, legacy does not")
    func asyncSwallowsTicksWhenFramesOutrunEngine() async throws {
        let frames = 40
        let busyMillis = 20
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            \(Self.busyLoop(millis: busyMillis))
            return String(Number(value) + 1);
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: legacyShared,
            tickBudget: 5
        )
        for _ in 1...frames { _ = legacy.tickString() }
        #expect(Self.updateCount(legacyShared) == frames)
        #expect(legacy.lastValue == String(frames))

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared,
            tickBudget: 5
        )
        for _ in 1...frames { _ = WPEBatchTickDriver.tick(asyncInstance) }
        let asyncUpdates = try await Self.quiesce(asyncShared)

        #expect(asyncUpdates < frames)
        #expect(asyncUpdates <= 5, "expected near-total tick loss in a tight burst, got \(asyncUpdates)/\(frames)")
    }

    @Test("60fps cadence with a 30ms tick: async loses roughly half its update() calls")
    func asyncLossRateAtSixtyFpsWithSlowTick() async throws {
        let frames = 30
        let busyMillis = 30
        let frameInterval = Duration.microseconds(16_667)
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            \(Self.busyLoop(millis: busyMillis))
            return String(Number(value) + 1);
        }
        """

        let shared = WPESharedScriptState()
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: shared,
            tickBudget: 5
        )

        let clock = ContinuousClock()
        var deadline = clock.now
        for _ in 1...frames {
            _ = WPEBatchTickDriver.tick(instance)
            deadline += frameInterval
            try await Task.sleep(until: deadline, clock: clock)
        }
        let updates = try await Self.quiesce(shared)

        #expect(updates < frames)
        #expect(updates <= (frames * 3) / 4, "expected substantial tick loss, got \(updates)/\(frames)")
        #expect(updates >= 2, "sanity: the engine must have ticked at all, got \(updates)")
    }

    @Test("Batch dispatch: every script ticks every frame", arguments: [100, 200])
    func batchTickKeepsEveryScriptAtFrameRate(scriptCount: Int) async throws {
        let seconds = 2
        let traversalsPerSecond = 60
        let traversals = seconds * traversalsPerSecond
        let interval = Duration.nanoseconds(1_000_000_000 / traversalsPerSecond)
        let script = """
        export function update(value) {
            return String(Number(value) + 1);
        }
        """

        let dispatcher = WPESceneScriptBatchDispatcher(
            width: WPESceneScriptContainmentDefaults.batchWorkerWidth
        )
        var instances: [WPESceneScriptInstance] = []
        for _ in 0 ..< scriptCount {
            instances.append(try WPESceneScriptInstance(
                script: script,
                initialValue: "0",
                shared: WPESharedScriptState(),
                batchDispatcher: dispatcher
            ))
        }

        let clock = ContinuousClock()
        var deadline = clock.now
        var submitNanos: Int64 = 0
        var dispatches = 0
        for _ in 1 ... traversals {
            let started = DispatchTime.now().uptimeNanoseconds
            var jobs: [WPESceneScriptBatchDispatcher.Job] = []
            jobs.reserveCapacity(instances.count)
            for instance in instances {
                if let job = instance.batchTickString().job { jobs.append(job) }
            }
            dispatcher.submit(jobs)
            dispatches += min(jobs.count, dispatcher.width)
            submitNanos += Int64(DispatchTime.now().uptimeNanoseconds - started)
            deadline += interval
            try await Task.sleep(until: deadline, clock: clock)
        }
        try await Task.sleep(for: .milliseconds(200))

        // The returned string IS the counter: how many update() calls landed.
        let applied = instances.compactMap { Int($0.lastValue) }
        let total = applied.reduce(0, +)
        let perScriptPerSecond = Double(total) / Double(scriptCount) / Double(seconds)
        print("""
        [batch] scripts=\(scriptCount) \
        perScriptTicksPerSecond=\(perScriptPerSecond) \
        dispatchesPerSecond=\(Double(dispatches) / Double(seconds)) \
        submitMsPerFrame=\(Double(submitNanos) / Double(traversals) / 1_000_000) \
        slowestScriptTicks=\(applied.min() ?? -1) fastest=\(applied.max() ?? -1)
        """)

        #expect(perScriptPerSecond > 55)
        #expect(Double(dispatches) / Double(seconds) <= Double(dispatcher.width * traversalsPerSecond))
    }

    @Test("Cost of one update(): sync round trip vs the frame budget")
    func costOfOneUpdate() async throws {
        let script = """
        export function update(value) {
            return String(Number(value) + 1);
        }
        """
        let governor = WPESceneScriptExecutionGovernor(limit: 1024)
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: WPESharedScriptState(),
            governor: governor
        )
        // Warm the queue and the JIT before timing.
        for _ in 1 ... 200 { _ = instance.tickString() }
        let calls = 2000
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 1 ... calls { _ = instance.tickString() }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - started) / Double(calls) / 1000
        print("""
        [cost] syncRoundTripUs=\(micros) \
        hundredScriptsMs=\(micros * 100 / 1000) \
        frameBudgetMs=16.667
        """)
        #expect(micros > 0)
    }

    /// Real per-tick cost of scene 3660962877's own scripts, weighted by how many
    /// objects use each one. Skips unless the corpus has been staged into the
    /// container (see the fleet-contention notes); nothing in CI depends on it.
    @Test("Real scene script cost: weighted per-frame total for 3660962877")
    func realSceneScriptCostDistribution() async throws {
        struct Entry: Decodable {
            let kind: String
            let prop: String
            let script: String
            let count: Int
        }
        let url = URL.applicationSupportDirectory
            .appending(path: "LiveWallpaper/script-cost-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let corpus = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            print("[scenecost] corpus not staged at \(url.path(percentEncoded: false)) — skipped")
            return
        }

        let governor = WPESceneScriptExecutionGovernor(limit: 1024)
        var weightedTotalUs = 0.0
        var perTick: [Double] = []
        var failures: [String] = []

        for entry in corpus {
            let tick: () -> Void
            do {
                switch entry.kind {
                case "text":
                    let instance = try WPESceneScriptInstance(
                        script: entry.script,
                        initialValue: "",
                        shared: WPESharedScriptState(),
                        governor: governor
                    )
                    tick = { _ = instance.tickString() }
                case "transform":
                    let instance = try WPEDynamicTransformScriptInstance(
                        script: entry.script,
                        seed: SIMD3<Double>(0, 0, 0),
                        canvasSize: SIMD2<Double>(3840, 2160),
                        shared: WPESharedScriptState()
                    )
                    tick = { _ = instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)) }
                default:
                    let instance = try WPELayerScriptInstance(
                        script: entry.script,
                        shared: WPESharedScriptState(),
                        outputMode: .returnedAlpha(initialValue: 1)
                    )
                    tick = { _ = instance.tick(runtimeSeconds: 1) }
                }
            } catch {
                failures.append("\(entry.kind)/\(entry.prop) x\(entry.count): \(error)")
                continue
            }

            for _ in 1 ... 100 { tick() }
            let calls = 500
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 1 ... calls { tick() }
            let us = Double(DispatchTime.now().uptimeNanoseconds - started) / Double(calls) / 1000
            perTick.append(us)
            weightedTotalUs += us * Double(entry.count)
            print("[scenecost] \(entry.kind)/\(entry.prop) x\(entry.count) \(Int(entry.script.count))B -> \(us)us")
        }

        let sorted = perTick.sorted()
        print("""
        [scenecost] distinct=\(perTick.count) failed=\(failures.count) \
        minUs=\(sorted.first ?? 0) medianUs=\(sorted[sorted.count / 2]) maxUs=\(sorted.last ?? 0) \
        weightedFrameMs=\(weightedTotalUs / 1000) frameBudgetMs=16.667
        """)
        for failure in failures { print("[scenecost] FAILED \(failure)") }
        #expect(perTick.isEmpty == false)
    }
}
