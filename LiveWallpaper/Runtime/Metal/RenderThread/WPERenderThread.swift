import Foundation
import LiveWallpaperCore
import QuartzCore

/// Persistent serial render thread with a live run loop for display-link callbacks.
/// Initialization handoff and mutable lifecycle state are synchronized before cross-thread access.
final class WPERenderThread: @unchecked Sendable {

    enum State {
        case running
        /// New work must NOT run inline yet — that would overlap the still-draining thread and break `SerialExecutor` mutual exclusion. Late posts block until `.stopped`.
        case stopping
        /// New work now runs inline on the caller (serialized via `postShutdownLock`) with nothing to overlap.
        case stopped
    }

    /// One-shot handoff of the run loop from the render thread back to `init`,
    /// consumed under the ready semaphore. `@unchecked Sendable`: written once on
    /// the render thread, read once on the init thread with the semaphore as the
    /// happens-before edge.
    private final class LoopHandoff: @unchecked Sendable {
        var nsRunLoop: RunLoop?
        var cfRunLoop: CFRunLoop?
        var pthread: pthread_t?
    }

    private let stateCondition = NSCondition()
    private var state: State = .running

    /// Recursive because an inline job may itself re-enqueue synchronously. Mutual exclusion is the `SerialExecutor` contract — not same-thread.
    private let postShutdownLock = NSRecursiveLock()

    private let backingThread: Thread
    private let finishedSemaphore = DispatchSemaphore(value: 0)

    /// Populated by the time `init` returns and never mutated afterward.
    private let nsRunLoop: RunLoop
    private let cfRunLoop: CFRunLoop
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
        let handoff = LoopHandoff()
        let ready = DispatchSemaphore(value: 0)
        let finished = finishedSemaphore

        let thread = Thread {
            let ns = RunLoop.current
            let cf = ns.getCFRunLoop()
            // A bare port is the keep-alive source so the loop never exits for lack of sources; the run loop retains it, so no stored ref needed.
            ns.add(NSMachPort(), forMode: .common)

            handoff.nsRunLoop = ns
            handoff.cfRunLoop = cf
            handoff.pthread = pthread_self()
            ready.signal()

            // Return after each handled source so bridged Objective-C temporaries are released at frame cadence instead of only when the thread exits.
            var keepRunning = true
            while keepRunning {
                var result: CFRunLoopRunResult = .finished
                autoreleasepool {
                    result = CFRunLoopRunInMode(
                        CFRunLoopMode.defaultMode,
                        60,
                        true
                    )
                }
                keepRunning = result != .stopped && result != .finished
            }
            finished.signal()
        }
        thread.name = label
        // Base stays `.userInteractive` until the first frame; dropping earlier would invert priority for warm-up and any non-rendering caller.
        thread.qualityOfService = .userInteractive
        self.backingThread = thread

        thread.start()
        ready.wait()
        self.nsRunLoop = handoff.nsRunLoop!
        self.cfRunLoop = handoff.cfRunLoop!
        self.backingPThread = handoff.pthread!
    }

    // MARK: - Introspection

    var isCurrent: Bool { Thread.current === backingThread }

    // MARK: - Work delivery

    /// After shutdown the block runs inline on the caller (serialized via `postShutdownLock`) — it is never dropped.
    func perform(_ block: @escaping @Sendable () -> Void) {
        stateCondition.lock()
        switch state {
        case .running:
            // Enqueue under the lock so a post seen as `.running` always lands before the stop block and is drained, never dropped.
            CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(cfRunLoop)
            stateCondition.unlock()
        case .stopping:
            // Wait for `.stopped` before running inline — otherwise this job would overlap the drain and break mutual exclusion.
            while state == .stopping { stateCondition.wait() }
            stateCondition.unlock()
            runInline(block)
        case .stopped:
            stateCondition.unlock()
            runInline(block)
        }
    }

    private func runInline(_ block: @Sendable () -> Void) {
        postShutdownLock.lock()
        defer { postShutdownLock.unlock() }
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

    /// If called from the render thread itself it cannot join (would deadlock), so it only schedules the stop and returns.
    func shutdown() {
        let cf = cfRunLoop
        stateCondition.lock()
        guard state == .running else { stateCondition.unlock(); return }
        state = .stopping
        // FIFO: this stop block runs after every `.running` post; it is the correct place to publish `.stopped` so an inline post can no longer overlap one.
        CFRunLoopPerformBlock(cf, CFRunLoopMode.commonModes.rawValue) { [self] in
            stateCondition.lock()
            state = .stopped
            stateCondition.broadcast()
            stateCondition.unlock()
            CFRunLoopStop(cf)
        }
        CFRunLoopWakeUp(cf)
        stateCondition.unlock()

        if isCurrent { return }
        let override = pthread_override_qos_class_start_np(
            backingPThread, QOS_CLASS_USER_INTERACTIVE, 0
        )
        finishedSemaphore.wait()
        pthread_override_qos_class_end_np(override)
    }
}
