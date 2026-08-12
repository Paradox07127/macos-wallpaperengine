import Foundation
import Testing
@testable import LiveWallpaper

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [Int] = []
    private var threads: [ObjectIdentifier] = []

    func record(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        order.append(index)
        threads.append(ObjectIdentifier(Thread.current))
    }

    var recordedOrder: [Int] { lock.lock(); defer { lock.unlock() }; return order }
    var distinctThreads: Set<ObjectIdentifier> { lock.lock(); defer { lock.unlock() }; return Set(threads) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class OverlapDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var overlapped = false
    func enter() { lock.lock(); inside += 1; if inside > 1 { overlapped = true }; lock.unlock() }
    func leave() { lock.lock(); inside -= 1; lock.unlock() }
    var overlapDetected: Bool { lock.lock(); defer { lock.unlock() }; return overlapped }
}

struct WPERenderThreadTests {

    @Test("perform runs work serially, FIFO, all on the one render thread")
    func serialFIFOSingleThread() async {
        let thread = WPERenderThread(label: "test.serial")
        defer { thread.shutdown() }

        let recorder = Recorder()
        let done = Counter()
        let n = 200

        for i in 0..<n {
            thread.perform { recorder.record(index: i) }
        }
        thread.perform { done.increment() }
        let completed = await eventually { done.count == 1 }
        #expect(completed)

        #expect(recorder.recordedOrder == Array(0..<n))
        #expect(recorder.distinctThreads.count == 1)
        #expect(!recorder.distinctThreads.contains(synchronousCurrentThreadIdentifier()))
    }

    @Test("isCurrent is true only while executing on the render thread")
    func isCurrentReflectsThread() async {
        let thread = WPERenderThread(label: "test.iscurrent")
        defer { thread.shutdown() }

        #expect(thread.isCurrent == false)

        let box = Counter()
        let done = Counter()
        thread.perform {
            if thread.isCurrent { box.increment() }
            done.increment()
        }
        let completed = await eventually { done.count == 1 }
        #expect(completed)
        #expect(box.count == 1)
    }

    @Test("a Timer added to the render loop fires (run loop stays alive)")
    func timerFires() async {
        let thread = WPERenderThread(label: "test.timer")
        defer { thread.shutdown() }

        let fired = Counter()
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in fired.increment() }
        thread.add(timer)

        let completed = await eventually { fired.count == 1 }
        #expect(completed)
    }

    @Test("render run loop drains an autorelease pool after each handled source")
    func runLoopUsesIterationAutoreleasePool() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPERenderThread.swift"
        )

        #expect(source.contains("while keepRunning"))
        #expect(source.contains("autoreleasepool {\n                    result = CFRunLoopRunInMode("))
        #expect(source.contains("60,\n                        true"))
        #expect(!source.contains("CFRunLoopRun()\n            }\n            finished.signal()"))
    }

    @Test("shutdown drains queued work, is idempotent, and still consumes later work")
    func shutdownDrainsAndIdempotent() {
        let thread = WPERenderThread(label: "test.shutdown")

        let counter = Counter()
        let n = 100
        for _ in 0..<n {
            thread.perform { counter.increment() }
        }
        thread.shutdown()
        #expect(counter.count == n)

        thread.perform { counter.increment() }
        #expect(counter.count == n + 1)

        thread.shutdown()
        #expect(counter.count == n + 1)
    }

    @Test("shutdown window: a post-shutdown job never overlaps an in-flight render-thread job")
    func shutdownWindowMutualExclusion() async {
        let thread = WPERenderThread(label: "test.shutdown.window")
        let overlap = OverlapDetector()

        let aRunning = Counter()
        let aMayFinish = DispatchSemaphore(value: 0)
        let bDone = Counter()
        let shutdownReturned = Counter()

        thread.perform {
            overlap.enter()
            aRunning.increment()
            aMayFinish.wait()
            overlap.leave()
        }
        let started = await eventually { aRunning.count == 1 }
        #expect(started)

        Thread.detachNewThread {
            thread.shutdown()
            shutdownReturned.increment()
        }
        try? await Task.sleep(for: .milliseconds(100))

        Thread.detachNewThread {
            thread.perform {
                overlap.enter()
                overlap.leave()
                bDone.increment()
            }
        }
        try? await Task.sleep(for: .milliseconds(100))

        aMayFinish.signal()
        let bCompleted = await eventually { bDone.count == 1 }
        let shutdownCompleted = await eventually { shutdownReturned.count == 1 }
        #expect(bCompleted)
        #expect(shutdownCompleted)
        #expect(overlap.overlapDetected == false)
    }

    @Test("checkIsolated passes on the render thread (bare callback, no task executor)")
    func executorCheckIsolatedOnThread() async {
        let thread = WPERenderThread(label: "test.checkisolated")
        defer { thread.shutdown() }
        let executor = WPERenderThreadExecutor(thread: thread)

        let passed = Counter()
        let done = Counter()
        thread.perform {
            executor.checkIsolated()
            passed.increment()
            done.increment()
        }
        let completed = await eventually { done.count == 1 }
        #expect(completed)
        #expect(passed.count == 1)
    }

    @Test("adaptive QoS actually re-tiers the OS thread: economy → high → economy")
    func adaptiveQoSChangesRealThreadClass() async {
        let thread = WPERenderThread(label: "test.qos.adaptive", adaptiveQoSEnabled: true)

        func qosAfter(feeding durations: [Double]) async -> qos_class_t {
            let box = QoSBox()
            let done = Counter()
            thread.perform {
                for d in durations { thread.noteFrameDuration(d) }
                box.set(qos_class_self())
                done.increment()
            }
            _ = await eventually { done.count == 1 }
            return box.value
        }

        let high = await qosAfter(feeding: Array(repeating: 0.012, count: 5))
        let economy = await qosAfter(feeding: Array(repeating: 0.002, count: 120))
        #expect(high == QOS_CLASS_USER_INTERACTIVE)
        #expect(economy == QOS_CLASS_UTILITY)
        await shutdownAtUtility { thread.shutdown() }
    }

    @Test("escape hatch OFF keeps the OS thread at userInteractive despite cheap frames")
    func disabledEscapeHatchKeepsRealThreadHigh() async {
        let thread = WPERenderThread(label: "test.qos.pinned", adaptiveQoSEnabled: false)
        defer { thread.shutdown() }

        let box = QoSBox()
        let done = Counter()
        thread.perform {
            for _ in 0..<120 { thread.noteFrameDuration(0.001) }
            box.set(qos_class_self())
            done.increment()
        }
        _ = await eventually { done.count == 1 }
        #expect(box.value == QOS_CLASS_USER_INTERACTIVE)
    }
}

private final class QoSBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: qos_class_t = QOS_CLASS_UNSPECIFIED

    func set(_ value: qos_class_t) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: qos_class_t {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

struct WPEAdaptiveRenderQoSTests {

    @Test("disabled escape hatch pins .high and never downgrades")
    func disabledPinsHigh() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: false)
        #expect(qos.level == .high)
        for _ in 0..<200 {
            #expect(qos.record(frameDuration: 0.0005) == nil)
        }
        #expect(qos.level == .high)
    }

    @Test("enabled starts economy and climbs to high once p95 exceeds the raise threshold")
    func raiseOnOverrun() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        #expect(qos.level == .economy)
        #expect(qos.record(frameDuration: 0.012) == .high)
        #expect(qos.level == .high)
    }

    @Test("hysteresis: mid-band durations neither raise from economy nor lower from high")
    func hysteresisDeadZone() {
        var fromEconomy = WPEAdaptiveRenderQoS(isEnabled: true)
        for _ in 0..<120 { #expect(fromEconomy.record(frameDuration: 0.008) == nil) }
        #expect(fromEconomy.level == .economy)

        var fromHigh = WPEAdaptiveRenderQoS(isEnabled: true)
        _ = fromHigh.record(frameDuration: 0.012)
        #expect(fromHigh.level == .high)
        for _ in 0..<120 { #expect(fromHigh.record(frameDuration: 0.008) == nil) }
        #expect(fromHigh.level == .high)
    }

    @Test("high downgrades to economy once the whole window is comfortably under budget")
    func lowerWhenComfortable() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        _ = qos.record(frameDuration: 0.012)
        #expect(qos.level == .high)
        var downgraded = false
        for _ in 0..<90 where !downgraded {
            if qos.record(frameDuration: 0.003) == .economy { downgraded = true }
        }
        #expect(downgraded)
        #expect(qos.level == .economy)
    }

    @Test("warm-up boost pins high for exactly N frames regardless of cheap timings")
    func boostPinsThenReleases() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        qos.boost(frames: 3)
        #expect(qos.record(frameDuration: 0.001) == .high)
        #expect(qos.record(frameDuration: 0.001) == nil)
        #expect(qos.record(frameDuration: 0.001) == nil)
        #expect(qos.level == .high)
        #expect(qos.boostFramesRemainingForTesting == 0)
        var back = false
        for _ in 0..<90 where !back {
            if qos.record(frameDuration: 0.001) == .economy { back = true }
        }
        #expect(back)
    }

    @Test("budget retarget: a 30fps budget tolerates frames a 60fps budget would reject")
    func budgetRetarget() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        qos.setBudget(seconds: 1.0 / 30.0)
        for _ in 0..<120 { #expect(qos.record(frameDuration: 0.012) == nil) }
        #expect(qos.level == .economy)
    }
}

struct WPEDisplayRenderActorTests {

    @Test("run() hops onto the render thread and isolation is bound to the executor")
    func runExecutesOnRenderThread() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.run")
        defer { actor.shutdown() }

        #expect(actor.isOnRenderThread == false)

        let onRenderThread = await actor.run { iso in iso.isOnRenderThread }
        #expect(onRenderThread == true)
    }

    @Test("successive run() calls land on the same render thread")
    func runIsStableThread() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.stable")
        defer { actor.shutdown() }

        let a = await actor.run { _ in ObjectIdentifier(Thread.current) }
        let b = await actor.run { _ in ObjectIdentifier(Thread.current) }
        #expect(a == b)
        let onMain = await actor.run { _ in Thread.isMainThread }
        #expect(onMain == false)
    }

    @Test("assumeIsolatedOnRenderThread grants sync isolated access from a bare run-loop callback")
    func assumeIsolatedSyncEntry() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.assume")
        defer { actor.shutdown() }

        let box = Counter()
        let done = Counter()
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            let onThread = actor.assumeIsolatedOnRenderThread { iso in iso.isOnRenderThread }
            if onThread { box.increment() }
            done.increment()
        }
        actor.add(timer)

        let completed = await eventually { done.count == 1 }
        #expect(completed)
        #expect(box.count == 1)
    }

    @Test("actor work after shutdown is still consumed, not dropped")
    func jobConsumedAfterShutdown() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.postshutdown")
        actor.shutdown()

        let value = await actor.run { _ in 42 }
        #expect(value == 42)
    }

    // MARK: - Main-backed (M2c1 flag-off) mode

    @Test("main-backed actor runs isolation on the main thread, not a render thread")
    @MainActor
    func mainBackingRunsOnMain() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.main", backing: .main)
        defer { actor.shutdown() }

        let onMain = await actor.run { _ in Thread.isMainThread }
        #expect(onMain == true)
        let onRenderThread = await actor.run { iso in iso.isOnRenderThread }
        #expect(onRenderThread == true)
    }

    @Test("main-backed actor owns no thread and shutdown is a no-op")
    @MainActor
    func mainBackingShutdownIsNoOp() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.main.shutdown", backing: .main)
        actor.shutdown()
        let value = await actor.run { _ in 7 }
        #expect(value == 7)
    }

#if !LITE_BUILD
    @Test("main-backed shim renders the frame synchronously (draw returns = frame produced)")
    @MainActor
    func mainBackedShimRendersSynchronously() {
        let actor = WPEDisplayRenderActor(backing: .main)
        defer { actor.shutdown() }
        let shim = WPERenderSurfaceClientShim(renderActor: actor, backing: .main)

        #expect(shim.completedFrameDeliveries == 0)
        shim.renderAndPresentFrame()
        #expect(shim.completedFrameDeliveries == 1)
        shim.renderAndPresentFrame()
        #expect(shim.completedFrameDeliveries == 2)
    }

    @Test("render-thread-backed shim delivers the frame asynchronously")
    @MainActor
    func renderThreadShimDeliversAsynchronously() async {
        let actor = WPEDisplayRenderActor(backing: .renderThread)
        let shim = WPERenderSurfaceClientShim(renderActor: actor, backing: .renderThread)

        shim.renderAndPresentFrame()
        var delivered = false
        for _ in 0..<400 where !delivered {
            if shim.completedFrameDeliveries == 1 { delivered = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(delivered)
        await shutdownAtUtility { actor.shutdown() }
    }
#endif

    @Test("off-main render flag defaults to true (render-thread backing)")
    func offMainFlagDefaultsTrue() {
        UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey)
        #expect(WPEOffMainRenderFlag.isEnabled == true)
        if case .renderThread = WPEOffMainRenderFlag.backing {} else {
            Issue.record("absent flag must select .renderThread backing")
        }
    }

    @Test("writing the flag false rolls back to main backing")
    func offMainFlagFalseSelectsMain() {
        UserDefaults.standard.set(false, forKey: WPEOffMainRenderFlag.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey) }
        #expect(WPEOffMainRenderFlag.isEnabled == false)
        if case .main = WPEOffMainRenderFlag.backing {} else {
            Issue.record("flag written false must select .main backing")
        }
    }

    @Test("M2c1b-3c: flag-on selects the dedicated render-thread backing")
    func offMainFlagSelectsRenderThread() {
        UserDefaults.standard.set(true, forKey: WPEOffMainRenderFlag.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey) }
        #expect(WPEOffMainRenderFlag.isEnabled == true)
        if case .renderThread = WPEOffMainRenderFlag.backing {} else {
            Issue.record("flag-on must select .renderThread backing after b-3c")
        }
    }

#if !LITE_BUILD
    // MARK: - M2c2 CADisplayLink frame driver

    @Test("display-link build and terminal stop share one ordered lifecycle")
    func displayLinkLifecycleIsOrderedAndDrained() throws {
        let surface = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPERenderSurface.swift"
        )
        let actor = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPEDisplayRenderActor.swift"
        )
        let session = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Session/SceneWallpaperSession.swift"
        )

        #expect(surface.contains("private var displayLinkLifecycleTask: Task<Void, Never>?"))
        #expect(surface.contains("await previousTask?.value"))
        #expect(surface.contains("await renderActor.stopDisplayLinkDriver(generation: generation)"))
        #expect(actor.contains("private var displayLinkLifecycle = WPEDisplayLinkLifecycleState()"))
        #expect(actor.contains("guard displayLinkLifecycle.admit(generation: generation)"))
        #expect(session.contains("let displayLinkStopTask = surface.stopDisplayLinkDriver()"))
        #expect(session.contains("await displayLinkStopTask?.value"))
    }

    @Test("display-link lifecycle rejects stale and duplicate generations")
    func displayLinkLifecycleRejectsStaleGenerations() {
        var lifecycle = WPEDisplayLinkLifecycleState()

        let first = lifecycle.admit(generation: 1)
        let duplicate = lifecycle.admit(generation: 1)
        let stale = lifecycle.admit(generation: 0)
        let second = lifecycle.admit(generation: 2)
        #expect(first)
        #expect(!duplicate)
        #expect(!stale)
        #expect(second)
        #expect(lifecycle.latestGeneration == 2)
    }

    @Test("display-link terminal stop cannot be reopened")
    func displayLinkLifecycleStopIsTerminal() {
        var lifecycle = WPEDisplayLinkLifecycleState()
        let admitted = lifecycle.admit(generation: 1)
        #expect(admitted)

        lifecycle.stop(generation: 2)
        let reopened = lifecycle.admit(generation: 3)

        #expect(lifecycle.isTerminal)
        #expect(lifecycle.latestGeneration == 2)
        #expect(!reopened)
    }

    @Test("effectiveFPS maps to a fixed-cadence frame-rate range (min == max == preferred)")
    func fpsMapsToFrameRateRange() {
        let range = WPEDisplayRenderActor.frameRateRange(forPreferredFPS: 30)
        #expect(range.minimum == 30)
        #expect(range.maximum == 30)
        #expect(range.preferred == 30)
        let clamped = WPEDisplayRenderActor.frameRateRange(forPreferredFPS: 0)
        #expect(clamped.maximum == 1)
    }

    @Test("link pacing setters buffer pause + fps on the render thread even with no link installed")
    func linkPacingBuffers() async {
        let actor = WPEDisplayRenderActor(label: "test.link.buffer", backing: .renderThread)
        defer { actor.shutdown() }

        await actor.run { iso in
            iso.setLinkPaused(false)
            iso.setLinkPreferredFPS(24)
        }
        let (paused, fps, hasLink) = await actor.run { iso in
            (iso.linkPausedForTesting, iso.linkPreferredFPSForTesting, iso.hasDisplayLinkForTesting)
        }
        #expect(paused == false)
        #expect(fps == 24)
        #expect(hasLink == false)
    }

    @Test("the pacer routes applyPacing onto the render-thread link buffer")
    func pacerRoutesPacingToLink() async {
        let actor = WPEDisplayRenderActor(label: "test.link.pacer", backing: .renderThread)
        defer { actor.shutdown() }
        let pacer = WPERenderThreadFramePacer(surface: StubSurfaceControl(), renderActor: actor)

        await actor.run { _ in
            pacer.applyPacing(WPERenderPacingUpdate(
                isPaused: false,
                enableSetNeedsDisplay: nil,
                preferredFramesPerSecond: 48
            ))
        }
        let (paused, fps) = await actor.run { iso in
            (iso.linkPausedForTesting, iso.linkPreferredFPSForTesting)
        }
        #expect(paused == false)
        #expect(fps == 48)
    }

    @Test("the pacer safely hops any-thread protocol calls onto the render actor")
    func pacerAcceptsOffActorDelivery() async throws {
        let actor = WPEDisplayRenderActor(label: "test.link.off-actor", backing: .renderThread)
        let pacer = WPERenderThreadFramePacer(surface: StubSurfaceControl(), renderActor: actor)

        // Regression: live-poster continuation work can reach this protocol seam
        // from a cooperative executor. Direct assumeIsolated used to SIGTRAP
        // before any of these calls could be delivered.
        pacer.applyPacing(WPERenderPacingUpdate(
            isPaused: false,
            enableSetNeedsDisplay: nil,
            preferredFramesPerSecond: 37
        ))
        pacer.setNeedsRedraw()
        pacer.drawImmediately()

        var observed: (Bool?, Int)?
        for _ in 0 ..< 100 {
            observed = await actor.run { iso in
                (iso.linkPausedForTesting, iso.linkPreferredFPSForTesting)
            }
            if observed?.0 == false, observed?.1 == 37 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observed?.0 == false)
        #expect(observed?.1 == 37)
        await shutdownAtUtility { actor.shutdown() }
    }

    @Test("a run-loop callback drives renderFrame on the render thread (link stand-in)")
    func linkCallbackDrivesFrameOnRenderThread() async {
        let actor = WPEDisplayRenderActor(label: "test.link.callback", backing: .renderThread)

        let onThread = Counter()
        let done = Counter()
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            actor.assumeIsolatedOnRenderThread { iso in
                if iso.isOnRenderThread { onThread.increment() }
                iso.renderFrame()
            }
            done.increment()
        }
        actor.add(timer)

        let completed = await eventually { done.count == 1 }
        #expect(completed)
        #expect(onThread.count == 1)
        await shutdownAtUtility { actor.shutdown() }
    }
#endif
}

private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Keeps Foundation's sync-only `Thread.current` API outside async test bodies.
private func synchronousCurrentThreadIdentifier() -> ObjectIdentifier {
    ObjectIdentifier(Thread.current)
}

/// The tested render thread intentionally sits at utility QoS after cheap frames.
/// Joining it from the test runner's user-initiated thread creates a checker-only
/// priority inversion, so teardown is dispatched at the same QoS and awaited
/// cooperatively by the test task.
private func shutdownAtUtility(_ shutdown: @escaping @Sendable () -> Void) async {
    let done = Counter()
    DispatchQueue.global(qos: .utility).async {
        shutdown()
        done.increment()
    }
    _ = await eventually { done.count == 1 }
}

#if !LITE_BUILD
private final class StubSurfaceControl: WPESurfaceControl, @unchecked Sendable {
    func applyPacing(_ update: WPERenderPacingUpdate) {}
    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_ enabled: Bool) {}
}
#endif
