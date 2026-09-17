import Foundation
import LiveWallpaperCore
import os
import QuartzCore

/// Persistent serial render thread with a live run loop for display-link callbacks.
/// Initialization handoff and mutable lifecycle state are synchronized before cross-thread access.
final class WPERenderThread: @unchecked Sendable {

    enum State {
        case running
        /// The loop exits after its current pass; jobs posted meanwhile are drained by the exit path, still on the render thread.
        case stopRequested
        /// New work runs inline on the caller (serialized via `postShutdownLock`) with nothing left to overlap.
        case stopped
    }

    /// Lifecycle state shared with the run-loop thread. Created before the thread so the
    /// thread closure never captures a half-initialized `self`. `@unchecked Sendable`: every
    /// field is guarded by `condition`. It must not reference the loop or the drain source —
    /// the source's context retains this object, and a back-reference would be a leak cycle.
    private final class Lifecycle: @unchecked Sendable {
        let condition = NSCondition()
        var state: State = .running
        /// FIFO of posted work. The render thread drains it from `drainSource`, and once more on exit.
        var jobs: [@Sendable () -> Void] = []
        /// True once the exit path has run the leftover jobs; joiners wait for this, not for `.stopped`.
        var hasExited = false
        /// Recursive because an inline job may itself re-enqueue synchronously. Mutual exclusion is the `SerialExecutor` contract — not same-thread.
        let postShutdownLock = NSRecursiveLock()

        #if DEBUG
        static let liveCount = OSAllocatedUnfairLock(initialState: 0)

        init() {
            Self.liveCount.withLock { $0 += 1 }
        }

        deinit {
            Self.liveCount.withLock { $0 -= 1 }
        }
        #endif

        func takeJobs() -> [@Sendable () -> Void] {
            condition.lock()
            defer { condition.unlock() }
            let taken = jobs
            jobs.removeAll(keepingCapacity: true)
            return taken
        }

        var isStopRequested: Bool {
            condition.lock()
            defer { condition.unlock() }
            return state != .running
        }

        var hasExitedValue: Bool {
            condition.lock()
            defer { condition.unlock() }
            return hasExited
        }

        /// Exit path, on the render thread. Leftovers are drained in rounds while the state stays
        /// `.stopRequested`, so a post that arrives mid-drain is queued and run here — never inline,
        /// where it would block its caller on `postShutdownLock` for as long as a leftover runs.
        /// `.stopped` is published under the same lock acquisition that observes an empty queue,
        /// so no post is orphaned: it is either in a round or runs inline after.
        func finishStopping() {
            postShutdownLock.lock()
            while true {
                condition.lock()
                let leftovers = jobs
                jobs.removeAll()
                if leftovers.isEmpty {
                    state = .stopped
                    condition.unlock()
                    break
                }
                condition.unlock()
                for job in leftovers {
                    job()
                }
            }
            postShutdownLock.unlock()
            condition.lock()
            hasExited = true
            condition.broadcast()
            condition.unlock()
        }

        /// Blocks the caller until the thread has exited or `deadline` passes.
        func waitForExit(until deadline: Date) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            while !hasExited {
                guard condition.wait(until: deadline) else { break }
            }
            return hasExited
        }
    }

    /// One-shot handoff of the loop objects from the render thread back to `init`, consumed
    /// under the ready semaphore. `@unchecked Sendable`: written once on the render thread,
    /// read once on the init thread with the semaphore as the happens-before edge.
    private final class LoopHandoff: @unchecked Sendable {
        var nsRunLoop: RunLoop?
        var cfRunLoop: CFRunLoop?
        var drainSource: CFRunLoopSource?
        var pthread: pthread_t?
    }

    private let lifecycle = Lifecycle()
    private let backingThread: Thread

    /// Populated by the time `init` returns and never mutated afterward.
    private let nsRunLoop: RunLoop
    private let cfRunLoop: CFRunLoop
    private let drainSource: CFRunLoopSource
    private let backingPThread: pthread_t

    /// Escape hatch: `defaults write <bundle> loomscreen.wallpapers.adaptiveRenderQoS.v1 -bool NO` pins `.userInteractive`. Default ON.
    static let adaptiveQoSDefaultsKey = "loomscreen.wallpapers.adaptiveRenderQoS.v1"

    static var adaptiveQoSEnabledFromDefaults: Bool {
        UserDefaults.standard.object(forKey: adaptiveQoSDefaultsKey) as? Bool ?? true
    }

    /// Adaptive-QoS state machine. Mutated ONLY on the render thread (via
    /// `noteFrameDuration` / `boostRenderQoSWarmup` / `setFrameBudget`), which is
    /// serial — so no lock, matching this class's `@unchecked Sendable` contract.
    private var adaptiveQoS: WPEAdaptiveRenderQoS

    private let qosMode: WPERenderQoSMode
    private let qosDiagnosticsEnabled = ProcessInfo.processInfo.environment["WPE_RENDER_QOS_DIAGNOSTICS"] == "1"
    private var diagnosticFrames = 0
    private var diagnosticHighFrames = 0
    private var diagnosticWallSeconds = 0.0
    private var diagnosticDrawableSeconds = 0.0

    init(
        label: String = "com.livewallpaper.render",
        adaptiveQoSEnabled: Bool? = nil,
        qosMode: WPERenderQoSMode? = nil
    ) {
        let adaptiveEnabled = adaptiveQoSEnabled ?? Self.adaptiveQoSEnabledFromDefaults
        self.qosMode = qosMode ?? WPERenderQoSMode.resolve(
            environment: adaptiveQoSEnabled == nil ? ProcessInfo.processInfo.environment : [:],
            adaptiveEnabled: adaptiveEnabled
        )
        adaptiveQoS = WPEAdaptiveRenderQoS(isEnabled: self.qosMode.isAdaptive)
        let loopState = lifecycle
        let handoff = LoopHandoff()
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread {
            let ns = RunLoop.current
            let cf = ns.getCFRunLoop()

            // The drain source is the loop's only permanent source: it keeps the mode non-empty and its callout runs every posted job on this thread.
            var context = CFRunLoopSourceContext()
            context.info = Unmanaged.passUnretained(loopState).toOpaque()
            context.retain = { info in
                UnsafeRawPointer(Unmanaged<Lifecycle>.fromOpaque(info!).retain().toOpaque())
            }
            context.release = { info in
                Unmanaged<Lifecycle>.fromOpaque(info!).release()
            }
            context.perform = { info in
                let lifecycle = Unmanaged<Lifecycle>.fromOpaque(info!).takeUnretainedValue()
                for job in lifecycle.takeJobs() {
                    job()
                }
            }
            let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
            CFRunLoopAddSource(cf, source, .commonModes)

            handoff.nsRunLoop = ns
            handoff.cfRunLoop = cf
            handoff.drainSource = source
            handoff.pthread = pthread_self()
            ready.signal()

            // Return after each handled source so bridged Objective-C temporaries are released at frame cadence instead of only when the thread exits.
            while true {
                autoreleasepool {
                    _ = CFRunLoopRunInMode(
                        CFRunLoopMode.defaultMode,
                        60,
                        true
                    )
                }
                // The exit decision is ours, not CoreFoundation's: CF's stop flag lives in per-run data and is discarded when a handled source or the timeout returns first, so a `CFRunLoopStop` can be lost. A signalled `drainSource` always makes the run return, so this check is always reached.
                if loopState.isStopRequested {
                    break
                }
            }
            loopState.finishStopping()
        }
        thread.name = label
        // Base stays `.userInteractive` until the first frame; dropping earlier would invert priority for warm-up and any non-rendering caller.
        thread.qualityOfService = .userInteractive
        self.backingThread = thread

        thread.start()
        ready.wait()
        nsRunLoop = handoff.nsRunLoop!
        cfRunLoop = handoff.cfRunLoop!
        drainSource = handoff.drainSource!
        backingPThread = handoff.pthread!
    }

    // MARK: - Introspection

    var isCurrent: Bool { Thread.current === backingThread }

    #if DEBUG
    /// Lifecycle objects still alive process-wide; a stopped, released thread must not keep one.
    static var liveLifecycleCountForTesting: Int {
        Lifecycle.liveCount.withLock { $0 }
    }
    #endif

    // MARK: - Work delivery

    /// Before exit enqueue never blocks the caller. The block is queued for the render thread (FIFO, drained by
    /// the exit path if it arrives during the stop window); afterwards it runs inline on the caller,
    /// serialized via `postShutdownLock` — it is never dropped.
    func perform(_ block: @escaping @Sendable () -> Void) {
        lifecycle.condition.lock()
        switch lifecycle.state {
        case .running, .stopRequested:
            lifecycle.jobs.append(block)
            lifecycle.condition.unlock()
            signalDrain()
        case .stopped:
            lifecycle.condition.unlock()
            runInline(block)
        }
    }

    private func signalDrain() {
        CFRunLoopSourceSignal(drainSource)
        CFRunLoopWakeUp(cfRunLoop)
    }

    private func runInline(_ block: @Sendable () -> Void) {
        lifecycle.postShutdownLock.lock()
        defer { lifecycle.postShutdownLock.unlock() }
        block()
    }

    // MARK: - Adaptive QoS

    /// Deferred to the first frame so the thread's `.userInteractive` base holds until frames actually flow.
    private var didSyncInitialQoS = false

    func noteFrameDuration(_ seconds: Double, drawableWait: Double = 0) {
        assert(isCurrent, "noteFrameDuration must run on the render thread")
        if !didSyncInitialQoS {
            didSyncInitialQoS = true
            applyQoS(adaptiveQoS.level)
        }
        if let level = adaptiveQoS.record(
            frameDuration: seconds,
            drawableWait: qosMode == .adaptiveWall ? 0 : drawableWait
        ) {
            applyQoS(level)
        }
        if qosDiagnosticsEnabled {
            recordDiagnostics(wall: seconds, drawable: drawableWait)
        }
    }

    private func recordDiagnostics(wall: Double, drawable: Double) {
        diagnosticFrames += 1
        diagnosticWallSeconds += wall
        diagnosticDrawableSeconds += drawable
        if qosMode == .userInteractive || (qosMode.isAdaptive && adaptiveQoS.level == .high) {
            diagnosticHighFrames += 1
        }
        guard diagnosticFrames == 120 else { return }
        Logger.notice(
            "[render-qos] mode=\(qosMode.rawValue) frames=\(diagnosticFrames) high=\(diagnosticHighFrames) "
                + "wallMs=\(diagnosticWallSeconds * 1000 / Double(diagnosticFrames)) "
                + "drawableMs=\(diagnosticDrawableSeconds * 1000 / Double(diagnosticFrames))",
            category: .wpeRender
        )
        diagnosticFrames = 0
        diagnosticHighFrames = 0
        diagnosticWallSeconds = 0
        diagnosticDrawableSeconds = 0
    }

    /// Request `.high` during load/reload warm-up in adaptive modes.
    func boostRenderQoSWarmup(frames: Int = 120) {
        assert(isCurrent, "boostRenderQoSWarmup must run on the render thread")
        adaptiveQoS.boost(frames: frames)
    }

    func setFrameBudget(seconds: Double) {
        assert(isCurrent, "setFrameBudget must run on the render thread")
        adaptiveQoS.setBudget(seconds: seconds)
    }

    private func applyQoS(_ level: WPEAdaptiveRenderQoS.Level) {
        let qos: qos_class_t = switch qosMode {
        case .utility: QOS_CLASS_UTILITY
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .adaptive, .adaptiveWall:
            level == .economy ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INTERACTIVE
        }
        pthread_set_qos_class_self_np(qos, 0)
    }

    // MARK: - Run-loop attachment

    func add(_ timer: Timer, forMode mode: RunLoop.Mode = .common) {
        nsRunLoop.add(timer, forMode: mode)
        CFRunLoopWakeUp(cfRunLoop)
    }

    func add(_ displayLink: CADisplayLink, forMode mode: RunLoop.Mode = .common) {
        displayLink.add(to: nsRunLoop, forMode: mode)
        CFRunLoopWakeUp(cfRunLoop)
    }

    // MARK: - Shutdown

    /// Never blocks; idempotent; safe from any thread including the render thread itself.
    /// The loop notices the request after its current pass and exits on its own.
    func requestStop() {
        lifecycle.condition.lock()
        guard lifecycle.state == .running else {
            lifecycle.condition.unlock()
            return
        }
        lifecycle.state = .stopRequested
        lifecycle.condition.unlock()
        // A signalled source persists until handled, so the run returns and the loop sees the request.
        signalDrain()
    }

    /// True once the render thread has drained its leftovers and exited.
    var hasExited: Bool {
        lifecycle.hasExitedValue
    }

    /// Resumes once the thread has exited. False on cancellation or after `timeout`; neither abandons
    /// the requested stop or its queued work. Only timeout logs a fault: cancelling a waiter is normal.
    @discardableResult
    func waitUntilStopped(timeout: Duration = .seconds(5)) async -> Bool {
        if lifecycle.hasExitedValue {
            return true
        }
        guard !Task.isCancelled else { return false }
        let override = pthread_override_qos_class_start_np(
            backingPThread, QOS_CLASS_USER_INTERACTIVE, 0
        )
        defer { pthread_override_qos_class_end_np(override) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !lifecycle.hasExitedValue {
            guard clock.now < deadline else {
                logExitTimeout(timeout)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                // A cancelled sleep throws immediately on every subsequent call. Do not spin until
                // the deadline; the loop owns draining and can finish without this particular waiter.
                return lifecycle.hasExitedValue
            }
        }
        return true
    }

    /// Synchronous join for callers on a thread they own (tests). Never call it from the main thread
    /// or an executor thread; production teardown uses `waitUntilStopped`. Returns false from the
    /// render thread itself (it cannot join itself; the loop exits after the current job) or on timeout.
    @discardableResult
    func stopAndJoin(timeout: TimeInterval = 5) -> Bool {
        requestStop()
        if isCurrent {
            return false
        }
        if lifecycle.hasExitedValue {
            return true
        }
        let override = pthread_override_qos_class_start_np(
            backingPThread, QOS_CLASS_USER_INTERACTIVE, 0
        )
        defer { pthread_override_qos_class_end_np(override) }
        let exited = lifecycle.waitForExit(until: Date(timeIntervalSinceNow: timeout))
        if !exited {
            logExitTimeout(.seconds(timeout))
        }
        return exited
    }

    private func logExitTimeout(_ timeout: Duration) {
        Logger.log(
            "Render thread \(backingThread.name ?? "?") did not exit within \(timeout) — leaving it running",
            category: .wpeRender,
            level: .fault
        )
    }
}
