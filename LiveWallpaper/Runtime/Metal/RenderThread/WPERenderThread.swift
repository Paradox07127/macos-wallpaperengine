import Foundation
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

    init(label: String = "com.livewallpaper.render", adaptiveQoSEnabled: Bool? = nil) {
        let adaptiveEnabled = adaptiveQoSEnabled ?? Self.adaptiveQoSEnabledFromDefaults
        self.adaptiveQoS = WPEAdaptiveRenderQoS(isEnabled: adaptiveEnabled)
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

    func noteFrameDuration(_ seconds: Double) {
        assert(isCurrent, "noteFrameDuration must run on the render thread")
        if !didSyncInitialQoS {
            didSyncInitialQoS = true
            applyQoS(adaptiveQoS.level)
        }
        if let level = adaptiveQoS.record(frameDuration: seconds) {
            applyQoS(level)
        }
    }

    /// Pin `.high` for the first `frames` frames after a scene load/reload, so the
    /// heavy warm-up (lazy shader transpile) isn't throttled onto the E-cores.
    func boostRenderQoSWarmup(frames: Int = 120) {
        assert(isCurrent, "boostRenderQoSWarmup must run on the render thread")
        adaptiveQoS.boost(frames: frames)
    }

    func setFrameBudget(seconds: Double) {
        assert(isCurrent, "setFrameBudget must run on the render thread")
        adaptiveQoS.setBudget(seconds: seconds)
    }

    private func applyQoS(_ level: WPEAdaptiveRenderQoS.Level) {
        let qos: qos_class_t
        switch level {
        case .economy: qos = QOS_CLASS_UTILITY
        case .high: qos = QOS_CLASS_USER_INTERACTIVE
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
