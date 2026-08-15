#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

/// Shared admission + async-overrun quarantine for scene/layer/transform engines.
protocol WPESceneScriptEngineExecutionGuarding: AnyObject {
    var queue: DispatchQueue { get }
    var executionLane: WPESceneScriptBatchDispatcher.Lane { get }
    var governor: WPESceneScriptExecutionGovernor { get }
    var participant: WPESceneScriptExecutionGovernor.Participant { get }
    var instanceLimitToken: WPESceneScriptInstanceLimitToken? { get }
    var asyncExecutionSafety: WPESceneScriptAsyncExecutionSafety { get }
}

extension WPESceneScriptEngineExecutionGuarding {
    func allows(_ operation: WPESceneScriptOperation) -> Bool {
        instanceLimitToken?.allows(operation) ?? true
    }

    func acceptsCompletion() -> Bool {
        instanceLimitToken?.acceptsCompletion() ?? true
    }

    func quarantineAsyncIfOverdue(
        budget: TimeInterval
    ) -> WPESceneScriptAsyncExecutionSafety.Overrun? {
        let overrun = asyncExecutionSafety.quarantineIfOverdue(budget: budget, engine: self)
        if overrun != nil { executionLane.invalidate() }
        return overrun
    }

    func runWithBudget<T>(
        _ budget: TimeInterval,
        operation: WPESceneScriptOperation,
        admission: WPESceneScriptAdmissionPolicy,
        _ work: @escaping @Sendable () -> T
    ) -> WPESceneScriptBoundedExecutionResult<T> {
        let deadline = DispatchTime.now() + max(budget, 0)
        guard let safety = WPESceneScriptExecutionSafetyReservation.reserve(
            sceneToken: instanceLimitToken
        ) else { return .capacityUnavailable }
        let permit: WPESceneScriptExecutionGovernor.Permit? = switch admission {
        case .failFast:
            governor.tryAcquireUnreserved(for: participant)
        case .waitUntilDeadline:
            governor.acquire(for: participant, until: deadline)
        }
        guard let permit else {
            safety.complete()
            return .capacityUnavailable
        }
        guard DispatchTime.now() < deadline else {
            safety.complete()
            permit.release()
            return .capacityUnavailable
        }
        let done = DispatchSemaphore(value: 0)
        let box = WPESceneScriptResultBox<WPESceneScriptBoundedExecutionResult<T>>()
        queue.async {
            defer {
                safety.complete()
                permit.release()
                done.signal()
            }
            box.value = .completed(work())
        }
        guard done.wait(timeout: deadline) == .success else {
            _ = safety.quarantine(self, operation: operation)
            executionLane.invalidate()
            instanceLimitToken?.failClosed(.executionTimedOut(operation: operation))
            return .timedOut
        }
        return box.value ?? .timedOut
    }
}

private final class WPESceneScriptResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Keeps a JSC engine's final ARC release on the serial lane that owns its
/// context. Dropping a scene on the render actor only enqueues this handoff; if
/// the lane is wedged, the queued closure retains the engine without making the
/// render actor contend for that VM's JSLock.
final class WPESceneScriptLaneRelease<Value: AnyObject>: @unchecked Sendable {
    private let queue: DispatchQueue
    let value: Value

    init(value: Value, queue: DispatchQueue) {
        self.value = value
        self.queue = queue
    }

    deinit {
        // Safe despite `Value` being non-Sendable: deinit runs when the last
        // strong reference is already gone, so this closure is the only thing
        // that can reach the value, and all it does is hold it until the lane
        // drops it.
        nonisolated(unsafe) let laneOwnedValue = value
        queue.async {
            withExtendedLifetime(laneOwnedValue) {}
        }
    }
}

/// Engine-queue ↔ frame outcome slot: newest-wins, combine for one-shots, generation CAS.
final class WPESceneScriptOutcomeSlot<Outcome: Sendable>: Sendable {
    struct Claim: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    private struct State: Sendable {
        var pending: Outcome?
        var publishedGeneration: UInt64 = 0
        var consumedGeneration: UInt64 = 0
        var nextTickGeneration: UInt64 = 0
        var inFlightTickGeneration: UInt64?
        var tickStartedAtUptimeNanos: UInt64?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let combine: @Sendable (_ pending: Outcome, _ newer: Outcome) -> Outcome

    init(
        combine: @escaping @Sendable (_ pending: Outcome, _ newer: Outcome) -> Outcome = { _, newer in newer }
    ) {
        self.combine = combine
    }

    /// Newest unconsumed outcome (consumes), or nil to keep last.
    func takeLatest() -> Outcome? {
        state.withLock { s in
            guard s.publishedGeneration > s.consumedGeneration else { return nil }
            s.consumedGeneration = s.publishedGeneration
            defer { s.pending = nil }
            return s.pending
        }
    }

    /// Claim the single in-flight tick (generation blocks stale clear/overwrite).
    func beginTick() -> Claim? {
        state.withLock { s in
            guard s.inFlightTickGeneration == nil else { return nil }
            s.nextTickGeneration &+= 1
            s.inFlightTickGeneration = s.nextTickGeneration
            s.tickStartedAtUptimeNanos = DispatchTime.now().uptimeNanoseconds
            return Claim(generation: s.nextTickGeneration)
        }
    }

    /// Admission failed before submit — release only this claim.
    @discardableResult
    func rejectTick(_ claim: Claim) -> Bool {
        state.withLock { s in
            guard s.inFlightTickGeneration == claim.generation else { return false }
            s.inFlightTickGeneration = nil
            s.tickStartedAtUptimeNanos = nil
            return true
        }
    }

    /// Queue-side tick finish; stale generation discarded.
    @discardableResult
    func publishTick(_ outcome: Outcome, for claim: Claim) -> Bool {
        state.withLock { s in
            guard s.inFlightTickGeneration == claim.generation else { return false }
            s.inFlightTickGeneration = nil
            s.tickStartedAtUptimeNanos = nil
            Self.store(outcome, into: &s, combine: combine)
            return true
        }
    }

    /// Queue-side event/property finish (no tick claim).
    func publishEvent(_ outcome: Outcome) {
        state.withLock { s in Self.store(outcome, into: &s, combine: combine) }
    }

    /// After sync eval: fold pending + mark consumed so an older tick can't clobber it.
    func supersede(with outcome: Outcome) -> Outcome {
        state.withLock { s in
            var merged = outcome
            if s.publishedGeneration > s.consumedGeneration, let pending = s.pending {
                merged = combine(pending, outcome)
            }
            s.pending = nil
            s.publishedGeneration += 1
            s.consumedGeneration = s.publishedGeneration
            return merged
        }
    }

    private static func store(
        _ outcome: Outcome,
        into s: inout State,
        combine: (_ pending: Outcome, _ newer: Outcome) -> Outcome
    ) {
        if s.publishedGeneration > s.consumedGeneration, let pending = s.pending {
            s.pending = combine(pending, outcome)
        } else {
            s.pending = outcome
        }
        s.publishedGeneration += 1
    }
}

/// Liveness beacon for retain-cycle regressions AND the memory audit: an exact
/// count of JSContexts still alive. Not DEBUG-gated — each instance is an empty
/// NSObject plus two atomic ops, and a Release build is exactly where the
/// "1382 scripts x ~1.15 MB of JSVirtualMachine" question gets asked.
final class WPESceneScriptContextBeacon: NSObject {
    private static let liveLock = OSAllocatedUnfairLock(initialState: 0)
    static var liveCount: Int { liveLock.withLock { $0 } }

    override init() {
        super.init()
        Self.liveLock.withLock { $0 += 1 }
    }

    deinit { Self.liveLock.withLock { $0 -= 1 } }
}

/// Per-engine `registerAudioBuffers` bridge; rewrites arrays in place each tick (WPE permanent link).
/// Not Sendable — only touched on the engine's queue.
final class WPESceneScriptAudioBridge {
    /// WPE AUDIO_RESOLUTION_* constants (broker width = largest).
    private static let resolutions = [16, 32, 64]
    /// FIFO cap on registrations: a script that calls registerAudioBuffers()
    /// from update() would otherwise append 3 permanently-protected JSValues
    /// per frame, pinning them for the context's lifetime.
    private static let maxRegisteredBuffers = 16

    private struct Buffer {
        let bands: Int
        let average: JSValue
        let left: JSValue
        let right: JSValue
    }

    private var buffers: [Buffer] = []
    /// One trailing zero pass after capture stops; later ticks only read isCapturing.
    private var wasSilent = true
    /// WPEAudioDebugLog: split "bars don't move" into register/zeros/downstream.
    private static let debugLogEnabled = UserDefaults.standard.bool(forKey: "WPEAudioDebugLog")
    private var debugTickCounter = 0

    func install(in engine: JSValue, context: JSContext) {
        for bands in Self.resolutions {
            engine.setObject(bands, forKeyedSubscript: "AUDIO_RESOLUTION_\(bands)" as NSString)
        }

        // Optional return (nil→undefined); context-less JSValue is not bridgeable.
        let register: @convention(block) (JSValue?) -> JSValue? = { [weak self, weak context] requested in
            guard let context else { return nil }
            let buffer = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            // Unresolved resolution → 16 (zero-length arrays index to NaN).
            let asked = (requested?.isNumber ?? false) ? Int(requested!.toInt32()) : 16
            let bands = Self.resolutions.contains(asked) ? asked : 16
            let zeros = [Double](repeating: 0, count: bands)
            let average = JSValue(object: zeros, in: context) ?? JSValue(newArrayIn: context)!
            let left = JSValue(object: zeros, in: context) ?? JSValue(newArrayIn: context)!
            let right = JSValue(object: zeros, in: context) ?? JSValue(newArrayIn: context)!
            buffer.setObject(average, forKeyedSubscript: "average" as NSString)
            buffer.setObject(left, forKeyedSubscript: "left" as NSString)
            buffer.setObject(right, forKeyedSubscript: "right" as NSString)
            if Self.debugLogEnabled {
                Logger.notice(
                    "[AudioCapture] registerAudioBuffers called bands=\(bands)"
                        + " bridgeAlive=\(self != nil)",
                    category: .audioCapture
                )
            }
            if let self {
                self.buffers.append(
                    Buffer(bands: bands, average: average, left: left, right: right)
                )
                // A dropped buffer's JS arrays simply stop receiving updates;
                // a per-update registrant converges on its newest registration.
                if self.buffers.count > Self.maxRegisteredBuffers {
                    self.buffers.removeFirst(self.buffers.count - Self.maxRegisteredBuffers)
                }
            }
            return buffer
        }
        // Undocumented 64-bin stereo average; sampled per call (rare, no per-tick cache).
        let getFrequency: @convention(block) (Int) -> Double = { index in
            let averages = Self.stereoAverage64()
            guard index >= 0, index < averages.count else { return 0 }
            return averages[index]
        }
        let getFrequencies: @convention(block) () -> JSValue? = { [weak context] in
            guard let context else { return nil }
            return JSValue(object: Self.stereoAverage64(), in: context)
                ?? JSValue(newArrayIn: context)!
        }
        engine.setObject(register, forKeyedSubscript: "registerAudioBuffers" as NSString)
        engine.setObject(getFrequency, forKeyedSubscript: "getFrequency" as NSString)
        engine.setObject(getFrequencies, forKeyedSubscript: "getFrequencies" as NSString)
    }

    /// Per-tick buffer rewrite; no-op if script never registered.
    func refresh() {
        if Self.debugLogEnabled {
            debugTickCounter += 1
            if debugTickCounter % 120 == 1, let first = buffers.first {
                // Log whole vector — distinguishes dead low-end vs dead spectrum.
                let values = (0..<first.bands).map {
                    String(format: "%.2f", first.average.atIndex($0)?.toDouble() ?? -1)
                }
                let peak = (0..<first.bands)
                    .map { ($0, first.average.atIndex($0)?.toDouble() ?? 0) }
                    .max { $0.1 < $1.1 }
                Logger.notice(
                    "[AudioCapture] script bridge: bands=\(first.bands)"
                        + " peakBand=\(peak?.0 ?? -1)@\(String(format: "%.3f", peak?.1 ?? 0))"
                        + " [\(values.joined(separator: " "))]",
                    category: .audioCapture
                )
            }
        }
        guard !buffers.isEmpty else { return }
        guard SystemAudioCaptureManager.isCapturing else {
            // One trailing zero pass when capture stops; then no-op (capture usually off).
            guard !wasSilent else { return }
            for buffer in buffers { write(buffer, left: nil, right: nil) }
            wasSilent = true
            return
        }
        let frame = SystemAudioCaptureManager.broker.snapshot()
        for buffer in buffers {
            write(
                buffer,
                left: Self.downsample(frame.left, to: buffer.bands),
                right: Self.downsample(frame.right, to: buffer.bands)
            )
        }
        wasSilent = false
    }

    private static func stereoAverage64() -> [Double] {
        guard SystemAudioCaptureManager.isCapturing else {
            return [Double](repeating: 0, count: AudioSpectrumFrame.binCount)
        }
        let frame = SystemAudioCaptureManager.broker.snapshot()
        return zip(frame.left, frame.right).map { (Double($0) + Double($1)) * 0.5 }
    }

    private func write(_ buffer: Buffer, left: [Float]?, right: [Float]?) {
        for band in 0..<buffer.bands {
            let l = Double(left?[band] ?? 0)
            let r = Double(right?[band] ?? 0)
            buffer.left.setValue(l, at: band)
            buffer.right.setValue(r, at: band)
            buffer.average.setValue((l + r) * 0.5, at: band)
        }
    }

    /// Pairwise max halving matching WPEMetalRuntimeUniforms.halve
    /// (scripts = shaders; see the L1 capture evidence cited there).
    private static func downsample(_ bins: [Float], to bands: Int) -> [Float] {
        var result = bins
        while result.count > bands, result.count >= 2 {
            var halved: [Float] = []
            halved.reserveCapacity(result.count / 2)
            var index = 0
            while index + 1 < result.count {
                halved.append(max(result[index], result[index + 1]))
                index += 2
            }
            result = halved
        }
        if result.count < bands {
            result += [Float](repeating: 0, count: bands - result.count)
        }
        return result
    }
}

/// Lane-owned logical-time scheduler for SceneScript timers. It deliberately
/// never creates a `Timer`/run-loop source: every mutation and callback stays on
/// the JSContext's serial execution lane and advances from the renderer's
/// monotonic `engine.runtime` value.
final class WPESceneScriptTimerScheduler {
    enum AdvanceResult: Equatable {
        case completed
        case callbackLimitExceeded
    }

    /// A finite catch-up limit keeps a large authored runtime jump from trapping
    /// the lane inside the scheduler. Hitting it is a scene fail-close, never a
    /// silent callback drop/defer.
    static let maximumCallbacksPerAdvance = 1_024

    private final class Entry {
        let handle: UInt64
        var deadline: Double
        let interval: Double
        let callback: JSValue
        let repeating: Bool
        var isCancelled = false

        init(
            handle: UInt64,
            deadline: Double,
            interval: Double,
            callback: JSValue,
            repeating: Bool
        ) {
            self.handle = handle
            self.deadline = deadline
            self.interval = interval
            self.callback = callback
            self.repeating = repeating
        }
    }

    private var heap: [Entry] = []
    private var entriesByHandle: [UInt64: Entry] = [:]
    private var nextHandle: UInt64 = 1
    private var currentRuntimeSeconds = 0.0
    private var isInvalidated = false

    var hasPendingTimers: Bool {
        !entriesByHandle.isEmpty
    }

    func install(in context: JSContext, engine: JSValue) {
        let timeout: @convention(block) (JSValue, JSValue) -> JSValue? = {
            [weak self, weak context] callback, delay in
            guard let self, let context else { return nil }
            return self.schedule(
                callback: callback,
                delay: delay,
                repeating: false,
                in: context
            )
        }
        let interval: @convention(block) (JSValue, JSValue) -> JSValue? = {
            [weak self, weak context] callback, delay in
            guard let self, let context else { return nil }
            return self.schedule(
                callback: callback,
                delay: delay,
                repeating: true,
                in: context
            )
        }
        let clear: @convention(block) (JSValue) -> Void = { value in
            guard value.isObject, value.hasProperty("call") else { return }
            _ = value.call(withArguments: [])
        }
        for (name, function) in [
            ("setTimeout", timeout as Any),
            ("setInterval", interval as Any),
            ("clearTimeout", clear as Any),
            ("clearInterval", clear as Any),
        ] {
            engine.setObject(function, forKeyedSubscript: name as NSString)
            context.setObject(function, forKeyedSubscript: name as NSString)
        }
    }

    func advance(
        to proposedRuntimeSeconds: Double,
        beforeEachCallback: () -> Void,
        callbackDidThrow: () -> Bool
    ) -> AdvanceResult {
        guard !isInvalidated, proposedRuntimeSeconds.isFinite else { return .completed }
        currentRuntimeSeconds = max(currentRuntimeSeconds, proposedRuntimeSeconds)
        var callbackCount = 0

        while let next = heap.first, next.deadline <= currentRuntimeSeconds {
            guard callbackCount < Self.maximumCallbacksPerAdvance else {
                invalidate()
                return .callbackLimitExceeded
            }
            let entry = removeMinimum()
            guard !entry.isCancelled else { continue }
            callbackCount += 1

            // Keep the entry addressable while its callback runs so handle()
            // self-cancellation and clearTimeout(handle) both tombstone it.
            beforeEachCallback()
            let result = entry.callback.call(withArguments: [])
            if result == nil || callbackDidThrow() {
                entry.isCancelled = true
            }
            if entry.isCancelled || !entry.repeating || entry.interval <= 0 {
                entriesByHandle.removeValue(forKey: entry.handle)
                continue
            }

            // Reschedule from the prior deadline, not from `now`, matching WPE's
            // bounded-drift catch-up semantics. Re-entrant schedules already sit
            // in the same heap and are considered by the next iteration.
            entry.deadline += entry.interval
            insert(entry)
        }
        return .completed
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        for entry in entriesByHandle.values { entry.isCancelled = true }
        heap.removeAll(keepingCapacity: false)
        entriesByHandle.removeAll(keepingCapacity: false)
    }

    private func schedule(
        callback: JSValue,
        delay: JSValue,
        repeating: Bool,
        in context: JSContext
    ) -> JSValue? {
        guard !isInvalidated, callback.isObject, callback.hasProperty("call") else {
            return JSValue(undefinedIn: context)
        }
        let milliseconds = delay.isUndefined ? 0 : delay.toDouble()
        let interval = milliseconds.isFinite ? milliseconds / 1_000 : 0
        let handle = nextHandle
        nextHandle &+= 1
        let entry = Entry(
            handle: handle,
            deadline: currentRuntimeSeconds + interval,
            interval: interval,
            callback: callback,
            repeating: repeating
        )
        entriesByHandle[handle] = entry
        insert(entry)

        let cancel: @convention(block) () -> Void = { [weak self] in
            self?.cancel(handle)
        }
        return JSValue(object: cancel, in: context)
    }

    private func cancel(_ handle: UInt64) {
        guard let entry = entriesByHandle.removeValue(forKey: handle) else { return }
        entry.isCancelled = true
    }

    private func orderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.deadline < rhs.deadline
            || (lhs.deadline == rhs.deadline && lhs.handle < rhs.handle)
    }

    private func insert(_ entry: Entry) {
        heap.append(entry)
        var index = heap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard orderedBefore(heap[index], heap[parent]) else { break }
            heap.swapAt(index, parent)
            index = parent
        }
    }

    private func removeMinimum() -> Entry {
        precondition(!heap.isEmpty)
        if heap.count == 1 { return heap.removeLast() }
        let result = heap[0]
        heap[0] = heap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var child = left
            if right < heap.count, orderedBefore(heap[right], heap[left]) {
                child = right
            }
            guard orderedBefore(heap[child], heap[index]) else { break }
            heap.swapAt(child, index)
            index = child
        }
        return result
    }
}

/// Per-property sandboxed SceneScript evaluator (engine/thisLayer/localstorage only).
/// Wall-clock budget on dedicated queue; timeout quarantines the engine (JSC has no kill).
/// Not `@MainActor` — ticked on the display render actor; outcome slot is thread-safe.
final class WPESceneScriptInstance {
    private let engineRelease: WPESceneScriptLaneRelease<Engine>
    private var engine: Engine { engineRelease.value }
    private let hasUpdateFunction: Bool
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    private(set) var lastValue: String
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<String?>()

    /// Budgets: setup covers the whole module body + `init()` (allow real
    /// work); per-frame `update()` is expected to be microseconds, so an
    /// overrun only ever means a runaway loop. Tests inject smaller values.
    init(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared,
        /// The scene's render size. `nil` leaves the sandbox's 1920x1080, which
        /// is only right for scenes that happen to be that size — every caller
        /// that knows the real canvas must pass it.
        canvasSize: SIMD2<Double>? = nil
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        let engine = Engine(
            shared: shared,
            governor: governor,
            batchDispatcher: batchDispatcher,
            canvasSize: canvasSize
        )
        self.engineRelease = WPESceneScriptLaneRelease(value: engine, queue: engine.queue)
        var prepared = Self.preprocess(script: script)
        // Normalize `let/const scriptProperties` → `var` only when injecting, so
        // the scene's overrides reach a reassignable global.
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        let setupResult = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            initialValue: initialValue,
            budget: setupBudget
        )
        switch setupResult {
        case .timedOut:
            shared?.sceneScriptLoadToken?.failClosed(.executionTimedOut(operation: .setup))
            isPoisoned = true
            Logger.warning(
                "SceneScript setup exceeded \(setupBudget)s — script disabled",
                category: .wpeRender
            )
            throw WPESceneScriptError.executionTimedOut
        case .capacityUnavailable:
            shared?.sceneScriptLoadToken?.failClosed(.capacityUnavailable(operation: .setup))
            isPoisoned = true
            throw WPESceneScriptError.capacityUnavailable(operation: .setup)
        case let .completed(outcome):
            switch outcome {
            case .contextUnavailable:
                throw WPESceneScriptError.contextUnavailable
            case let .ready(hasUpdate):
                self.hasUpdateFunction = hasUpdate
            }
        }
    }

    // MARK: Synchronous Oracle (DEBUG only)
    // Test-only bounded-blocking wrappers (production uses batchTick*/seedAsyncTick).
    #if DEBUG
    func tickString(
        runtimeSeconds: Double? = nil
    ) -> String {
        guard hasUpdateFunction, !isPoisoned,
              engine.allows(.tick) else { return lastValue }
        switch engine.tick(
            lastValue: lastValue,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "SceneScript update() exceeded \(tickBudget)s — script frozen at its last value",
                category: .wpeRender
            )
            return lastValue
        case .capacityUnavailable:
            return lastValue
        case let .completed(outcome):
            guard engine.acceptsCompletion() else { return lastValue }
            if let newValue = outcome {
                lastValue = newValue
            }
            return lastValue
        }
    }
    #endif

    /// Live editor update for a text-content script. The mutation and one
    /// `update(value)` evaluation run on the instance lane, then supersede any
    /// older in-flight frame result so a stale tick cannot restore old text.
    @discardableResult
    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> Bool {
        guard !isPoisoned, !properties.isEmpty,
              engine.allows(.userProperties) else { return false }
        let budget = tickBudget * 2
        switch engine.applyScriptProperties(
            properties,
            lastValue: lastValue,
            runtimeSeconds: runtimeSeconds,
            budget: budget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "SceneScript scriptProperties patch exceeded \(budget)s — frozen",
                category: .wpeRender
            )
            return false
        case .capacityUnavailable:
            return false
        case let .completed(outcome):
            guard engine.acceptsCompletion(), outcome.applied else { return false }
            let merged = asyncOutcomeSlot.supersede(with: outcome.value)
            if let merged { lastValue = merged }
            return true
        }
    }

    // MARK: Async Tick

    /// Load-path seeding: one bounded synchronous tick so the first frame shows
    /// the scripted value instead of popping the authored placeholder.
    func seedAsyncTick(runtimeSeconds: Double? = nil) {
        guard hasUpdateFunction, !isPoisoned,
              engine.allows(.tick) else { return }
        switch engine.tick(
            lastValue: lastValue,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "SceneScript update() exceeded \(tickBudget)s — script frozen at its last value",
                category: .wpeRender
            )
            return
        case .capacityUnavailable:
            return
        case let .completed(outcome):
            guard engine.acceptsCompletion() else { return }
            asyncOutcomeSlot.publishEvent(outcome)
        }
    }

    // MARK: Batch Tick

    /// Batch frame tick: present value + one worker job (nil if in-flight/poisoned).
    func batchTickString(
        runtimeSeconds: Double? = nil
    ) -> (value: String, job: WPESceneScriptBatchDispatcher.Job?) {
        guard hasUpdateFunction, !isPoisoned else { return (lastValue, nil) }
        if let overrun = engine.quarantineAsyncIfOverdue(budget: tickBudget) {
            isPoisoned = true
            Logger.warning(
                "SceneScript \(overrun.operation.rawValue) exceeded \(tickBudget)s — frozen at its last value",
                category: .wpeRender
            )
            return (lastValue, nil)
        }
        guard engine.allows(.tick) else { return (lastValue, nil) }
        if let fresh = asyncOutcomeSlot.takeLatest(), let newValue = fresh {
            lastValue = newValue
        }
        guard let claim = asyncOutcomeSlot.beginTick() else { return (lastValue, nil) }
        guard let work = engine.makeBatchTick(
            lastValue: lastValue,
            runtimeSeconds: runtimeSeconds,
            claim: claim,
            publishTo: asyncOutcomeSlot
        ) else {
            asyncOutcomeSlot.rejectTick(claim)
            return (lastValue, nil)
        }
        return (lastValue, WPESceneScriptBatchDispatcher.Job(queue: engine.queue, work: work))
    }

    /// Owns the JSContext and the only thread allowed to touch it. The class
    /// is `@unchecked Sendable` because `context`/`updateFunction` are only
    /// ever accessed on `queue`; callers exchange plain `String`s.
    private final class Engine: @unchecked Sendable, WPESceneScriptEngineExecutionGuarding {
        enum SetupOutcome {
            case ready(hasUpdate: Bool)
            case contextUnavailable
        }

        /// The engine's serial queue IS its batch worker, so "one context, one
        /// queue" holds while a frame's ticks cost one dispatch per worker.
        fileprivate var queue: DispatchQueue { executionLane.queue }
        fileprivate let executionLane: WPESceneScriptBatchDispatcher.Lane
        /// The lane's shared VM — every context this engine builds lives in it.
        private let virtualMachine: JSVirtualMachine
        private var context: JSContext?
        /// Rewrites every `registerAudioBuffers` array from the shared audio
        /// broker at the top of each tick; nil until `setUp` builds the context.
        private var audioBridge: WPESceneScriptAudioBridge?
        private var timerScheduler: WPESceneScriptTimerScheduler?
        private var updateFunction: JSValue?
        private var lastRuntimeSeconds: Double?
        private let shared: WPESharedScriptState?
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let participant: WPESceneScriptExecutionGovernor.Participant
        let instanceLimitToken: WPESceneScriptInstanceLimitToken?
        let asyncExecutionSafety = WPESceneScriptAsyncExecutionSafety()
        /// Latches after the first uncaught JS exception is logged, so a script
        /// that throws every tick surfaces once instead of spamming per frame.
        private var didLogException = false
        private var didThrow = false
        private var faultPolicy = WPEScriptFaultPolicy()
        /// Scene render size, or nil to leave the sandbox's 1920x1080.
        private let canvasSize: SIMD2<Double>?

        init(
            shared: WPESharedScriptState?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher,
            canvasSize: SIMD2<Double>?
        ) {
            self.canvasSize = canvasSize
            self.shared = shared
            self.governor = governor
            self.participant = governor.makeParticipant()
            self.instanceLimitToken = shared?.sceneScriptLoadToken
            let lane = batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialValue: String,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.setUpOnQueue(
                    script: script,
                    scriptProperties: scriptProperties,
                    initialValue: initialValue
                )
            }
        }

        func tick(
            lastValue: String,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<String?> {
            guard allows(.tick) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .tick, admission: .failFast) {
                self.tickOnQueue(lastValue: lastValue, runtimeSeconds: runtimeSeconds)
            }
        }

        func applyScriptProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            lastValue: String,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPEScriptPropertyPatchOutcome<String>> {
            guard allows(.userProperties) else { return .capacityUnavailable }
            return runWithBudget(
                budget,
                operation: .userProperties,
                admission: .waitUntilDeadline
            ) {
                guard wpePatchScriptProperties(properties, in: self.context) else {
                    return WPEScriptPropertyPatchOutcome(applied: false, value: nil)
                }
                return WPEScriptPropertyPatchOutcome(
                    applied: true,
                    value: self.tickOnQueue(
                        lastValue: lastValue,
                        runtimeSeconds: runtimeSeconds
                    )
                )
            }
        }

        /// Batch-mode work unit. No governor permit: concurrency is bounded by the
        /// dispatcher's worker count, and the work runs ON this engine's queue
        /// because in batch mode that queue IS its worker.
        func makeBatchTick(
            lastValue: String,
            runtimeSeconds: Double?,
            claim: WPESceneScriptOutcomeSlot<String?>.Claim,
            publishTo slot: WPESceneScriptOutcomeSlot<String?>
        ) -> (@Sendable () -> Void)? {
            guard allows(.tick) else { return nil }
            return { @Sendable [self] in
                // Reserve at run time (not job build) — pool caps running evals, not queued jobs.
                guard let safety = asyncExecutionSafety.begin(
                    sceneToken: instanceLimitToken,
                    operation: .tick
                ) else {
                    slot.rejectTick(claim)
                    return
                }
                defer { asyncExecutionSafety.complete(safety) }
                let outcome = tickOnQueue(
                    lastValue: lastValue,
                    runtimeSeconds: runtimeSeconds
                )
                guard acceptsCompletion() else {
                    slot.rejectTick(claim)
                    return
                }
                slot.publishTick(outcome, for: claim)
            }
        }

        /// Same contract as the layer engine's: both keys, or the sandbox's
        /// hardcoded 1920x1080 `screenResolution` survives and contradicts
        /// `canvasSize` in the same context.
        private func installCanvasSize(in context: JSContext) {
            guard let canvasSize,
                  let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
                  let size = JSValue(newObjectIn: context) else { return }
            size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
            size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
            engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
            engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
        }

        private func setUpOnQueue(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialValue: String
        ) -> SetupOutcome {
            guard let context = JSContext(virtualMachine: virtualMachine) else {
                return .contextUnavailable
            }
            self.context = context
            let timerScheduler = WPESceneScriptTimerScheduler()
            self.timerScheduler = timerScheduler
            audioBridge = WPESceneScriptInstance.installSandbox(
                in: context,
                userProperties: shared?.userProperties ?? [:],
                timerScheduler: timerScheduler
            )
            WPESceneScriptBaseclasses.install(in: context)
            installCanvasSize(in: context)
            _ = updateEngineRuntime(0)
            if let shared { wpeInstallSharedState(shared, in: context) }
            context.exceptionHandler = { [weak self] _, ex in
                guard let self else { return }
                self.didThrow = true
                guard !self.didLogException else { return }
                self.didLogException = true
                Logger.warning(
                    "Text SceneScript raised an uncaught JS exception — keeping last value; retries back off exponentially (logged once): \(ex?.toString() ?? "unknown")",
                    category: .wpeRender
                )
            }
            _ = context.evaluateScript(script)

            // Overlay the scene's per-object scriptProperty overrides onto the
            // script's declared defaults, so text renders with the scene's
            // configuration (e.g. dayFormat/showDay) instead of bare defaults.
            if !scriptProperties.isEmpty {
                wpeInstallScriptProperties(
                    overrides: scriptProperties,
                    declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                        context.objectForKeyedSubscript("scriptProperties")
                    ),
                    into: context
                )
            }

            let updateValue = context.objectForKeyedSubscript("update")
            if let updateValue, !updateValue.isUndefined, updateValue.hasProperty("call") {
                updateFunction = updateValue
            } else {
                updateFunction = nil
            }
            // WPE hands `init` the property's authored value; the audio-response
            // templates stash it as `initialValue` and multiply by it every frame,
            // so calling with no argument leaves them multiplying by `undefined`.
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                let seed = JSValue(object: initialValue, in: context) ?? JSValue(undefinedIn: context)!
                _ = initFn.call(withArguments: [seed as Any])
            }
            return .ready(hasUpdate: updateFunction != nil || timerScheduler.hasPendingTimers)
        }

        private func tickOnQueue(
            lastValue: String,
            runtimeSeconds: Double?
        ) -> String? {
            audioBridge?.refresh()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return nil }
            guard let context, let updateFunction else { return nil }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return nil }
            let arg = JSValue(object: lastValue, in: context) ?? JSValue(nullIn: context)!
            didThrow = false
            let result = updateFunction.call(withArguments: [arg as Any])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: "update", at: now)
                return nil
            }
            faultPolicy.recordSuccess(entryPoint: "update")
            guard let result, !result.isUndefined && !result.isNull else {
                return nil
            }
            if result.isString, let s = result.toString() {
                return s
            }
            if result.isNumber {
                return String(result.toDouble())
            }
            return nil
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) -> Double? {
            guard let context else { return nil }
            let supplied = runtimeSeconds.flatMap { $0.isFinite ? $0 : nil }
            let runtime = max(lastRuntimeSeconds ?? 0, supplied ?? lastRuntimeSeconds ?? 0)
            let frameTime = lastRuntimeSeconds.map { max(runtime - $0, 0) } ?? 0
            lastRuntimeSeconds = runtime
            wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
            return supplied == nil ? nil : runtime
        }

        private func advanceTimers(to runtimeSeconds: Double?) -> Bool {
            guard let runtimeSeconds, let timerScheduler else { return true }
            guard timerScheduler.advance(
                to: runtimeSeconds,
                beforeEachCallback: { self.didThrow = false },
                callbackDidThrow: { self.didThrow }
            ) == .completed else {
                instanceLimitToken?.failClosed(.timerCallbackLimitExceeded(
                    limit: WPESceneScriptTimerScheduler.maximumCallbacksPerAdvance
                ))
                return false
            }
            return true
        }

        deinit {
            timerScheduler?.invalidate()
        }

    }

    /// Strip `export` keywords, ESM `import` lines and `'use strict'` so the script body evaluates as flat top-level declarations the JSContext can look up by name.
    /// `nonisolated`: also called by `WPETransformScriptEvaluator` off the main actor.
    ///
    /// The import strip belongs HERE, not at the call sites: it used to be
    /// duplicated at two of the four `preprocess` callers, and the text-script
    /// caller was one of the two without it — so scene 3713073223's typewriter
    /// scripts died on their opening `import * as WEMath from 'WEMath';`.
    nonisolated static func preprocess(script: String) -> String {
        var s = script
        // WPE serializes some exported scripts with non-breaking spaces between
        // keywords (`export function`), which JavaScriptCore will not match via
        // the ASCII-space replacements below.
        for space in ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{FEFF}"] {
            s = s.replacingOccurrences(of: space, with: " ")
        }
        s = s.replacingOccurrences(of: "'use strict';", with: "")
        s = s.replacingOccurrences(of: "\"use strict\";", with: "")
        s = s.replacingOccurrences(of: "export function", with: "function")
        s = s.replacingOccurrences(of: "export var", with: "var")
        s = s.replacingOccurrences(of: "export let", with: "let")
        s = s.replacingOccurrences(of: "export const", with: "const")
        // A top-level `import` is a SyntaxError in JSContext's non-module eval,
        // and one SyntaxError aborts the whole body — no update(), no init().
        // The modules scripts import (`WEMath`) are installed as globals by
        // `installSandbox`, so dropping the line is enough.
        s = s.replacingOccurrences(
            of: #"(?m)^[\t ]*import\b[^\n]*$"#,
            with: "",
            options: .regularExpression
        )
        return s
    }

    /// Install a minimal global API surface mirroring the subset of SceneScript that scripts in the corpus actually use.
    /// `nonisolated`: runs on the engine's worker queue (or the parser's evaluator), never on the MainActor.
    /// Returns the audio bridge the caller must `refresh()` before each tick.
    @discardableResult
    nonisolated static func installSandbox(
        in context: JSContext,
        userProperties: [String: WPESceneScriptPropertyValue] = [:],
        timerScheduler: WPESceneScriptTimerScheduler? = nil
    ) -> WPESceneScriptAudioBridge {
        let console = JSValue(newObjectIn: context)!
        let log: @convention(block) (JSValue) -> Void = { _ in }
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        context.setObject(
            WPESceneScriptContextBeacon(),
            forKeyedSubscript: "__contextBeacon" as NSString
        )

        let engine = JSValue(newObjectIn: context)!
        let getTimeOfDay: @convention(block) () -> Double = {
            // Oracle freezes wall-clock so `engine.getTimeOfDay()` (day-fraction
            // clock scripts) can't drift the trace across a minute boundary.
            let date = WPEOracleMode.isEnabled ? WPEOracleMode.frozenWallClock : Date()
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute, .second], from: date)
            let secs = Double((comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0))
            return secs / 86_400.0
        }
        engine.setObject(getTimeOfDay, forKeyedSubscript: "getTimeOfDay" as NSString)
        // engine.timeOfDay property form (legacy getTimeOfDay exists); refreshed each tick.
        engine.setObject(getTimeOfDay(), forKeyedSubscript: "timeOfDay" as NSString)
        // Project-level user properties, as WPE exposes them. The object must
        // exist even when empty — `engine.userProperties.foo` on `undefined`
        // throws out of update(). Leaving it permanently empty is not harmless
        // either: 3151551777's day/night driver reads
        // `engine.userProperties.timeofday`, and an absent key sent it down the
        // `else { value = 0 }` branch every frame, i.e. permanent daytime.
        //
        // This is a DIFFERENT API from the `applyUserProperties(props)` event
        // (see `applyScriptUserProperties`) — a scene may use either or both.
        let userPropertyObject = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
        for (key, value) in userProperties {
            switch value {
            case let .bool(flag):
                userPropertyObject.setObject(flag, forKeyedSubscript: key as NSString)
            case let .number(number):
                userPropertyObject.setObject(number, forKeyedSubscript: key as NSString)
            case let .string(text):
                userPropertyObject.setObject(text, forKeyedSubscript: key as NSString)
            }
        }
        engine.setObject(userPropertyObject, forKeyedSubscript: "userProperties" as NSString)
        if let timerScheduler {
            timerScheduler.install(in: context, engine: engine)
        } else {
            // Static one-shot evaluators have no frame/runtime source. Preserve
            // the callable contract without retaining callbacks that can never
            // be advanced; live engines always supply a real scheduler.
            let scheduleNever: @convention(block) (JSValue, JSValue) -> JSValue? = {
                [weak context] _, _ in
                guard let context else { return nil }
                let cancel: @convention(block) () -> Void = {}
                return JSValue(object: cancel, in: context)
            }
            let clearNever: @convention(block) (JSValue) -> Void = { _ in }
            engine.setObject(scheduleNever, forKeyedSubscript: "setTimeout" as NSString)
            engine.setObject(scheduleNever, forKeyedSubscript: "setInterval" as NSString)
            engine.setObject(clearNever, forKeyedSubscript: "clearTimeout" as NSString)
            engine.setObject(clearNever, forKeyedSubscript: "clearInterval" as NSString)
            context.setObject(scheduleNever, forKeyedSubscript: "setTimeout" as NSString)
            context.setObject(scheduleNever, forKeyedSubscript: "setInterval" as NSString)
            context.setObject(clearNever, forKeyedSubscript: "clearTimeout" as NSString)
            context.setObject(clearNever, forKeyedSubscript: "clearInterval" as NSString)
        }
        let getProperty: @convention(block) (String) -> JSValue? = { [weak context] _ in
            context.flatMap { JSValue(undefinedIn: $0) }
        }
        let setProperty: @convention(block) (String, JSValue) -> Void = { _, _ in }
        engine.setObject(getProperty, forKeyedSubscript: "getPropertyValue" as NSString)
        engine.setObject(setProperty, forKeyedSubscript: "setPropertyValue" as NSString)
        let audioBridge = WPESceneScriptAudioBridge()
        audioBridge.install(in: engine, context: context)
        // openURL stub must exist (undefined call throws out of cursorClick mid-handler).
        let openUserShortcut: @convention(block) (String) -> Bool = { _ in false }
        engine.setObject(openUserShortcut, forKeyedSubscript: "openUserShortcut" as NSString)
        // We are never the WPE editor, so this one has an unambiguously correct
        // answer — and 3 corpus instances threw on it, which discards the rest of
        // their update() with it.
        let isRunningInEditor: @convention(block) () -> Bool = { false }
        engine.setObject(isRunningInEditor, forKeyedSubscript: "isRunningInEditor" as NSString)
        // Wallpaper, never the screensaver host — same unambiguous answer.
        let isScreensaver: @convention(block) () -> Bool = { false }
        engine.setObject(isScreensaver, forKeyedSubscript: "isScreensaver" as NSString)
        let screenResolution = JSValue(newObjectIn: context)!
        screenResolution.setObject(1920.0, forKeyedSubscript: "x" as NSString)
        screenResolution.setObject(1080.0, forKeyedSubscript: "y" as NSString)
        engine.setObject(screenResolution, forKeyedSubscript: "screenResolution" as NSString)
        engine.setObject(screenResolution, forKeyedSubscript: "canvasSize" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)

        let input = JSValue(newObjectIn: context)!
        let cursorScreen = JSValue(newObjectIn: context)!
        cursorScreen.setObject(960.0, forKeyedSubscript: "x" as NSString)
        cursorScreen.setObject(540.0, forKeyedSubscript: "y" as NSString)
        input.setObject(cursorScreen, forKeyedSubscript: "cursorScreenPosition" as NSString)
        input.setObject(cursorScreen, forKeyedSubscript: "cursorWorldPosition" as NSString)
        context.setObject(input, forKeyedSubscript: "input" as NSString)

        let storage = JSValue(newObjectIn: context)!
        let storageBacking = NSMutableDictionary()
        let storageGet: @convention(block) (String) -> JSValue? = { [weak context] key in
            guard let context else { return nil }
            return storageBacking[key].flatMap { JSValue(object: $0, in: context) }
                ?? JSValue(undefinedIn: context)
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, value in
            if value.isString {
                storageBacking[key] = value.toString() ?? ""
            } else if value.isNumber {
                storageBacking[key] = value.toDouble()
            } else if value.isBoolean {
                storageBacking[key] = value.toBool()
            } else {
                storageBacking[key] = value.toObject() ?? NSNull()
            }
        }
        // `ILocalStorage`: get/set/delete/clear, each taking an optional location.
        // We keep one per-scene backing regardless of location — nothing here
        // persists across launches yet, so GLOBAL and SCREEN are the same store.
        let storageDelete: @convention(block) (String) -> Bool = { key in
            let existed = storageBacking[key] != nil
            storageBacking.removeObject(forKey: key)
            return existed
        }
        let storageClear: @convention(block) () -> Void = { storageBacking.removeAllObjects() }
        storage.setObject(storageGet, forKeyedSubscript: "get" as NSString)
        storage.setObject(storageSet, forKeyedSubscript: "set" as NSString)
        storage.setObject(storageDelete, forKeyedSubscript: "delete" as NSString)
        storage.setObject(storageClear, forKeyedSubscript: "clear" as NSString)
        storage.setObject("global", forKeyedSubscript: "LOCATION_GLOBAL" as NSString)
        storage.setObject("screen", forKeyedSubscript: "LOCATION_SCREEN" as NSString)
        // `localStorage` is the documented global; our lowercase `localstorage` was
        // a guess, and the corpus bears that out (11 scenes camelCase vs 1). The
        // lowercase alias stays so the one scene using it keeps working.
        context.setObject(storage, forKeyedSubscript: "localStorage" as NSString)
        context.setObject(storage, forKeyedSubscript: "localstorage" as NSString)

        let createScriptProperties: @convention(block) () -> JSValue? = { [weak context] in
            guard let context, let proxy = JSValue(newObjectIn: context) else {
                return nil
            }
            // add* exposes default value on scriptProperties; use currentThis (not capture) to avoid ~1.15MB JSC retain cycle.
            let register: @convention(block) (JSValue) -> JSValue? = { config in
                guard let proxy = JSContext.currentThis(), proxy.isObject else { return nil }
                guard config.isObject,
                      let nameValue = config.objectForKeyedSubscript("name"),
                      nameValue.isString, let name = nameValue.toString(), !name.isEmpty else {
                    return proxy
                }
                // Explicit default (addCheckbox/addText/addSlider/addColor).
                if let value = config.objectForKeyedSubscript("value"), !value.isUndefined {
                    proxy.setObject(value, forKeyedSubscript: name as NSString)
                    return proxy
                }
                // addCombo has no top-level value — default to options[0].value like WPE.
                if let options = config.objectForKeyedSubscript("options"), options.isArray,
                   let first = options.atIndex(0), first.isObject,
                   let optionValue = first.objectForKeyedSubscript("value"), !optionValue.isUndefined {
                    proxy.setObject(optionValue, forKeyedSubscript: name as NSString)
                }
                return proxy
            }
            for name in ["addCheckbox", "addText", "addSlider", "addColor",
                         "addCombo", "addFile", "addUserShortcut", "addGroup", "finish"] {
                proxy.setObject(register, forKeyedSubscript: name as NSString)
            }
            return proxy
        }
        context.setObject(createScriptProperties, forKeyedSubscript: "createScriptProperties" as NSString)

        // WEMath shim after import strip (smoothStep/mix + clamp/saturate).
        if let weMath = JSValue(newObjectIn: context) {
            let mix: @convention(block) (Double, Double, Double) -> Double = { a, b, t in a + (b - a) * t }
            // WPE: "Remaps value based on min and max into [0, 1] range." Plain
            // GLSL smoothstep, so a DESCENDING pair (min > max) still yields the
            // falling ramp the time-of-day scripts build their windows from.
            let smoothStep: @convention(block) (Double, Double, Double) -> Double = { lo, hi, value in
                guard hi != lo else { return value < lo ? 0 : 1 }
                let t = Swift.min(Swift.max((value - lo) / (hi - lo), 0), 1)
                return t * t * (3 - 2 * t)
            }
            let clampFn: @convention(block) (Double, Double, Double) -> Double = { x, lo, hi in Swift.min(Swift.max(x, lo), hi) }
            let saturate: @convention(block) (Double) -> Double = { Swift.min(Swift.max($0, 0), 1) }
            weMath.setObject(mix, forKeyedSubscript: "mix" as NSString)
            weMath.setObject(mix, forKeyedSubscript: "lerp" as NSString)
            weMath.setObject(smoothStep, forKeyedSubscript: "smoothStep" as NSString)
            weMath.setObject(clampFn, forKeyedSubscript: "clamp" as NSString)
            weMath.setObject(saturate, forKeyedSubscript: "saturate" as NSString)
            weMath.setObject(Double.pi / 180, forKeyedSubscript: "deg2rad" as NSString)
            weMath.setObject(180 / Double.pi, forKeyedSubscript: "rad2deg" as NSString)
            context.setObject(weMath, forKeyedSubscript: "WEMath" as NSString)
        }

        // Oracle-only: virtual Date.now (+1ms/call) + seeded Math.random for deterministic content.
        if WPEOracleMode.isEnabled {
            let frozenMillis = Int(WPEOracleMode.frozenWallClockMillis)
            context.evaluateScript("""
            ;(function(){var R=Date,F=\(frozenMillis),n=0;\
            function now(){return F+(n++);}\
            function D(){if(arguments.length===0)return new R(now());\
            return new (Function.prototype.bind.apply(R,[null].concat([].slice.call(arguments))))();}\
            D.prototype=R.prototype;D.now=now;D.parse=R.parse;D.UTC=R.UTC;Date=D;\
            var s=0x9e3779b9>>>0;Math.random=function(){s=(s+0x6D2B79F5)|0;\
            var t=Math.imul(s^(s>>>15),1|s);t=(t+Math.imul(t^(t>>>7),61|t))^t;\
            return((t^(t>>>14))>>>0)/4294967296;};})();
            """)
        }
        return audioBridge
    }
}

enum WPESceneScriptError: Error, Equatable {
    case contextUnavailable
    /// No process-wide execution permit was available, so setup was not
    /// dispatched and no JavaScriptCore worker/context was touched.
    case capacityUnavailable(operation: WPESceneScriptOperation)
    /// The script exceeded its wall-clock execution budget (runaway loop);
    /// the instance was disabled before it could hang the render thread.
    case executionTimedOut
    /// The module body raised an uncaught exception at evaluation, so no usable
    /// `update()` was declared. The caller drops the instance and keeps the
    /// baked transform (same visual result as an inert instance, but logged).
    case scriptEvaluationFailed
}

extension WPESceneScriptPropertyValue {
    var jsBridged: Any {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value
        case .string(let value): return value
        }
    }

    /// Re-type a scene override to match what the script DECLARED the property as.
    ///
    /// scene.json carries no types, so the parser has to guess, and it reads a
    /// numeric-looking string as a number — 387 of the corpus's 828 string-valued
    /// scriptproperties. That is silently lossy in one direction only: JS coerces
    /// a string to a number for arithmetic (`"0.5" * 1920`), but a Number has no
    /// `.trim()`, so `.addText` properties like 3460973721's `delayTime: "0.2"`
    /// threw every tick. `createScriptProperties()` is the type authority.
    func matchingType(of declared: WPESceneScriptPropertyValue?) -> WPESceneScriptPropertyValue {
        guard let declared else { return self }
        switch (declared, self) {
        case (.string, .number(let value)):
            // Combo option values are authored "1"/"2"/"3"; keep them integral so
            // a `=== '3'` comparison still matches.
            let isIntegral = value == value.rounded() && abs(value) < 1e15
            return .string(isIntegral ? String(Int(value)) : String(value))
        case (.string, .bool(let value)):
            return .string(value ? "true" : "false")
        case (.number, .string(let value)):
            return Double(value).map { .number($0) } ?? self
        case (.bool, .number(let value)):
            return .bool(value != 0)
        case (.bool, .string(let value)):
            return .bool(value == "true" || value == "1")
        default:
            return self
        }
    }
}

// MARK: - Shared cross-script state (`shared` global)

/// Host-owned lock-guarded `shared` store; per-context proxies exchange detached copies.
/// One scene layer as SceneScript sees it: the name scripts address it by, its
/// authored size in scene pixels, and its z-order position.
struct WPESceneScriptLayerInfo: Sendable {
    let id: String
    let name: String
    let size: SIMD2<Double>
    let origin: SIMD2<Double>
    let originZ: Double
    let scale: SIMD3<Double>
    /// Radians in renderer/schema space. The JS bridge exposes degrees.
    let angles: SIMD3<Double>
    let index: Int
    /// Name of this layer's parent, so `getParent()` can hand back the real
    /// handle (with a real `origin`) instead of a neutral stub.
    let parentName: String?

    init(
        id: String,
        name: String,
        size: SIMD2<Double>,
        origin: SIMD2<Double>,
        originZ: Double = 0,
        scale: SIMD3<Double> = SIMD3<Double>(repeating: 1),
        angles: SIMD3<Double> = .zero,
        index: Int,
        parentName: String?
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.origin = origin
        self.originZ = originZ
        self.scale = scale
        self.angles = angles
        self.index = index
        self.parentName = parentName
    }
}

final class WPESharedScriptState: @unchecked Sendable {
    let sceneScriptLoadToken: WPESceneScriptInstanceLimitToken?
    /// Resolved project user properties, for `engine.userProperties.<key>`.
    /// Carried here because this is the one object every script engine in a
    /// scene already receives. Immutable after construction, hence no locking.
    let userProperties: [String: WPESceneScriptPropertyValue]
    /// Scene layer table in document order, for `thisLayer.size`,
    /// `thisScene.getLayerIndex(l)` and `thisScene.enumerateLayers()`. Same
    /// reasoning as `userProperties`: every engine already gets this object,
    /// and it is immutable after construction.
    let layers: [WPESceneScriptLayerInfo]
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    private var liveLayerTransformsByID: [String: LiveLayerTransform] = [:]

    struct LiveLayerTransform: Sendable {
        var origin: SIMD3<Double>?
        var scale: SIMD3<Double>?
        var angles: SIMD3<Double>?
    }

    init(
        sceneScriptLoadToken: WPESceneScriptInstanceLimitToken? = nil,
        userProperties: [String: WPESceneScriptPropertyValue] = [:],
        layers: [WPESceneScriptLayerInfo] = []
    ) {
        self.sceneScriptLoadToken = sceneScriptLoadToken
        self.userProperties = userProperties
        self.layers = layers
    }

    func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    /// `ISoundLayer` calls, drained once per frame by the renderer. Bounded so a
    /// script looping `play()` can't grow this without limit between frames.
    private var pendingSoundCommands: [(layer: String, command: WPELayerSoundCommand)] = []

    func enqueueSoundCommand(layer: String, _ command: WPELayerSoundCommand) {
        lock.lock(); defer { lock.unlock() }
        guard pendingSoundCommands.count < 256 else { return }
        pendingSoundCommands.append((layer, command))
    }

    func drainSoundCommands() -> [(layer: String, command: WPELayerSoundCommand)] {
        lock.lock(); defer { lock.unlock() }
        defer { pendingSoundCommands.removeAll(keepingCapacity: true) }
        return pendingSoundCommands
    }

    func set(_ key: String, _ value: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard sceneScriptLoadToken?.acceptsCompletion() ?? true else { return }
        if storage[key] == nil,
           sceneScriptLoadToken?.admitNewSharedStateEntry() == false {
            return
        }
        storage[key] = value ?? NSNull()
    }

    /// Publishes a detached render-state snapshot for script lanes. JavaScriptCore
    /// contexts run on worker queues, so they must never reach into the renderer's
    /// actor-owned dictionaries directly. Missing fields deliberately fall back
    /// to authored layer-table values in `layerTransform(named:)`.
    func publishLayerTransforms(
        origins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>]
    ) {
        var snapshot: [String: LiveLayerTransform] = [:]
        snapshot.reserveCapacity(origins.count + scales.count + angles.count)
        for (id, value) in origins { snapshot[id, default: .init()].origin = value }
        for (id, value) in scales { snapshot[id, default: .init()].scale = value }
        for (id, value) in angles { snapshot[id, default: .init()].angles = value }
        lock.lock()
        liveLayerTransformsByID = snapshot
        lock.unlock()
    }

    func layerTransform(named name: String) -> (info: WPESceneScriptLayerInfo, transform: LiveLayerTransform)? {
        guard let info = layers.first(where: { $0.name == name }) else { return nil }
        lock.lock()
        let live = liveLayerTransformsByID[info.id] ?? LiveLayerTransform()
        lock.unlock()
        return (info, live)
    }
}

private func wpeBridgeJSValueToHost(_ value: JSValue) -> Any? {
    if value.isBoolean { return value.toBool() }
    if value.isNumber { return value.toDouble() }
    if value.isString { return value.toString() }
    if value.isNull || value.isUndefined { return nil }
    return value.toObject()
}

/// Day fraction [0,1]; frozen under oracle mode for byte-identical captures.
private func wpeDayFraction() -> Double {
    if WPEOracleMode.isEnabled {
        if let replay = WPEOracleMode.loadFrameOverride() {
            return min(max(replay.daytime, 0), 1)
        }
        return wpeDayFraction(of: WPEOracleMode.frozenWallClock)
    }
    return wpeDayFraction(of: Date())
}

private func wpeDayFraction(of date: Date) -> Double {
    let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    let seconds = Double((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
    return seconds / 86_400.0
}

/// Per-tick engine clock, shared by all script families so `runtime` /
/// `frametime` / `timeOfDay` can't drift apart between them.
func wpeRefreshEngineClock(
    in context: JSContext?,
    runtime: Double,
    frameTime: Double
) {
    guard let engine = context?.objectForKeyedSubscript("engine"), !engine.isUndefined else { return }
    engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
    engine.setObject(frameTime, forKeyedSubscript: "frametime" as NSString)
    engine.setObject(wpeDayFraction(), forKeyedSubscript: "timeOfDay" as NSString)
}

/// Install cross-context `shared` proxy (container mutations write root back to host).
func wpeInstallSharedState(_ store: WPESharedScriptState, in context: JSContext) {
    let get: @convention(block) (String) -> Any? = { store.get($0) }
    let set: @convention(block) (String, JSValue) -> Void = { key, value in
        store.set(key, wpeBridgeJSValueToHost(value))
    }
    context.setObject(get, forKeyedSubscript: "__sharedGet" as NSString)
    context.setObject(set, forKeyedSubscript: "__sharedSet" as NSString)
    _ = context.evaluateScript("""
    var __sharedMutators = {
        push: 1, pop: 1, shift: 1, unshift: 1, splice: 1, sort: 1, reverse: 1,
        fill: 1, copyWithin: 1, add: 1, clear: 1, delete: 1, set: 1
    };
    function __sharedWrap(rootKey, root, node) {
        if (node === null || typeof node !== 'object') { return node; }
        return new Proxy(node, {
            get: function(t, p) {
                var v = t[p];
                // Symbol-keyed access (Symbol.iterator → spread/for-of) must stay
                // raw: wrapping the iterator protocol breaks it for no benefit,
                // since iteration itself never mutates.
                if (typeof p === 'symbol') {
                    return (typeof v === 'function') ? v.bind(t) : v;
                }
                if (typeof v === 'function') {
                    return function() {
                        var res = v.apply(t, arguments);
                        if (__sharedMutators[p] === 1) { __sharedSet(rootKey, root); }
                        return __sharedWrap(rootKey, root, res);
                    };
                }
                return __sharedWrap(rootKey, root, v);
            },
            set: function(t, p, v) { t[p] = v; __sharedSet(rootKey, root); return true; },
            deleteProperty: function(t, p) { delete t[p]; __sharedSet(rootKey, root); return true; }
        });
    }
    // Functions and class instances cannot survive the host round trip: the
    // bridge keeps own properties only, so a stored dispatcher comes back as a
    // plain object and `shared.eventDispatcher.registerEvent(...)` throws. Each
    // context therefore keeps the ORIGINAL for values it wrote itself.
    // Deliberately NOT a general write cache — plain data must keep going through
    // the host, or a producer would read back its own stale value instead of a
    // peer's (that path is how day/night cycles talk).
    var __sharedLive = {};
    function __sharedNeedsLive(v) {
        if (typeof v === 'function') { return true; }
        if (v === null || typeof v !== 'object' || Array.isArray(v)) { return false; }
        // A class instance: its methods live on a prototype the bridge drops.
        return Object.getPrototypeOf(v) !== Object.prototype;
    }
    var shared = new Proxy({}, {
        get: function(_t, k) {
            if (Object.prototype.hasOwnProperty.call(__sharedLive, k)) { return __sharedLive[k]; }
            var v = __sharedGet(k);
            return (v !== null && typeof v === 'object') ? __sharedWrap(k, v, v) : v;
        },
        set: function(_t, k, v) {
            if (__sharedNeedsLive(v)) { __sharedLive[k] = v; } else { delete __sharedLive[k]; }
            __sharedSet(k, v);
            return true;
        },
        has: function(_t, k) {
            return Object.prototype.hasOwnProperty.call(__sharedLive, k) || __sharedGet(k) !== undefined;
        }
    });
    """)
}

// MARK: - Shared scriptProperties injection (transform + text-content scripts)

struct WPEScriptPropertyPatchOutcome<Value> {
    let applied: Bool
    let value: Value?
}

/// Mutates only the addressed entries on the JS engine's owning lane. The
/// object itself is retained so authored references to `scriptProperties`
/// remain valid; replacing the global would break closures that captured it.
func wpePatchScriptProperties(
    _ properties: [String: WPESceneScriptPropertyValue],
    in context: JSContext?
) -> Bool {
    guard !properties.isEmpty,
          let context,
          let bag = context.objectForKeyedSubscript("scriptProperties"),
          !bag.isUndefined, !bag.isNull, bag.isObject else {
        return false
    }
    let currentTypes = wpeDeclaredScriptPropertyDefaults(bag)
    for (name, value) in properties {
        let typed = value.matchingType(of: currentTypes[name])
        bag.setObject(typed.jsBridged, forKeyedSubscript: name as NSString)
    }
    return true
}

/// Force let/const scriptProperties → var so Swift can read/replace the global.
func wpeNormalizeScriptPropertiesDeclaration(_ preprocessed: String) -> String {
    preprocessed
        .replacingOccurrences(of: "let scriptProperties", with: "var scriptProperties")
        .replacingOccurrences(of: "const scriptProperties", with: "var scriptProperties")
}

/// Snapshot a script's declared scriptProperty defaults (from its
/// `createScriptProperties()` object) so an injection can rebuild from them.
func wpeDeclaredScriptPropertyDefaults(
    _ value: JSValue?
) -> [String: WPESceneScriptPropertyValue] {
    guard let dict = value?.toDictionary() as? [String: Any] else { return [:] }
    var defaults: [String: WPESceneScriptPropertyValue] = [:]
    for (name, raw) in dict {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                defaults[name] = .bool(number.boolValue)
            } else if number.doubleValue.isFinite {
                defaults[name] = .number(number.doubleValue)
            }
        } else if let string = raw as? String {
            defaults[name] = .string(string)
        }
    }
    return defaults
}

/// Fresh scriptProperties = defaults + scene overrides (no prior-object binding leak).
func wpeInstallScriptProperties(
    overrides: [String: WPESceneScriptPropertyValue],
    declaredDefaults: [String: WPESceneScriptPropertyValue],
    into context: JSContext
) {
    guard let scriptProperties = JSValue(newObjectIn: context) else { return }
    for (name, value) in declaredDefaults {
        scriptProperties.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
    }
    for (name, value) in overrides {
        let typed = value.matchingType(of: declaredDefaults[name])
        scriptProperties.setObject(typed.jsBridged, forKeyedSubscript: name as NSString)
    }
    context.setObject(scriptProperties, forKeyedSubscript: "scriptProperties" as NSString)
}

/// Static transform resolve under time/context limits; falls back to baked values.
/// `@unchecked Sendable`: JSContext/JSValue only touched on queue; poison is lock-guarded.
final class WPETransformScriptEvaluator: @unchecked Sendable {
    private let canvasSize: SIMD2<Double>
    private let evaluationBudget: TimeInterval
    private let governor: WPESceneScriptExecutionGovernor
    private let participant: WPESceneScriptExecutionGovernor.Participant
    private let queue = DispatchQueue(
        label: "com.livewallpaper.wpe-transform-evaluator",
        qos: .userInitiated
    )
    /// One VM for all `maxCachedContexts` contexts: they only ever run on the
    /// single serial `queue` above, so the shared VM lock is uncontended.
    private let virtualMachine: JSVirtualMachine = JSVirtualMachine()
    private var contextsBySource: [String: CachedContext] = [:]
    /// Set by each context's exception handler; reset around eval/update so a
    /// throwing script is rejected (nil → caller keeps the baked value) instead
    /// of returning a half-mutated input object.
    private let exception = ExceptionFlag()
    /// Guards `poisoned` so the `@unchecked Sendable` claim holds even if a future
    /// caller invokes `resolveVec3` off more than one thread.
    private let poisonLock = NSLock()
    /// Flipped after a single evaluation overruns its budget; the hung worker
    /// still owns `queue`, so every later call must short-circuit to the baked value.
    private var poisoned = false

    /// Upper bound on distinct script contexts built per document. Real scenes
    /// reuse one source across all scripted objects; this only guards pathological
    /// inputs. Beyond it, objects keep their baked value (no crash, no blowup).
    private static let maxCachedContexts = 64

    private final class ExceptionFlag { var didThrow = false }
    private final class ResultBox: @unchecked Sendable { var value: SIMD3<Double>? }

    /// Cached context + declared defaults; each eval rebuilds fresh scriptProperties.
    private struct CachedContext {
        let context: JSContext
        let declaredDefaults: [String: WPESceneScriptPropertyValue]
    }

    private var isPoisoned: Bool {
        poisonLock.lock(); defer { poisonLock.unlock() }
        return poisoned
    }

    private func poison() {
        poisonLock.lock(); poisoned = true; poisonLock.unlock()
    }

    /// evaluationBudget covers cold bootstrap + update(); matches instance tick budget.
    init(
        canvasWidth: Double,
        canvasHeight: Double,
        evaluationBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor = .processShared
    ) {
        self.canvasSize = SIMD2<Double>(canvasWidth, canvasHeight)
        self.evaluationBudget = evaluationBudget
        self.governor = governor
        self.participant = governor.makeParticipant()
    }

    // No deinit teardown on purpose. `virtualMachine` is this evaluator's own
    // property, so the whole GC heap dies with it and the cached contexts are
    // reclaimed deterministically — unlike the batch lanes, which share a VM
    // that outlives any one engine. Touching `contextsBySource` or collecting
    // that VM from deinit would also break the queue contract below: a worker
    // that overran its budget still owns `queue` and may be executing JS on
    // this very VM (see `poisoned`), and deinit runs on whatever thread
    // released the last reference.

    /// Log unresolved origins in Release — shared authored seeds pile onto one point.
    /// thisLayer/thisScene scripts still belong here (dynamic path also has stubs only).
    static func reportKeptBakedOrigins(count: Int, reason: String) {
        Logger.warning(
            "Static transform scripts unresolved (\(reason)) — \(count) object(s) keep their baked origin; scripted layout will be wrong",
            category: .wpeRender
        )
    }

    /// Heuristics live with the package parser so bake-time and runtime agree.
    static func isStaticallyResolvable(_ script: String) -> Bool {
        WPETransformScriptStaticAnalysis.isStaticallyResolvable(script)
    }

    /// Script vec3 or nil (dynamic/fail/timeout/busy); seed passes through untouched components.
    func resolveVec3(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) -> SIMD3<Double>? {
        resolveBatch([
            WPESceneTransformScriptRequest(
                script: script,
                properties: properties,
                seed: seed
            )
        ]).first ?? nil
    }

    /// In-process static origins.
    ///
    /// Must stay an override: `resolveVec3` above delegates *to* this, while the protocol's
    /// default `resolveBatch` (`WPESceneDocumentParser.swift`) delegates the other way, to
    /// `resolveVec3`. Deleting this as "redundant" closes that loop into infinite recursion.
    func resolveBatch(
        _ requests: [WPESceneTransformScriptRequest]
    ) -> [SIMD3<Double>?] {
        guard !isPoisoned, !requests.isEmpty else {
            return Array(repeating: nil, count: requests.count)
        }
        var reasonCounts: [UnresolvedReason: Int] = [:]
        let outputs = requests.map { request -> SIMD3<Double>? in
            guard Self.isStaticallyResolvable(request.script) else { return nil }
            var reason: UnresolvedReason?
            let value = resolveVec3InProcess(
                script: request.script,
                properties: request.properties,
                seed: request.seed,
                reason: &reason
            )
            if value == nil { reasonCounts[reason ?? .scriptReturnedNothing, default: 0] += 1 }
            return value
        }
        let unresolved = reasonCounts.values.reduce(0, +)
        if unresolved > 0 {
            Self.reportKeptBakedOrigins(
                count: unresolved,
                reason: reasonCounts
                    .sorted { $0.value > $1.value }
                    .map { "\($0.key.rawValue) x\($0.value)" }
                    .joined(separator: "; ")
            )
        }
        return outputs
    }

    /// Why a static origin kept its baked value. The three used to be reported as
    /// one "failed, refused capacity, or overran" string, which said nothing about
    /// which knob to turn.
    enum UnresolvedReason: String {
        case poisonedOrNotStatic = "engine poisoned or script not statically resolvable"
        case safetyReservationRefused = "execution-safety reservation refused"
        case governorCapacityRefused = "governor refused capacity before the deadline"
        case deadlineAlreadyPassed = "budget already spent before evaluation started"
        case evaluationTimedOut = "evaluation overran its budget (engine quarantined)"
        case scriptReturnedNothing = "script threw or returned no usable vec3"
    }

    private func resolveVec3InProcess(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>,
        reason: inout UnresolvedReason?
    ) -> SIMD3<Double>? {
        guard !isPoisoned, Self.isStaticallyResolvable(script) else {
            reason = .poisonedOrNotStatic
            return nil
        }
        let deadline = DispatchTime.now() + max(evaluationBudget, 0)
        guard let safety = WPESceneScriptExecutionSafetyReservation.reserve(
            sceneToken: nil
        ) else {
            reason = .safetyReservationRefused
            return nil
        }
        guard let permit = governor.acquire(for: participant, until: deadline) else {
            safety.complete()
            reason = .governorCapacityRefused
            return nil
        }
        guard DispatchTime.now() < deadline else {
            safety.complete()
            permit.release()
            reason = .deadlineAlreadyPassed
            return nil
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            defer {
                safety.complete()
                permit.release()
                done.signal()
            }
            box.value = evaluateOnQueue(script: script, properties: properties, seed: seed)
        }
        guard done.wait(timeout: deadline) == .success else {
            // Runaway script: the worker is still spinning on `queue`. Stop using
            // it so the parse completes; the rest of the scene keeps baked values.
            _ = safety.quarantine(self, operation: .staticTransform)
            poison()
            reason = .evaluationTimedOut
            return nil
        }
        if box.value == nil { reason = .scriptReturnedNothing }
        return box.value
    }

    private func evaluateOnQueue(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) -> SIMD3<Double>? {
        guard let cached = context(for: script) else { return nil }
        let context = cached.context

        // Rebuild a fresh `scriptProperties` from this object's bindings each call.
        exception.didThrow = false
        wpeInstallScriptProperties(
            overrides: properties,
            declaredDefaults: cached.declaredDefaults,
            into: context
        )
        guard !exception.didThrow else { return nil }

        guard let update = context.objectForKeyedSubscript("update"),
              !update.isUndefined, update.hasProperty("call"),
              let valueObject = JSValue(newObjectIn: context) else { return nil }
        valueObject.setObject(seed.x, forKeyedSubscript: "x" as NSString)
        valueObject.setObject(seed.y, forKeyedSubscript: "y" as NSString)
        valueObject.setObject(seed.z, forKeyedSubscript: "z" as NSString)

        exception.didThrow = false
        guard let result = update.call(withArguments: [valueObject]),
              !exception.didThrow,
              !result.isUndefined, !result.isNull, result.isObject,
              let xValue = result.objectForKeyedSubscript("x"),
              let yValue = result.objectForKeyedSubscript("y") else {
            return nil
        }
        let x = xValue.toDouble()
        let y = yValue.toDouble()
        guard x.isFinite, y.isFinite else { return nil }
        let z = result.objectForKeyedSubscript("z")?.toDouble() ?? seed.z
        return SIMD3<Double>(x, y, z.isFinite ? z : seed.z)
    }

    /// Builds (or returns a cached) context for `source`. MUST run on `queue`.
    private func context(for source: String) -> CachedContext? {
        if let cached = contextsBySource[source] { return cached }
        guard contextsBySource.count < Self.maxCachedContexts,
              let context = JSContext(virtualMachine: virtualMachine) else { return nil }
        WPESceneScriptInstance.installSandbox(in: context)
        WPESceneScriptBaseclasses.install(in: context)
        installCanvasSize(in: context)
        // Install the handler only after bootstrap so it tracks the user script's
        // own exceptions, not any (ignored) noise from the sandbox/base classes.
        context.exceptionHandler = { [exception] _, _ in exception.didThrow = true }
        exception.didThrow = false
        let prepared = wpeNormalizeScriptPropertiesDeclaration(
            WPESceneScriptInstance.preprocess(script: source)
        )
        _ = context.evaluateScript(prepared)
        // A module body that throws at setup never declares a usable update().
        guard !exception.didThrow else { return nil }
        let cached = CachedContext(
            context: context,
            declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                context.objectForKeyedSubscript("scriptProperties")
            )
        )
        contextsBySource[source] = cached
        return cached
    }

    private func installCanvasSize(in context: JSContext) {
        guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
              let size = JSValue(newObjectIn: context) else { return }
        size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
        size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
        engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
        // Both, or the sandbox's hardcoded 1920x1080 `screenResolution` survives and
        // contradicts `canvasSize` in the same context. (WPE treats the two as separate
        // inputs — screen vs canvas — but every engine here equates them; see U-13.)
        engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
    }
}

/// Dynamic transform update(value) evaluator (narrower than full SceneScript).
final class WPEDynamicTransformScriptInstance: @unchecked Sendable {
    private let engineRelease: WPESceneScriptLaneRelease<Engine>
    private var engine: Engine { engineRelease.value }
    private let tickBudget: TimeInterval
    private var lastValue: SIMD3<Double>
    private var isPoisoned = false
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<SIMD3<Double>?>()
    /// Latest completed inner result: nil mirrors the legacy "script returned no
    /// value this tick" contract (caller falls back to the baked transform).
    private var lastAsyncInner: SIMD3<Double>?
    private var hasAsyncOutcome = false
    /// The arity WPE authored for the bound property. Vec3 is the transform
    /// default; shader constants are usually scalars.
    private let valueShape: WPEScriptValueShape

    /// Narrows a ticked Vec3 back to that arity, so a scalar uniform gets a
    /// Number rather than a 3-component vector the shader would misread.
    func constantValue(_ value: SIMD3<Double>) -> WPESceneShaderConstantValue {
        switch valueShape {
        case .scalar, .boolean: return .number(value.x)
        case .vector2: return .vector([value.x, value.y])
        case .vector3: return .vector([value.x, value.y, value.z])
        }
    }


    init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>,
        valueShape: WPEScriptValueShape = .vector3,
        canvasSize: SIMD2<Double>,
        ownLayerName: String? = nil,
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared
    ) throws {
        self.tickBudget = tickBudget
        self.valueShape = valueShape
        self.lastValue = seed
        let engine = Engine(
            seed: seed,
            valueShape: valueShape,
            canvasSize: canvasSize,
            ownLayerName: ownLayerName,
            shared: shared,
            governor: governor,
            batchDispatcher: batchDispatcher
        )
        self.engineRelease = WPESceneScriptLaneRelease(value: engine, queue: engine.queue)
        var prepared = WPESceneScriptInstance.preprocess(script: script)
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        let setupResult = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            budget: setupBudget
        )
        switch setupResult {
        case .timedOut:
            // `runWithBudget`'s queued closure strongly retains Engine until it
            // returns (or forever if JSC never returns), so throwing here cannot
            // deinitialize a context still executing on its serial queue.
            isPoisoned = true
            shared?.sceneScriptLoadToken?.failClosed(.executionTimedOut(operation: .setup))
            throw WPESceneScriptError.executionTimedOut
        case .capacityUnavailable:
            isPoisoned = true
            shared?.sceneScriptLoadToken?.failClosed(.capacityUnavailable(operation: .setup))
            throw WPESceneScriptError.capacityUnavailable(operation: .setup)
        case let .completed(outcome):
            switch outcome {
            case .contextUnavailable:
                throw WPESceneScriptError.contextUnavailable
            case .setupFailed:
                throw WPESceneScriptError.scriptEvaluationFailed
            case .ready:
                break
            }
        }
    }


    // MARK: Synchronous Oracle (DEBUG only)
    // Test-only bounded-blocking wrappers (production uses batchTick*/seedAsyncTick).
    #if DEBUG
    func tick(
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> SIMD3<Double>? {
        guard !isPoisoned, !engine.hasRuntimeFault, engine.allows(.tick) else { return nil }
        switch engine.tick(
            currentValue: lastValue,
            pointerPosition: pointerPosition,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            return nil
        case .capacityUnavailable:
            return lastValue
        case let .completed(result):
            guard engine.acceptsCompletion() else { return nil }
            if let result {
                lastValue = result
            }
            return result
        }
    }
    #endif

    /// Live editor update for transform/color/effect script properties. The
    /// patched bag and one evaluation share the same lane turn; a stale frame
    /// result is superseded before the renderer observes it.
    @discardableResult
    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> Bool {
        guard !isPoisoned, !engine.hasRuntimeFault, !properties.isEmpty,
              engine.allows(.userProperties) else { return false }
        let budget = tickBudget * 2
        switch engine.applyScriptProperties(
            properties,
            currentValue: lastValue,
            pointerPosition: pointerPosition,
            runtimeSeconds: runtimeSeconds,
            budget: budget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "Transform SceneScript scriptProperties patch exceeded \(budget)s — frozen",
                category: .wpeRender
            )
            return false
        case .capacityUnavailable:
            return false
        case let .completed(outcome):
            guard engine.acceptsCompletion(), outcome.applied else { return false }
            let merged = asyncOutcomeSlot.supersede(with: outcome.value)
            hasAsyncOutcome = true
            lastAsyncInner = merged
            if let merged { lastValue = merged }
            return true
        }
    }

    // MARK: Async Tick

    /// Load-path seeding: one bounded synchronous tick so the first frame uses
    /// the scripted transform instead of popping from the baked value.
    func seedAsyncTick(pointerPosition: SIMD2<Double>, runtimeSeconds: Double? = nil) {
        guard !isPoisoned, !engine.hasRuntimeFault, engine.allows(.tick) else { return }
        switch engine.tick(
            currentValue: lastValue,
            pointerPosition: pointerPosition,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            return
        case .capacityUnavailable:
            return
        case let .completed(outcome):
            guard engine.acceptsCompletion() else { return }
            asyncOutcomeSlot.publishEvent(outcome)
        }
    }

    /// Frame-path tick, batch mode. Same keep-last contract as `liveTick`; the
    /// pointer fast lane has no analogue here because batching cannot starve a
    /// script — every one of them is submitted every frame.
    func batchTick(
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> (value: SIMD3<Double>?, job: WPESceneScriptBatchDispatcher.Job?) {
        guard !isPoisoned, !engine.hasRuntimeFault else { return (nil, nil) }
        if let overrun = engine.quarantineAsyncIfOverdue(budget: tickBudget) {
            isPoisoned = true
            Logger.warning(
                "Transform SceneScript \(overrun.operation.rawValue) exceeded \(tickBudget)s — frozen",
                category: .wpeRender
            )
            return (nil, nil)
        }
        guard engine.allows(.tick) else { return (nil, nil) }
        if let fresh = asyncOutcomeSlot.takeLatest() {
            hasAsyncOutcome = true
            lastAsyncInner = fresh
            if let fresh {
                lastValue = fresh
            }
        }
        var job: WPESceneScriptBatchDispatcher.Job?
        if let claim = asyncOutcomeSlot.beginTick() {
            if let work = engine.makeBatchTick(
                currentValue: lastValue,
                pointerPosition: pointerPosition,
                runtimeSeconds: runtimeSeconds,
                claim: claim,
                publishTo: asyncOutcomeSlot
            ) {
                job = WPESceneScriptBatchDispatcher.Job(queue: engine.queue, work: work)
            } else {
                asyncOutcomeSlot.rejectTick(claim)
            }
        }
        guard hasAsyncOutcome else { return (nil, job) }
        return (lastAsyncInner == nil ? nil : lastValue, job)
    }

    private final class Engine: @unchecked Sendable, WPESceneScriptEngineExecutionGuarding {
        enum SetupOutcome {
            case ready
            case contextUnavailable
            case setupFailed
        }

        /// The engine's serial queue IS its batch worker, so "one context, one
        /// queue" holds while a frame's ticks cost one dispatch per worker.
        fileprivate var queue: DispatchQueue { executionLane.queue }
        fileprivate let executionLane: WPESceneScriptBatchDispatcher.Lane
        /// The lane's shared VM — every context this engine builds lives in it.
        private let virtualMachine: JSVirtualMachine
        private let seed: SIMD3<Double>
        private let valueShape: WPEScriptValueShape
        private let canvasSize: SIMD2<Double>
        private let ownLayerName: String?
        private let shared: WPESharedScriptState?
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let participant: WPESceneScriptExecutionGovernor.Participant
        let instanceLimitToken: WPESceneScriptInstanceLimitToken?
        let asyncExecutionSafety = WPESceneScriptAsyncExecutionSafety()
        private var context: JSContext?
        /// Rewrites every `registerAudioBuffers` array from the shared audio
        /// broker at the top of each tick; nil until `setUp` builds the context.
        private var audioBridge: WPESceneScriptAudioBridge?
        private var timerScheduler: WPESceneScriptTimerScheduler?
        private var updateFunction: JSValue?
        private var cursorWorldPosition: JSValue?
        private var layerHandles: [String: JSValue] = [:]
        private var neutralLayerHandle: JSValue?
        private var lastRuntimeSeconds: Double?
        private var didThrow = false
        /// Repeated update() exceptions back off through the shared policy so
        /// JSC reporting cannot thrash every tick.
        private var faultPolicy = WPEScriptFaultPolicy()
        /// Set on hard quarantine so callers can stop scheduling without a queue hop.
        private let runtimeFault = OSAllocatedUnfairLock(initialState: false)
        var hasRuntimeFault: Bool { runtimeFault.withLock { $0 } }

        init(
            seed: SIMD3<Double>,
            valueShape: WPEScriptValueShape,
            canvasSize: SIMD2<Double>,
            ownLayerName: String?,
            shared: WPESharedScriptState?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher
        ) {
            let lane = batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
            self.seed = seed
            self.valueShape = valueShape
            self.canvasSize = canvasSize
            self.ownLayerName = ownLayerName
            self.shared = shared
            self.governor = governor
            self.participant = governor.makeParticipant()
            self.instanceLimitToken = shared?.sceneScriptLoadToken
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.setUpOnQueue(script: script, scriptProperties: scriptProperties)
            }
        }

        func tick(
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<SIMD3<Double>?> {
            guard allows(.tick) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .tick, admission: .failFast) {
                self.tickOnQueue(
                    currentValue: currentValue,
                    pointerPosition: pointerPosition,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }

        func applyScriptProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPEScriptPropertyPatchOutcome<SIMD3<Double>>> {
            guard allows(.userProperties) else { return .capacityUnavailable }
            return runWithBudget(
                budget,
                operation: .userProperties,
                admission: .waitUntilDeadline
            ) {
                guard wpePatchScriptProperties(properties, in: self.context) else {
                    return WPEScriptPropertyPatchOutcome(applied: false, value: nil)
                }
                return WPEScriptPropertyPatchOutcome(
                    applied: true,
                    value: self.tickOnQueue(
                        currentValue: currentValue,
                        pointerPosition: pointerPosition,
                        runtimeSeconds: runtimeSeconds
                    )
                )
            }
        }

        /// Batch work unit: no governor permit (worker count bounds concurrency); reserve inside closure.
        func makeBatchTick(
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?,
            claim: WPESceneScriptOutcomeSlot<SIMD3<Double>?>.Claim,
            publishTo slot: WPESceneScriptOutcomeSlot<SIMD3<Double>?>
        ) -> (@Sendable () -> Void)? {
            guard allows(.tick) else { return nil }
            return { @Sendable [self] in
                guard let safety = asyncExecutionSafety.begin(
                    sceneToken: instanceLimitToken,
                    operation: .tick
                ) else {
                    slot.rejectTick(claim)
                    return
                }
                defer { asyncExecutionSafety.complete(safety) }
                let outcome = tickOnQueue(
                    currentValue: currentValue,
                    pointerPosition: pointerPosition,
                    runtimeSeconds: runtimeSeconds
                )
                guard acceptsCompletion() else {
                    slot.rejectTick(claim)
                    return
                }
                slot.publishTick(outcome, for: claim)
            }
        }

        private func setUpOnQueue(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue]
        ) -> SetupOutcome {
            guard let context = JSContext(virtualMachine: virtualMachine) else { return .contextUnavailable }
            self.context = context
            let timerScheduler = WPESceneScriptTimerScheduler()
            self.timerScheduler = timerScheduler
            audioBridge = WPESceneScriptInstance.installSandbox(
                in: context,
                userProperties: shared?.userProperties ?? [:],
                timerScheduler: timerScheduler
            )
            WPESceneScriptBaseclasses.install(in: context)
            installCanvasSize(in: context)
            installInput(in: context)
            installLayerBridge(in: context)
            _ = updateEngineRuntime(0)
            if let shared { wpeInstallSharedState(shared, in: context) }
            context.exceptionHandler = { [weak self] _, _ in self?.didThrow = true }

            didThrow = false
            _ = context.evaluateScript(script)
            // A module body that throws at eval never declares a usable update();
            // report failure so the caller logs and keeps the baked transform,
            // rather than installing a permanently inert instance.
            guard !didThrow else { return .setupFailed }

            if !scriptProperties.isEmpty {
                wpeInstallScriptProperties(
                    overrides: scriptProperties,
                    declaredDefaults: wpeDeclaredScriptPropertyDefaults(
                        context.objectForKeyedSubscript("scriptProperties")
                    ),
                    into: context
                )
            }
            let update = context.objectForKeyedSubscript("update")
            if let update, !update.isUndefined, update.hasProperty("call") {
                updateFunction = update
            }
            // Call init with authored value — without it audio templates leave initialValue undefined → NaN.
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                _ = initFn.call(withArguments: [jsValue(for: seed, in: context) as Any])
            }
            return .ready
        }

        /// The argument shape WPE gives `init`/`update`: a bare Number for a scalar
        /// property (an effect's shader constant), a Vec2/Vec3 otherwise.
        private func jsValue(for value: SIMD3<Double>, in context: JSContext) -> JSValue? {
            switch valueShape {
            case .boolean:
                return JSValue(bool: value.x > 0.5, in: context)
            case .scalar:
                return JSValue(double: value.x, in: context)
            case .vector2, .vector3:
                guard let object = JSValue(newObjectIn: context) else { return nil }
                object.setObject(value.x, forKeyedSubscript: "x" as NSString)
                object.setObject(value.y, forKeyedSubscript: "y" as NSString)
                if valueShape == .vector3 {
                    object.setObject(value.z, forKeyedSubscript: "z" as NSString)
                }
                return object
            }
        }

        private func tickOnQueue(
            currentValue: SIMD3<Double>,
            pointerPosition: SIMD2<Double>,
            runtimeSeconds: Double?
        ) -> SIMD3<Double>? {
            guard let context else { return nil }
            audioBridge?.refresh()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return nil }
            guard let updateFunction else { return nil }
            // Renderer pointer UV is top-left; WPE cursorWorldPosition is Y-up canvas space.
            cursorWorldPosition?.setObject(pointerPosition.x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorWorldPosition?.setObject((1.0 - pointerPosition.y) * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(seed.z, forKeyedSubscript: "z" as NSString)

            didThrow = false
            guard let argument = jsValue(for: currentValue, in: context) else { return nil }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return nil }
            let result = updateFunction.call(withArguments: [argument])
            if didThrow {
                let verdict = faultPolicy.recordFailure(entryPoint: "update", at: now)
                if verdict == .quarantined {
                    // Release the JS callable on its owning queue and stop
                    // scheduling this broken transform until scene reload.
                    self.updateFunction = nil
                    runtimeFault.withLock { $0 = true }
                }
                return nil
            }
            faultPolicy.recordSuccess(entryPoint: "update")
            guard let result,
                  !result.isUndefined, !result.isNull else {
                return nil
            }
            // A visibility gate's `update()` returns the BOOLEAN it was handed
            // (`value = shared.shownight`). JSC reports a boolean as neither
            // number nor object, so without this it reads as "no value".
            if result.isBoolean {
                return SIMD3<Double>(repeating: result.toBool() ? 1 : 0)
            }
            if result.isNumber {
                let scalar = result.toDouble()
                return scalar.isFinite ? SIMD3<Double>(scalar, scalar, scalar) : nil
            }
            guard result.isObject,
                  let xValue = result.objectForKeyedSubscript("x"),
                  let yValue = result.objectForKeyedSubscript("y") else {
                return nil
            }
            let x = xValue.toDouble()
            let y = yValue.toDouble()
            guard x.isFinite, y.isFinite else { return nil }
            let z = result.objectForKeyedSubscript("z")?.toDouble() ?? currentValue.z
            return SIMD3<Double>(x, y, z.isFinite ? z : currentValue.z)
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) -> Double? {
            guard let context else { return nil }
            let runtime: Double
            if let runtimeSeconds, runtimeSeconds.isFinite {
                runtime = max(lastRuntimeSeconds ?? 0, runtimeSeconds)
            } else {
                runtime = (lastRuntimeSeconds ?? 0) + 1.0 / 30.0
            }
            let frameTime: Double
            if let previous = lastRuntimeSeconds {
                frameTime = max(runtime - previous, 0)
            } else {
                frameTime = 1.0 / 30.0
            }
            lastRuntimeSeconds = runtime
            wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
            return runtimeSeconds?.isFinite == true ? runtime : nil
        }

        private func advanceTimers(to runtimeSeconds: Double?) -> Bool {
            guard let runtimeSeconds, let timerScheduler else { return true }
            guard timerScheduler.advance(
                to: runtimeSeconds,
                beforeEachCallback: { self.didThrow = false },
                callbackDidThrow: { self.didThrow }
            ) == .completed else {
                instanceLimitToken?.failClosed(.timerCallbackLimitExceeded(
                    limit: WPESceneScriptTimerScheduler.maximumCallbacksPerAdvance
                ))
                return false
            }
            return true
        }

        deinit {
            timerScheduler?.invalidate()
        }

        private func installCanvasSize(in context: JSContext) {
            guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
                  let size = JSValue(newObjectIn: context) else { return }
            size.setObject(canvasSize.x, forKeyedSubscript: "x" as NSString)
            size.setObject(canvasSize.y, forKeyedSubscript: "y" as NSString)
            engine.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
            engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
        }

        private func installInput(in context: JSContext) {
            let input = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let cursor = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            cursor.setObject(seed.x, forKeyedSubscript: "x" as NSString)
            cursor.setObject(seed.y, forKeyedSubscript: "y" as NSString)
            cursor.setObject(seed.z, forKeyedSubscript: "z" as NSString)
            input.setObject(cursor, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorWorldPosition = cursor
        }

        /// Read-only graph bridge for transform scripts. It is intentionally
        /// narrower than `WPELayerScriptInstance`'s mutation journal: transform
        /// bindings return their field value, but still need real layer identity,
        /// parent traversal and live origin/scale reads during init/update.
        private func installLayerBridge(in context: JSContext) {
            guard let ownLayerName, !ownLayerName.isEmpty else { return }
            let own = layerHandle(named: ownLayerName, in: context)
            context.setObject(own, forKeyedSubscript: "thisLayer" as NSString)
            context.setObject(own, forKeyedSubscript: "thisObject" as NSString)

            let scene = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let getLayer: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] value in
                guard let self, let context, value.isString,
                      let name = value.toString(), !name.isEmpty else { return nil }
                return self.layerHandle(named: name, in: context)
            }
            scene.setObject(getLayer, forKeyedSubscript: "getLayer" as NSString)
            context.setObject(scene, forKeyedSubscript: "thisScene" as NSString)
            context.setObject(scene, forKeyedSubscript: "scene" as NSString)
        }

        private func layerHandle(named name: String, in context: JSContext) -> JSValue {
            if let existing = layerHandles[name] { return existing }
            guard let layer = shared?.layerTransform(named: name) else {
                return neutralLayer(in: context)
            }
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            handle.setObject(name, forKeyedSubscript: "name" as NSString)
            handle.setObject(Self.vector(
                SIMD3<Double>(layer.info.size.x, layer.info.size.y, 0),
                in: context
            ), forKeyedSubscript: "size" as NSString)
            installLiveVectorAccessor("origin", on: handle, in: context) { [weak self] in
                let current = self?.shared?.layerTransform(named: name)
                return current?.transform.origin ?? SIMD3<Double>(
                    current?.info.origin.x ?? 0,
                    current?.info.origin.y ?? 0,
                    current?.info.originZ ?? 0
                )
            }
            installLiveVectorAccessor("scale", on: handle, in: context) { [weak self] in
                let current = self?.shared?.layerTransform(named: name)
                return current?.transform.scale ?? current?.info.scale ?? SIMD3<Double>(repeating: 1)
            }
            installLiveVectorAccessor("angles", on: handle, in: context) { [weak self] in
                let current = self?.shared?.layerTransform(named: name)
                return (current?.transform.angles ?? current?.info.angles ?? .zero) * (180 / .pi)
            }
            let parentName = layer.info.parentName
            let getParent: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self, let context, let parentName else { return self?.neutralLayerHandle }
                return self.layerHandle(named: parentName, in: context)
            }
            handle.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            let getTransformMatrix: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self, let context else { return nil }
                let current = self.shared?.layerTransform(named: name)
                let origin = current?.transform.origin ?? SIMD3<Double>(
                    current?.info.origin.x ?? 0,
                    current?.info.origin.y ?? 0,
                    current?.info.originZ ?? 0
                )
                let scale = current?.transform.scale ?? current?.info.scale ?? SIMD3<Double>(repeating: 1)
                let matrix: [Double] = [
                    scale.x, 0, 0, 0,
                    0, scale.y, 0, 0,
                    0, 0, scale.z, 0,
                    origin.x, origin.y, origin.z, 1,
                ]
                let result = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
                result.setObject(matrix, forKeyedSubscript: "m" as NSString)
                return result
            }
            handle.setObject(getTransformMatrix, forKeyedSubscript: "getTransformMatrix" as NSString)
            layerHandles[name] = handle
            _ = neutralLayer(in: context)
            return handle
        }

        private func installLiveVectorAccessor(
            _ property: String,
            on handle: JSValue,
            in context: JSContext,
            value: @escaping () -> SIMD3<Double>
        ) {
            let get: @convention(block) () -> JSValue? = { [weak context] in
                guard let context else { return nil }
                return Self.vector(value(), in: context)
            }
            guard let object = context.objectForKeyedSubscript("Object"),
                  let define = object.objectForKeyedSubscript("defineProperty"),
                  let descriptor = JSValue(newObjectIn: context) else { return }
            descriptor.setObject(get, forKeyedSubscript: "get" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "enumerable" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "configurable" as NSString)
            define.call(withArguments: [handle, property, descriptor])
        }

        private func neutralLayer(in context: JSContext) -> JSValue {
            if let neutralLayerHandle { return neutralLayerHandle }
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            handle.setObject(Self.vector(.zero, in: context), forKeyedSubscript: "origin" as NSString)
            handle.setObject(Self.vector(.zero, in: context), forKeyedSubscript: "size" as NSString)
            handle.setObject(Self.vector(SIMD3<Double>(repeating: 1), in: context), forKeyedSubscript: "scale" as NSString)
            let getParent: @convention(block) () -> JSValue? = { [weak self] in self?.neutralLayerHandle }
            handle.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            neutralLayerHandle = handle
            return handle
        }

        private static func vector(_ value: SIMD3<Double>, in context: JSContext) -> JSValue {
            let result = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            result.setObject(value.x, forKeyedSubscript: "x" as NSString)
            result.setObject(value.y, forKeyedSubscript: "y" as NSString)
            result.setObject(value.z, forKeyedSubscript: "z" as NSString)
            return result
        }

    }
}
#endif
