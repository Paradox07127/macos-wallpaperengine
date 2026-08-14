#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

/// Shared admission + async-overrun quarantine for scene/layer/transform engines.
private protocol WPESceneScriptEngineExecutionGuarding: AnyObject {
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
        let laneOwnedValue = value
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
private final class WPESceneScriptAudioBridge {
    /// WPE AUDIO_RESOLUTION_* constants (broker width = largest).
    private static let resolutions = [16, 32, 64]

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
            self?.buffers.append(
                Buffer(bands: bands, average: average, left: left, right: right)
            )
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
fileprivate final class WPESceneScriptTimerScheduler {
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
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        let engine = Engine(shared: shared, governor: governor, batchDispatcher: batchDispatcher)
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

        init(
            shared: WPESharedScriptState?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher
        ) {
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
            _ = updateEngineRuntime(0)
            if let shared { wpeInstallSharedState(shared, in: context) }
            context.exceptionHandler = { [weak self] _, ex in
                guard let self else { return }
                self.didThrow = true
                guard !self.didLogException else { return }
                self.didLogException = true
                Logger.warning(
                    "Text SceneScript raised an uncaught JS exception — keeping last value; update() retries each tick (logged once): \(ex?.toString() ?? "unknown")",
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
            let arg = JSValue(object: lastValue, in: context) ?? JSValue(nullIn: context)!
            guard let result = updateFunction.call(withArguments: [arg as Any]),
                  !result.isUndefined && !result.isNull else {
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
    nonisolated fileprivate static func preprocess(script: String) -> String {
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
    nonisolated fileprivate static func installSandbox(
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

// MARK: - Layer SceneScript (visible-script video intros)

/// One `ISoundLayer` call a script made on a sound layer, addressed by layer name.
/// Sound is scene-scoped rather than per-render-layer, so these travel through
/// `WPESharedScriptState` instead of `WPELayerScriptState` like video does.
enum WPELayerSoundCommand: Sendable, Equatable {
    case play
    case stop
    case pause
    case setVolume(Double)
}

/// One playback command a layer script issued via `thisLayer.getVideoTexture()`.
enum WPELayerVideoCommand: Sendable, Equatable {
    case play
    case pause
    case stop
    case seek(TimeInterval)
}

/// Scalar vs Vec2/Vec3 shape for property init/update (wrong shape is a silent undefined).
enum WPEScriptValueShape: Sendable {
    case scalar
    case vector2
    case vector3
    /// Effect-visibility gates: `update(value)` is handed — and returns — a
    /// JS boolean, not a Number. Carried as 0/1 through the shared Vec3 engine.
    case boolean
}

/// Explicit transform assignments made through a layer SceneScript's
/// `thisLayer`. Nil means the script has never assigned that field, so the
/// renderer must continue using the authored/keyframed value for that field.
/// Angles stay in the JavaScript API's degree domain until the renderer merges
/// them into its radian geometry.
struct WPELayerScriptTransformMutation: Sendable, Equatable {
    var origin: SIMD3<Double>? = nil
    var scale: SIMD3<Double>? = nil
    var angles: SIMD3<Double>? = nil

    var isEmpty: Bool {
        origin == nil && scale == nil && angles == nil
    }

    mutating func merge(_ newer: Self) {
        if let origin = newer.origin { self.origin = origin }
        if let scale = newer.scale { self.scale = scale }
        if let angles = newer.angles { self.angles = angles }
    }
}

/// Layer script tick result (visible/alpha + video commands). Value type for queue→MainActor.
struct WPELayerScriptState: Sendable, Equatable {
    var visible: Bool
    var alpha: Double
    var videoCommands: [WPELayerVideoCommand]
    /// Whether the script EXPLICITLY assigned this field. A layer it merely READ
    /// (`if (getLayer(x).visible)`) must not be driven, else the handle's default
    /// `visible=true` clobbers the layer's real state. Own/created states apply both.
    var visibleAssigned: Bool = true
    var alphaAssigned: Bool = true
}

/// Runtime state for a layer created by `thisScene.createLayer(...)`.
/// These handles are authored dynamically by SceneScript, so they are surfaced
/// separately from graph-backed `thisLayer` / `getLayer(name)` state.
struct WPECreatedLayerScriptState: Sendable, Equatable {
    var key: String
    var imagePath: String
    var origin: SIMD3<Double>
    var color: SIMD3<Double>
    var scale: SIMD3<Double>
    var alpha: Double
    var visible: Bool
}

/// A layer script's full output for one run: state for its own layer (`thisLayer`)
/// plus state for any other layers it reached via `thisScene.getLayer(name)`
/// (keyed by layer name). The renderer resolves the names to objectIDs.
struct WPELayerScriptOutput: Sendable, Equatable {
    var own: WPELayerScriptState
    var others: [String: WPELayerScriptState]
    var created: [WPECreatedLayerScriptState] = []
    var ownTransform: WPELayerScriptTransformMutation = .init()
    /// Transforms a script assigned to *other* layers through
    /// `thisScene.getLayer(name)`, keyed by scene layer name like `others`.
    var otherTransforms: [String: WPELayerScriptTransformMutation] = [:]
}

enum WPELayerScriptOutputMode: Sendable, Equatable {
    case layerState
    case returnedAlpha(initialValue: Double)
}

enum WPELayerScriptCursorEvent: Sendable, Equatable {
    case move
    case down
    case up
    case click
    case rightDown
    case rightUp
    /// Hover transitions, dispatched per-layer from renderer hit-testing (the
    /// pointer entered/left THIS layer's screen rect) — unlike down/up which
    /// broadcast. 3509243656's star tooltips fade in on `cursorEnter`.
    case enter
    case leave

    var handlerName: String {
        switch self {
        case .move: return "cursorMove"
        case .down: return "cursorDown"
        case .up: return "cursorUp"
        case .click: return "cursorClick"
        case .rightDown: return "cursorRightDown"
        case .rightUp: return "cursorRightUp"
        case .enter: return "cursorEnter"
        case .leave: return "cursorLeave"
        }
    }
}

/// Typed cursor-hit payload for the SceneScript event bridge. The renderer
/// does not populate it until hit ordering is captured on Windows; preserving
/// the IR first avoids baking a guessed overlap policy into dispatch.
struct WPELayerScriptCursorHit: Sendable, Equatable {
    var worldPosition: SIMD3<Double>?
    var localPosition: SIMD3<Double>?
    var hitBox: String?

    init(
        worldPosition: SIMD3<Double>? = nil,
        localPosition: SIMD3<Double>? = nil,
        hitBox: String? = nil
    ) {
        self.worldPosition = worldPosition
        self.localPosition = localPosition
        self.hitBox = hitBox
    }
}

/// Layer SceneScript: reads thisLayer mutations + video commands (not a returned string).
/// Same queue+budget quarantine model as text instances. Not `@MainActor`.
final class WPELayerScriptInstance {
    private let engineRelease: WPESceneScriptLaneRelease<LayerEngine>
    private var engine: LayerEngine { engineRelease.value }
    private let hasUpdateFunction: Bool
    /// Whether the authored module exports `applyUserProperties`. Scene settings
    /// are broadcast only to handlers that can consume them; avoiding a bounded
    /// synchronous queue round-trip for every other layer is important in scenes
    /// with many property-driven scripts.
    let handlesUserProperties: Bool
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    let initialOutput: WPELayerScriptOutput
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<WPELayerScriptOutput>(
        combine: { WPELayerScriptInstance.mergedOutputs(pending: $0, newer: $1) }
    )

    init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        canvasSize: SIMD2<Double> = SIMD2<Double>(1920, 1080),
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        nowProviderMillis: (@Sendable () -> Double)? = nil,
        outputMode: WPELayerScriptOutputMode = .layerState,
        initialVisible: Bool = true,
        initialAlpha: Double = 1,
        ownLayerName: String? = nil,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared
    ) throws {
        self.tickBudget = tickBudget
        let engine = LayerEngine(
            nowProviderMillis: nowProviderMillis,
            shared: shared,
            canvasSize: canvasSize,
            outputMode: outputMode,
            initialVisible: initialVisible,
            initialAlpha: initialAlpha,
            ownLayerName: ownLayerName,
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
            shared?.sceneScriptLoadToken?.failClosed(.executionTimedOut(operation: .setup))
            isPoisoned = true
            Logger.warning("Layer SceneScript setup exceeded \(setupBudget)s — script disabled", category: .wpeRender)
            throw WPESceneScriptError.executionTimedOut
        case .capacityUnavailable:
            shared?.sceneScriptLoadToken?.failClosed(.capacityUnavailable(operation: .setup))
            isPoisoned = true
            throw WPESceneScriptError.capacityUnavailable(operation: .setup)
        case let .completed(outcome):
            switch outcome {
            case .contextUnavailable:
                throw WPESceneScriptError.contextUnavailable
            case let .ready(hasUpdate, handlesUserProperties, output):
                self.hasUpdateFunction = hasUpdate
                self.handlesUserProperties = handlesUserProperties
                self.initialOutput = output
            }
        }
    }

    /// Tick `update()`; returns the script's new per-layer output, or nil when
    /// there's no `update()`, the instance is poisoned/timed out, or global
    /// capacity is momentarily unavailable.
    func tick(
        runtimeSeconds: Double? = nil,
        pointerFrame: WPEPointerFrame? = nil
    ) -> WPELayerScriptOutput? {
        guard hasUpdateFunction, !isPoisoned,
              engine.allows(.tick) else { return nil }
        switch engine.tick(
            runtimeSeconds: runtimeSeconds,
            pointerFrame: pointerFrame,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript update() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            return engine.acceptsCompletion() ? output : nil
        }
    }

    // MARK: Synchronous Oracle (DEBUG only)
    // Test-only bounded-blocking wrappers (production uses batchTick*/seedAsyncTick).
    #if DEBUG
    @discardableResult
    func dispatchCursorEvent(
        _ event: WPELayerScriptCursorEvent,
        pointerFrame: WPEPointerFrame,
        hit: WPELayerScriptCursorHit = .init(),
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, engine.allows(.event) else { return nil }
        switch engine.dispatchCursorEvent(
            event,
            pointerFrame: pointerFrame,
            hit: hit,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript \(event.handlerName)() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            return engine.acceptsCompletion() ? output : nil
        }
    }
    #endif

    // MARK: Synchronous Oracle (DEBUG only)
    // Test-only bounded-blocking wrappers (production uses batchTick*/seedAsyncTick).
    #if DEBUG
    /// Invoke applyUserProperties (time-of-day scripts gate day/night only here).
    @discardableResult
    func applyUserProperties(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !properties.isEmpty,
              engine.allows(.userProperties) else { return nil }
        switch engine.applyUserProperties(
            properties,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript applyUserProperties() exceeded \(tickBudget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            return engine.acceptsCompletion() ? output : nil
        }
    }
    #endif

    // MARK: Async Tick

    /// Frame-path tick, batch mode. Drains the newest completed output and returns
    /// the work to submit; see `WPESceneScriptInstance.batchTickString`.
    func batchTick(
        runtimeSeconds: Double? = nil,
        pointerFrame: WPEPointerFrame? = nil
    ) -> (output: WPELayerScriptOutput?, job: WPESceneScriptBatchDispatcher.Job?) {
        guard !isPoisoned else { return (nil, nil) }
        if let overrun = engine.quarantineAsyncIfOverdue(budget: tickBudget) {
            isPoisoned = true
            Logger.warning(
                "Layer SceneScript \(overrun.operation.rawValue) exceeded \(tickBudget)s — frozen",
                category: .wpeRender
            )
            return (nil, nil)
        }
        guard engine.allows(.tick) else { return (nil, nil) }
        let fresh = asyncOutcomeSlot.takeLatest()
        guard hasUpdateFunction, let claim = asyncOutcomeSlot.beginTick() else { return (fresh, nil) }
        guard let work = engine.makeBatchTick(
            runtimeSeconds: runtimeSeconds,
            pointerFrame: pointerFrame,
            claim: claim,
            publishTo: asyncOutcomeSlot
        ) else {
            asyncOutcomeSlot.rejectTick(claim)
            return (fresh, nil)
        }
        return (fresh, WPESceneScriptBatchDispatcher.Job(queue: engine.queue, work: work))
    }

    /// Async cursor event: fire-and-forget onto engine queue when capacity allows.
    func liveDispatchCursorEvent(
        _ event: WPELayerScriptCursorEvent,
        pointerFrame: WPEPointerFrame,
        hit: WPELayerScriptCursorHit = .init(),
        runtimeSeconds: Double? = nil
    ) {
        guard !isPoisoned, engine.allows(.event) else { return }
        _ = engine.dispatchCursorEventAsync(
            event,
            pointerFrame: pointerFrame,
            hit: hit,
            runtimeSeconds: runtimeSeconds,
            publishTo: asyncOutcomeSlot
        )
    }

    /// Async applyUserProperties: fold through outcome slot so a pending tick cannot clobber it.
    @discardableResult
    func applyUserPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !properties.isEmpty,
              engine.allows(.userProperties) else { return nil }
        let budget = tickBudget * 2
        switch engine.applyUserProperties(
            properties,
            runtimeSeconds: runtimeSeconds,
            budget: budget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript applyUserProperties() exceeded \(budget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            guard engine.acceptsCompletion() else { return nil }
            return asyncOutcomeSlot.supersede(with: output)
        }
    }

    /// Patches the authored global `scriptProperties` bag, then evaluates the
    /// layer script once on its owning lane. Separate from WPE's optional
    /// `applyUserProperties` export: most corpus scripts use only the bag.
    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !properties.isEmpty,
              engine.allows(.userProperties) else { return nil }
        let budget = tickBudget * 2
        switch engine.applyScriptProperties(
            properties,
            runtimeSeconds: runtimeSeconds,
            budget: budget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "Layer SceneScript scriptProperties patch exceeded \(budget)s — frozen",
                category: .wpeRender
            )
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(outcome):
            guard engine.acceptsCompletion(), outcome.applied,
                  let value = outcome.value else { return nil }
            return asyncOutcomeSlot.supersede(with: value)
        }
    }

    /// Newest-wins merge; carry pending one-shot video commands the newer run no longer reports.
    nonisolated static func mergedOutputs(
        pending: WPELayerScriptOutput,
        newer: WPELayerScriptOutput
    ) -> WPELayerScriptOutput {
        var merged = newer
        var transform = pending.ownTransform
        transform.merge(newer.ownTransform)
        merged.ownTransform = transform
        for (name, pendingTransform) in pending.otherTransforms {
            var accumulated = pendingTransform
            if let newerTransform = merged.otherTransforms[name] {
                accumulated.merge(newerTransform)
            }
            merged.otherTransforms[name] = accumulated
        }
        merged.own.videoCommands = pending.own.videoCommands + newer.own.videoCommands
        for (name, pendingState) in pending.others {
            if var newerState = merged.others[name] {
                newerState.videoCommands = pendingState.videoCommands + newerState.videoCommands
                merged.others[name] = newerState
            } else {
                merged.others[name] = pendingState
            }
        }
        return merged
    }

    private final class LayerEngine: @unchecked Sendable, WPESceneScriptEngineExecutionGuarding {
        enum SetupOutcome {
            case ready(
                hasUpdate: Bool,
                handlesUserProperties: Bool,
                output: WPELayerScriptOutput
            )
            case contextUnavailable
        }

        /// Key for `thisLayer` in the per-layer command/handle maps (other layers
        /// use their `getLayer(name)` name).
        private static let ownKey = ""
        /// `thisScene.createLayer` handles share the `getLayer` handle shape but
        /// are not scene layers: they report their transform through
        /// `created`, so they must stay out of the cross-layer journal.
        private static let createdKeyPrefix = "__created_"

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
        private var thisLayer: JSValue?
        /// Set by the context exception handler so `init()` failures can degrade
        /// safely (run on the engine queue, so no synchronization needed).
        private var didThrow = false
        /// One-shot latch for `logFirstThrow` (per instance, not per tick).
        private var hasLoggedThrow = false
        /// Handles minted by `thisScene.getLayer(name)`, keyed by layer name.
        private var namedLayers: [String: JSValue] = [:]
        /// Video handles stored here (not captured by getVideoTexture) to avoid ~1.1MB JSC retain cycle.
        private var videoHandles: [String: JSValue] = [:]
        /// Layers whose `visible`/`alpha` the script EXPLICITLY assigned (keyed by
        /// handle key = layer name, or `ownKey` for `thisLayer`). A `getLayer(x)`
        /// the script only *read* never lands here, so `readOutput` won't drive it.
        private var assignedVisible: [String: Bool] = [:]
        private var assignedAlpha: [String: Double] = [:]
        /// Cumulative own-layer assignments. These are deliberately separate
        /// from the JS vector objects so a read or nested-object edit does not
        /// masquerade as `thisLayer.<field> = value`.
        private var assignedOwnTransform = WPELayerScriptTransformMutation()
        private var ownOriginValue: JSValue?
        private var ownScaleValue: JSValue?
        private var ownAnglesValue: JSValue?
        /// Same contract as `assignedOwnTransform`, one entry per layer name a
        /// script addressed through `thisScene.getLayer(name)`.
        private var assignedOtherTransforms: [String: WPELayerScriptTransformMutation] = [:]
        private var otherTransformValues: [String: [OwnTransformField: JSValue]] = [:]
        private var createdLayers: [(key: String, handle: JSValue)] = []
        private var createdLayerCounter = 0
        /// Video commands per layer key ("" = thisLayer, else the getLayer name).
        /// Drained on the engine queue (where the JS blocks also append) so there
        /// is no cross-thread race.
        private var pendingVideo: [String: [WPELayerVideoCommand]] = [:]
        /// Last play/stop intent per sound layer, so `isPlaying()` answers without
        /// a read-back channel into the audio graph.
        private var soundIntent: [String: Bool] = [:]
        /// Last `volume` a script assigned per sound layer (same rationale).
        private var assignedSoundVolume: [String: Double] = [:]
        private let nowProviderMillis: (@Sendable () -> Double)?
        private let shared: WPESharedScriptState?
        private let canvasSize: SIMD2<Double>
        private let outputMode: WPELayerScriptOutputMode
        /// Parsed visible/alpha seeds — fallback when script never assigns.
        private let initialOwnVisible: Bool
        private let initialOwnAlpha: Double
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let participant: WPESceneScriptExecutionGovernor.Participant
        let instanceLimitToken: WPESceneScriptInstanceLimitToken?
        let asyncExecutionSafety = WPESceneScriptAsyncExecutionSafety()
        private let evaluationResourceBudget: WPESceneScriptEvaluationResourceBudget
        private var lastRuntimeSeconds: Double?
        private var cursorScreenPosition: JSValue?
        private var cursorWorldPosition: JSValue?
        /// Reused per-context stubs for `getParent()` / `getAnimationLayer()` so a
        /// chain (`getParent().getParent()`) doesn't mint a fresh object each call.
        private var neutralLayerStubCache: JSValue?
        private var neutralAnimationStubCache: JSValue?
        /// Scene name of the layer this script is attached to. `ownKey` is the
        /// empty string, so without this `thisLayer.name` / `.size` / `.origin`
        /// and `thisScene.getLayerIndex(thisLayer)` all miss the layer table.
        private let ownLayerName: String?

        init(
            nowProviderMillis: (@Sendable () -> Double)?,
            shared: WPESharedScriptState?,
            canvasSize: SIMD2<Double>,
            outputMode: WPELayerScriptOutputMode,
            initialVisible: Bool,
            initialAlpha: Double,
            ownLayerName: String?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher
        ) {
            let lane = batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
            self.ownLayerName = ownLayerName
            self.nowProviderMillis = nowProviderMillis
            self.shared = shared
            self.canvasSize = SIMD2<Double>(max(canvasSize.x, 1), max(canvasSize.y, 1))
            self.outputMode = outputMode
            self.initialOwnVisible = initialVisible
            self.initialOwnAlpha = initialAlpha.isFinite ? initialAlpha : 1
            self.governor = governor
            self.participant = governor.makeParticipant()
            let instanceLimitToken = shared?.sceneScriptLoadToken
            self.instanceLimitToken = instanceLimitToken
            self.evaluationResourceBudget = WPESceneScriptEvaluationResourceBudget(
                sceneToken: instanceLimitToken
            )
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
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput> {
            guard allows(.tick) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .tick, admission: .failFast) {
                self.tickOnQueue(runtimeSeconds: runtimeSeconds, pointerFrame: pointerFrame)
            }
        }

        func dispatchCursorEvent(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .failFast) {
                self.dispatchCursorEventOnQueue(
                    event,
                    pointerFrame: pointerFrame,
                    hit: hit,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }

        func applyUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput> {
            guard allows(.userProperties) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .userProperties, admission: .waitUntilDeadline) {
                self.applyUserPropertiesOnQueue(properties, runtimeSeconds: runtimeSeconds)
            }
        }

        func applyScriptProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPEScriptPropertyPatchOutcome<WPELayerScriptOutput>> {
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
                        runtimeSeconds: runtimeSeconds,
                        pointerFrame: nil
                    )
                )
            }
        }

        /// Batch work unit: no governor permit (worker count bounds concurrency); reserve inside closure.
        func makeBatchTick(
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?,
            claim: WPESceneScriptOutcomeSlot<WPELayerScriptOutput>.Claim,
            publishTo slot: WPESceneScriptOutcomeSlot<WPELayerScriptOutput>
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
                    runtimeSeconds: runtimeSeconds,
                    pointerFrame: pointerFrame
                )
                guard acceptsCompletion() else {
                    slot.rejectTick(claim)
                    return
                }
                slot.publishTick(outcome, for: claim)
            }
        }

        /// Async-mode cursor event: same handler as the synchronous path, but the
        /// output is published to the slot instead of returned to a waiting caller.
        func dispatchCursorEventAsync(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            runtimeSeconds: Double?,
            publishTo slot: WPESceneScriptOutcomeSlot<WPELayerScriptOutput>
        ) -> Bool {
            guard allows(.event) else { return false }
            guard let safety = asyncExecutionSafety.begin(
                sceneToken: instanceLimitToken,
                operation: .event
            ) else { return false }
            guard let permit = governor.tryAcquireUnreserved(for: participant) else {
                asyncExecutionSafety.complete(safety)
                return false
            }
            queue.async {
                defer {
                    self.asyncExecutionSafety.complete(safety)
                    permit.release()
                }
                let outcome = self.dispatchCursorEventOnQueue(
                    event,
                    pointerFrame: pointerFrame,
                    hit: hit,
                    runtimeSeconds: runtimeSeconds
                )
                guard self.acceptsCompletion() else { return }
                slot.publishEvent(outcome)
            }
            return true
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
            _ = updateEngineRuntime(0)
            installLayerBridge(in: context)
            if case let .returnedAlpha(initialValue) = outputMode {
                setOwnLayerAlpha(initialValue.isFinite ? initialValue : 1)
            }
            if let shared { wpeInstallSharedState(shared, in: context) }
            if let nowProviderMillis {
                let now: @convention(block) () -> Double = { nowProviderMillis() }
                context.setObject(now, forKeyedSubscript: "__hostNow" as NSString)
                _ = context.evaluateScript("Date.now = function(){ return __hostNow(); };")
            }
            context.exceptionHandler = { [weak self] _, exception in
                self?.didThrow = true
                self?.logFirstThrow(exception)
            }
            evaluationResourceBudget.beginEvaluation()
            _ = context.evaluateScript(script)
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
            let userPropertiesValue = context.objectForKeyedSubscript("applyUserProperties")
            let handlesUserProperties = userPropertiesValue != nil
                && userPropertiesValue?.isUndefined == false
                && userPropertiesValue?.hasProperty("call") == true
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            didThrow = false
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                _ = initFn.call(withArguments: [])
            }
            // A script that throws in init() (e.g. an API we don't yet support)
            // must NOT half-apply — degrade to "shown as authored" so a broken
            // script can't hide its layer, and don't tick its update().
            if didThrow {
                return .ready(
                    hasUpdate: false,
                    handlesUserProperties: handlesUserProperties,
                    output: WPELayerScriptOutput(
                        own: WPELayerScriptState(visible: true, alpha: 1, videoCommands: []),
                        others: [:]
                    )
                )
            }
            return .ready(
                hasUpdate: updateFunction != nil || timerScheduler.hasPendingTimers,
                handlesUserProperties: handlesUserProperties,
                output: readOutput()
            )
        }

        private func tickOnQueue(
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?
        ) -> WPELayerScriptOutput {
            audioBridge?.refresh()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            guard let context, let updateFunction else {
                return WPELayerScriptOutput(own: .init(visible: true, alpha: 1, videoCommands: []), others: [:])
            }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            switch outputMode {
            case .layerState:
                // Official contract for property-attached scripts: update(value)
                // receives the current value and its RETURN becomes the new one.
                // 285/392 visible scripts across the local corpus are pure
                // `return <expr>` (2955378002's 186-sprite calendar) and were
                // silently frozen at the authored seed. undefined/null returns
                // keep the assignment style (`thisLayer.visible = x`) intact.
                //
                // The LIVE property is the argument, not the last returned value:
                // an assignment-style script never returns one, so replaying the
                // return pinned it to the seed forever and `thisLayer.visible =
                // !value` re-inverted that same seed every frame. Both styles
                // write `assignedVisible` — the return path via
                // `setOwnLayerVisible`, which goes through the same
                // `defineProperty` setter an assignment uses.
                let current = assignedVisible[Self.ownKey] ?? initialOwnVisible
                let arg = JSValue(bool: current, in: context)
                    ?? JSValue(nullIn: context)!
                if let result = updateFunction.call(withArguments: [arg as Any]),
                   !result.isUndefined, !result.isNull {
                    let value: Bool?
                    if result.isBoolean {
                        value = result.toBool()
                    } else if result.isNumber {
                        let number = result.toDouble()
                        value = number.isFinite ? number != 0 : nil
                    } else {
                        value = nil
                    }
                    if let value {
                        setOwnLayerVisible(value)
                    }
                }
            case .returnedAlpha:
                // Same contract, and the same defect, as `.layerState` above:
                // the LIVE property is the argument, not the last returned
                // value, or `thisLayer.alpha = 1 - value` reads the seed forever.
                let current = assignedAlpha[Self.ownKey] ?? initialOwnAlpha
                let arg = JSValue(object: current, in: context) ?? JSValue(nullIn: context)!
                if let result = updateFunction.call(withArguments: [arg as Any]),
                   !result.isUndefined, !result.isNull, result.isNumber {
                    let value = result.toDouble()
                    if value.isFinite {
                        setOwnLayerAlpha(value)
                    }
                }
            }
            return readOutput()
        }

        /// A SceneScript that throws on EVERY tick used to be completely silent, and
        /// it is not cheap: a missing `thisLayer` method costs ~1000us per tick
        /// against ~10us once the call resolves. One line per instance, so a
        /// permanently-broken script is findable without a per-frame log flood.
        private func logFirstThrow(_ exception: JSValue?) {
            guard !hasLoggedThrow else { return }
            hasLoggedThrow = true
            Logger.warning(
                "SceneScript threw: \(exception?.toString() ?? "unknown") — it keeps running, but this "
                    + "tick produced nothing and a throwing tick costs ~100x a clean one",
                category: .wpeRender
            )
        }

        private func dispatchCursorEventOnQueue(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else {
                return readOutput()
            }
            _ = fn.call(withArguments: [cursorEventObject(
                event,
                pointerFrame: pointerFrame,
                hit: hit,
                in: context
            )])
            return readOutput()
        }

        private func applyUserPropertiesOnQueue(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            guard let context,
                  let fn = context.objectForKeyedSubscript("applyUserProperties"),
                  !fn.isUndefined, fn.hasProperty("call"),
                  let bag = JSValue(newObjectIn: context) else {
                return readOutput()
            }
            for (name, value) in properties {
                bag.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
            }
            _ = fn.call(withArguments: [bag])
            return readOutput()
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) -> Double? {
            guard let context else { return nil }
            let supplied = runtimeSeconds.flatMap { $0.isFinite ? $0 : nil }
            let runtime = max(lastRuntimeSeconds ?? 0, supplied ?? lastRuntimeSeconds ?? 0)
            let frameTime: Double
            if let previous = lastRuntimeSeconds {
                frameTime = max(runtime - previous, 0)
            } else {
                frameTime = max(runtime, 1.0 / 30.0)
            }
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
            let screen = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let world = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            input.setObject(screen, forKeyedSubscript: "cursorScreenPosition" as NSString)
            input.setObject(world, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorScreenPosition = screen
            cursorWorldPosition = world
            updateInput(.neutral)
        }

        private func updateInput(_ pointerFrame: WPEPointerFrame?) {
            guard let pointerFrame else { return }
            let x = clampFinite(pointerFrame.position.x, lower: 0, upper: 1)
            let y = clampFinite(pointerFrame.position.y, lower: 0, upper: 1)
            cursorScreenPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorScreenPosition?.setObject(y * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
            cursorWorldPosition?.setObject((1.0 - y) * canvasSize.y, forKeyedSubscript: "y" as NSString)
            cursorWorldPosition?.setObject(0.0, forKeyedSubscript: "z" as NSString)
        }

        private func cursorEventObject(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit = .init(),
            in context: JSContext
        ) -> JSValue {
            let object = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            object.setObject(event.handlerName, forKeyedSubscript: "type" as NSString)
            object.setObject(pointerFrame.isDown, forKeyedSubscript: "leftDown" as NSString)
            object.setObject(pointerFrame.isRightDown, forKeyedSubscript: "rightDown" as NSString)
            let position = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            position.setObject(clampFinite(pointerFrame.position.x, lower: 0, upper: 1), forKeyedSubscript: "x" as NSString)
            position.setObject(clampFinite(pointerFrame.position.y, lower: 0, upper: 1), forKeyedSubscript: "y" as NSString)
            object.setObject(position, forKeyedSubscript: "position" as NSString)
            object.setObject(cursorScreenPosition, forKeyedSubscript: "cursorScreenPosition" as NSString)
            object.setObject(cursorWorldPosition, forKeyedSubscript: "cursorWorldPosition" as NSString)
            object.setObject(
                hit.worldPosition.map { cursorVectorObject($0, in: context) } ?? cursorWorldPosition,
                forKeyedSubscript: "worldPosition" as NSString
            )
            object.setObject(
                hit.localPosition.map { cursorVectorObject($0, in: context) } ?? JSValue(nullIn: context),
                forKeyedSubscript: "localPosition" as NSString
            )
            if let hitBox = hit.hitBox {
                object.setObject(hitBox, forKeyedSubscript: "hitBox" as NSString)
            } else {
                object.setObject(JSValue(nullIn: context), forKeyedSubscript: "hitBox" as NSString)
            }
            return object
        }

        private func cursorVectorObject(_ value: SIMD3<Double>, in context: JSContext) -> JSValue {
            let object = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            object.setObject(value.x.isFinite ? value.x : 0, forKeyedSubscript: "x" as NSString)
            object.setObject(value.y.isFinite ? value.y : 0, forKeyedSubscript: "y" as NSString)
            object.setObject(value.z.isFinite ? value.z : 0, forKeyedSubscript: "z" as NSString)
            return object
        }

        private func clampFinite(_ value: Double, lower: Double, upper: Double) -> Double {
            guard value.isFinite else { return (lower + upper) * 0.5 }
            return min(max(value, lower), upper)
        }

        private func setOwnLayerVisible(_ value: Bool) {
            thisLayer?.setObject(value, forKeyedSubscript: "visible" as NSString)
        }

        private func setOwnLayerAlpha(_ value: Double) {
            thisLayer?.setObject(value.isFinite ? value : 1, forKeyedSubscript: "alpha" as NSString)
        }

        /// Real thisLayer + thisScene.getLayer handles + WEMath (replace read-only stubs).
        private func installLayerBridge(in context: JSContext) {
            let layer = makeLayerHandle(key: Self.ownKey, in: context)
            context.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
            // Same handle under WPE's other name for it. 8 bindings across 6 scenes
            // by different authors use `thisObject`, so it is a real global rather
            // than one author's invention — and it was undefined, so every one of
            // them threw.
            context.setObject(layer, forKeyedSubscript: "thisObject" as NSString)
            self.thisLayer = layer

            let getLayer: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] nameValue in
                guard let self, let context,
                      nameValue.isString,
                      let name = nameValue.toString(), !name.isEmpty else {
                    return nil
                }
                return self.layerHandle(named: name, in: context)
            }
            let scene = JSValue(newObjectIn: context)!
            scene.setObject(getLayer, forKeyedSubscript: "getLayer" as NSString)
            let createLayer: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] spec in
                guard let self, let context else { return nil }
                guard self.instanceLimitToken?.admitCreatedLayer() ?? true else {
                    return self.neutralLayerStub(in: context)
                }
                let key = "\(Self.createdKeyPrefix)\(self.createdLayerCounter)"
                let handle = self.makeLayerHandle(key: key, in: context)
                self.createdLayerCounter += 1
                self.createdLayers.append((key, handle))
                if spec.isObject {
                    for property in ["image", "origin", "color", "scale", "alpha", "visible"] {
                        if let value = spec.objectForKeyedSubscript(property), !value.isUndefined {
                            handle.setObject(value, forKeyedSubscript: property as NSString)
                        }
                    }
                }
                return handle
            }
            scene.setObject(createLayer, forKeyedSubscript: "createLayer" as NSString)
            // Document order is the z-order scripts index against. -1 for a name
            // that isn't a scene layer, mirroring indexOf.
            let getLayerIndex: @convention(block) (JSValue) -> Int = { [weak self] handleValue in
                guard let self,
                      let nameValue = handleValue.objectForKeyedSubscript("name"),
                      let name = nameValue.toString() else { return -1 }
                return self.shared?.layers.first { $0.name == name }?.index ?? -1
            }
            scene.setObject(getLayerIndex, forKeyedSubscript: "getLayerIndex" as NSString)
            let enumerateLayers: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self, let context else { return nil }
                let handles = (self.shared?.layers ?? []).map { self.layerHandle(named: $0.name, in: context) }
                return JSValue(object: handles, in: context)
            }
            scene.setObject(enumerateLayers, forKeyedSubscript: "enumerateLayers" as NSString)
            // `scene.on(event, cb)` isn't a real WPE API (some scenes assume it);
            // a no-op stub keeps such a script from throwing at top-level eval.
            let on: @convention(block) (JSValue, JSValue) -> Void = { _, _ in }
            scene.setObject(on, forKeyedSubscript: "on" as NSString)
            context.setObject(scene, forKeyedSubscript: "thisScene" as NSString)
            context.setObject(scene, forKeyedSubscript: "scene" as NSString)

        }

        /// One handle per layer name for the scene's lifetime, so `enumerateLayers`
        /// and repeated `getLayer` calls hand back the same object (scripts compare
        /// handles and stash them).
        private func layerHandle(named name: String, in context: JSContext) -> JSValue {
            if let existing = namedLayers[name] { return existing }
            let handle = makeLayerHandle(key: name, in: context)
            namedLayers[name] = handle
            return handle
        }

        /// Writable layer handle tagged by key; hierarchy/animation accessors are stubs.
        private func makeLayerHandle(key: String, in context: JSContext) -> JSValue {
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            // `key` is "" for the script's own layer, so anything addressed by
            // SCENE name (the layer table, sound commands) needs the resolved one.
            let layerName = key == Self.ownKey ? (ownLayerName ?? key) : key
            // visible/alpha are accessors so explicit assign is distinguishable from a mere read.
            installAssignmentAccessors(on: handle, key: key, layerName: layerName, in: context)
            handle.setObject(layerName, forKeyedSubscript: "name" as NSString)
            // Authored layer size. Five scenes size a background off their icons
            // (`icon.size.x * icon.scale.x`); the property being absent threw and
            // killed the rest of update(). Zero when the name isn't a scene layer —
            // `getLayer` mints handles for arbitrary strings.
            let size = JSValue(newObjectIn: context)!
            let info = shared?.layers.first { $0.name == layerName }
            size.setObject(info?.size.x ?? 0, forKeyedSubscript: "x" as NSString)
            size.setObject(info?.size.y ?? 0, forKeyedSubscript: "y" as NSString)
            handle.setObject(size, forKeyedSubscript: "size" as NSString)
            if key == Self.ownKey {
                installOwnTransformAccessors(on: handle, info: info, in: context)
            } else {
                installOtherTransformAccessors(on: handle, key: key, info: info, in: context)
            }
            videoHandles[key] = makeVideoHandle(key: key, in: context)
            _ = neutralLayerStub(in: context)
            _ = neutralAnimationStub(in: context)
            let getVideoTexture: @convention(block) () -> JSValue? = { [weak self] in
                self?.videoHandles[key]
            }
            handle.setObject(getVideoTexture, forKeyedSubscript: "getVideoTexture" as NSString)
            // Real parent when the document names one: 3660962877's dock reads
            // `parent.origin` to decide which screen edge to align to, and a
            // stub without an origin threw on `currentPos.x` every tick.
            let parentName = info?.parentName
            let getParent: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self else { return nil }
                guard let parentName, let context else { return self.neutralLayerStubCache }
                return self.layerHandle(named: parentName, in: context)
            }
            handle.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            let getAnimationLayer: @convention(block) (JSValue) -> JSValue? = { [weak self] _ in
                self?.neutralAnimationStubCache
            }
            handle.setObject(getAnimationLayer, forKeyedSubscript: "getAnimationLayer" as NSString)
            // The stub already answers setFrame/play/pause/stop; it was simply not
            // reachable under this name, so `thisLayer.getTextureAnimation()` threw a
            // TypeError on EVERY tick. Measured: 1039us/tick against 11us for a layer
            // script that doesn't throw — 30 bindings of one 415-byte script were
            // 31ms of scene 3299228616's 31.8ms per-frame script cost.
            let getTextureAnimation: @convention(block) () -> JSValue? = { [weak self] in
                self?.neutralAnimationStubCache
            }
            handle.setObject(getTextureAnimation, forKeyedSubscript: "getTextureAnimation" as NSString)
            // Timeline animation, called both bare (`thisLayer.getAnimation()`) and
            // by name (`thisScene.getLayer(a).getAnimation(b)`), across 5 scenes.
            let getAnimation: @convention(block) (JSValue) -> JSValue? = { [weak self] _ in
                self?.neutralAnimationStubCache
            }
            handle.setObject(getAnimation, forKeyedSubscript: "getAnimation" as NSString)
            // `ISoundLayer`: play/stop/pause/isPlaying/volume. Real WPE API — every
            // handle carries it because a script reaches a sound layer through the
            // same `thisScene.getLayer(name)` as any other. Commands go through
            // `shared` (sound is scene-scoped) and the renderer drains them.
            let store = shared
            for (method, command) in [
                ("play", WPELayerSoundCommand.play),
                ("stop", .stop),
                ("pause", .pause)
            ] {
                let block: @convention(block) () -> Void = { [weak self] in
                    self?.soundIntent[layerName] = (command == .play)
                    store?.enqueueSoundCommand(layer: layerName, command)
                }
                handle.setObject(block, forKeyedSubscript: method as NSString)
            }
            // Last intent this engine expressed, not a read-back from the audio
            // graph: giving scripts a live channel into AVAudioEngine would need a
            // per-tick snapshot, and nothing in the corpus reads it.
            let isPlaying: @convention(block) () -> Bool = { [weak self] in
                self?.soundIntent[layerName] ?? false
            }
            handle.setObject(isPlaying, forKeyedSubscript: "isPlaying" as NSString)
            return handle
        }

        /// Accessor visible/alpha whose setters record explicit assignment for readOutput.
        private func installAssignmentAccessors(
            on handle: JSValue,
            key: String,
            layerName: String,
            in context: JSContext
        ) {
            let getVisible: @convention(block) () -> Bool = { [weak self] in
                guard let self else { return true }
                return self.assignedVisible[key] ?? self.defaultVisible(forKey: key)
            }
            let setVisible: @convention(block) (JSValue) -> Void = { [weak self] value in
                self?.assignedVisible[key] = value.toBool()
            }
            let getAlpha: @convention(block) () -> Double = { [weak self] in
                guard let self else { return 1 }
                return self.assignedAlpha[key] ?? self.defaultAlpha(forKey: key)
            }
            let setAlpha: @convention(block) (JSValue) -> Void = { [weak self] value in
                let scalar = value.toDouble()
                self?.assignedAlpha[key] = scalar.isFinite ? scalar : 1
            }
            // `ISoundLayer.volume`. Reads back the last value this engine set
            // rather than the mixer's, for the same reason `isPlaying` does.
            let getVolume: @convention(block) () -> Double = { [weak self] in
                self?.assignedSoundVolume[layerName] ?? 1
            }
            let setVolume: @convention(block) (JSValue) -> Void = { [weak self] value in
                guard let self else { return }
                let scalar = value.toDouble()
                guard scalar.isFinite else { return }
                self.assignedSoundVolume[layerName] = scalar
                self.shared?.enqueueSoundCommand(layer: layerName, .setVolume(scalar))
            }
            defineAccessor(on: handle, property: "visible", get: getVisible, set: setVisible, in: context)
            defineAccessor(on: handle, property: "alpha", get: getAlpha, set: setAlpha, in: context)
            defineAccessor(on: handle, property: "volume", get: getVolume, set: setVolume, in: context)
        }

        /// Whole-property setters mirror the native layer API. Reading a vector
        /// or mutating only the returned object's `x/y/z` does not publish a
        /// geometry assignment; the script must assign the vector back to
        /// `thisLayer.origin/scale/angles`.
        private func installOwnTransformAccessors(
            on handle: JSValue,
            info: WPESceneScriptLayerInfo?,
            in context: JSContext
        ) {
            let origin = SIMD3<Double>(
                info?.origin.x ?? 0,
                info?.origin.y ?? 0,
                info?.originZ ?? 0
            )
            let scale = info?.scale ?? SIMD3<Double>(repeating: 1)
            let anglesDegrees = (info?.angles ?? .zero) * (180 / .pi)
            ownOriginValue = Self.vector(origin, in: context)
            ownScaleValue = Self.vector(scale, in: context)
            ownAnglesValue = Self.vector(anglesDegrees, in: context)

            let getOrigin: @convention(block) () -> JSValue? = { [weak self] in self?.ownOriginValue }
            let setOrigin: @convention(block) (JSValue) -> Void = { [weak self] value in
                self?.setOwnTransformVector(value, field: .origin)
            }
            let getScale: @convention(block) () -> JSValue? = { [weak self] in self?.ownScaleValue }
            let setScale: @convention(block) (JSValue) -> Void = { [weak self] value in
                self?.setOwnTransformVector(value, field: .scale)
            }
            let getAngles: @convention(block) () -> JSValue? = { [weak self] in self?.ownAnglesValue }
            let setAngles: @convention(block) (JSValue) -> Void = { [weak self] value in
                self?.setOwnTransformVector(value, field: .angles)
            }
            defineAccessor(on: handle, property: "origin", get: getOrigin, set: setOrigin, in: context)
            defineAccessor(on: handle, property: "scale", get: getScale, set: setScale, in: context)
            defineAccessor(on: handle, property: "angles", get: getAngles, set: setAngles, in: context)
        }

        private enum OwnTransformField: Hashable {
            case origin
            case scale
            case angles
        }

        /// The `getLayer(name)` counterpart of `installOwnTransformAccessors`.
        /// 2955378002 copies one layer's origin onto another in `init`
        /// (`thisScene.getLayer("playerprogexception").origin = thisLayer.origin`),
        /// which silently did nothing while these were plain data properties.
        private func installOtherTransformAccessors(
            on handle: JSValue,
            key: String,
            info: WPESceneScriptLayerInfo?,
            in context: JSContext
        ) {
            let seeds: [OwnTransformField: SIMD3<Double>] = [
                .origin: SIMD3<Double>(info?.origin.x ?? 0, info?.origin.y ?? 0, info?.originZ ?? 0),
                .scale: info?.scale ?? SIMD3<Double>(repeating: 1),
                .angles: (info?.angles ?? .zero) * (180 / .pi),
            ]
            var bridges: [OwnTransformField: JSValue] = [:]
            for (field, seed) in seeds {
                bridges[field] = Self.vector(seed, in: context)
            }
            otherTransformValues[key] = bridges

            for (field, property) in [
                (OwnTransformField.origin, "origin"),
                (OwnTransformField.scale, "scale"),
                (OwnTransformField.angles, "angles"),
            ] {
                let get: @convention(block) () -> JSValue? = { [weak self] in
                    self?.otherTransformValues[key]?[field]
                }
                let set: @convention(block) (JSValue) -> Void = { [weak self] value in
                    self?.setOtherTransformVector(value, key: key, field: field)
                }
                defineAccessor(on: handle, property: property, get: get, set: set, in: context)
            }
        }

        private func setOtherTransformVector(_ value: JSValue, key: String, field: OwnTransformField) {
            guard let vector = finiteVector(value) else { return }
            // The bridge value updates either way — `createdStateFor` reads the
            // handle back through it — but only real scene layers are journaled.
            Self.update(otherTransformValues[key]?[field], with: vector)
            guard !key.hasPrefix(Self.createdKeyPrefix) else { return }
            var mutation = assignedOtherTransforms[key] ?? .init()
            switch field {
            case .origin: mutation.origin = vector
            case .scale: mutation.scale = vector
            case .angles: mutation.angles = vector
            }
            assignedOtherTransforms[key] = mutation
        }

        private func setOwnTransformVector(_ value: JSValue, field: OwnTransformField) {
            guard let vector = finiteVector(value) else { return }
            let bridgeValue: JSValue?
            switch field {
            case .origin:
                assignedOwnTransform.origin = vector
                bridgeValue = ownOriginValue
            case .scale:
                assignedOwnTransform.scale = vector
                bridgeValue = ownScaleValue
            case .angles:
                assignedOwnTransform.angles = vector
                bridgeValue = ownAnglesValue
            }
            Self.update(bridgeValue, with: vector)
        }

        private func finiteVector(_ value: JSValue) -> SIMD3<Double>? {
            guard value.isObject,
                  let xValue = value.objectForKeyedSubscript("x"), xValue.isNumber,
                  let yValue = value.objectForKeyedSubscript("y"), yValue.isNumber,
                  let zValue = value.objectForKeyedSubscript("z"), zValue.isNumber else {
                return nil
            }
            let vector = SIMD3<Double>(xValue.toDouble(), yValue.toDouble(), zValue.toDouble())
            return vector.x.isFinite && vector.y.isFinite && vector.z.isFinite ? vector : nil
        }

        private func defineAccessor(
            on handle: JSValue,
            property: String,
            get: Any,
            set: Any,
            in context: JSContext
        ) {
            guard let objectClass = context.objectForKeyedSubscript("Object"),
                  let define = objectClass.objectForKeyedSubscript("defineProperty"),
                  !define.isUndefined,
                  let descriptor = JSValue(newObjectIn: context) else { return }
            descriptor.setObject(get, forKeyedSubscript: "get" as NSString)
            descriptor.setObject(set, forKeyedSubscript: "set" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "enumerable" as NSString)
            descriptor.setObject(true, forKeyedSubscript: "configurable" as NSString)
            define.call(withArguments: [handle, property, descriptor])
        }

        private static func vector(_ value: SIMD3<Double>, in context: JSContext) -> JSValue {
            let vector = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            update(vector, with: value)
            return vector
        }

        private static func update(_ value: JSValue?, with vector: SIMD3<Double>) {
            value?.setObject(vector.x, forKeyedSubscript: "x" as NSString)
            value?.setObject(vector.y, forKeyedSubscript: "y" as NSString)
            value?.setObject(vector.z, forKeyedSubscript: "z" as NSString)
        }

        private static func unitScale(in context: JSContext) -> JSValue {
            vector(SIMD3<Double>(repeating: 1), in: context)
        }

        /// Neutral ancestor for `getParent()`: unit scale, visible, and self-returning
        /// `getParent()` so a `getParent().getParent()` chain terminates safely.
        private func neutralLayerStub(in context: JSContext) -> JSValue {
            if let cached = neutralLayerStubCache { return cached }
            let stub = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            stub.setObject(true, forKeyedSubscript: "visible" as NSString)
            stub.setObject(1.0, forKeyedSubscript: "alpha" as NSString)
            stub.setObject(Self.unitScale(in: context), forKeyedSubscript: "scale" as NSString)
            // Zeroed but PRESENT: scripts read `.origin.x` / `.size.x` off whatever
            // getParent()/getLayer() hands them, and undefined there throws.
            for property in ["origin", "size"] {
                let vector = JSValue(newObjectIn: context)!
                vector.setObject(0.0, forKeyedSubscript: "x" as NSString)
                vector.setObject(0.0, forKeyedSubscript: "y" as NSString)
                vector.setObject(0.0, forKeyedSubscript: "z" as NSString)
                stub.setObject(vector, forKeyedSubscript: property as NSString)
            }
            let getParent: @convention(block) () -> JSValue? = { [weak self] in
                self?.neutralLayerStubCache
            }
            stub.setObject(getParent, forKeyedSubscript: "getParent" as NSString)
            _ = neutralAnimationStub(in: context)
            let getAnimationLayer: @convention(block) (JSValue) -> JSValue? = { [weak self] _ in
                self?.neutralAnimationStubCache
            }
            stub.setObject(getAnimationLayer, forKeyedSubscript: "getAnimationLayer" as NSString)
            neutralLayerStubCache = stub
            return stub
        }

        private func neutralAnimationStub(in context: JSContext) -> JSValue {
            if let cached = neutralAnimationStubCache { return cached }
            let stub = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let noop: @convention(block) () -> Void = {}
            let noop1: @convention(block) (JSValue) -> Void = { _ in }
            // Writable playback rate. We don't drive layer timeline animations at
            // all, so this stores and does nothing — but 3448877775 assigns it in
            // the FIRST statement of update(), and an assignment to a property of
            // `undefined` threw away the rest of the body along with it.
            stub.setObject(1.0, forKeyedSubscript: "rate" as NSString)
            for method in ["play", "pause", "stop"] {
                stub.setObject(noop, forKeyedSubscript: method as NSString)
            }
            stub.setObject(noop1, forKeyedSubscript: "setFrame" as NSString)
            // Paired with setFrame — 4 instances in the corpus scan threw on
            // `ani.getFrame()`. We drive no timeline, so frame 0 is the only
            // answer we can give, and it beats killing the rest of update().
            let getFrame: @convention(block) () -> Double = { 0 }
            stub.setObject(getFrame, forKeyedSubscript: "getFrame" as NSString)
            neutralAnimationStubCache = stub
            return stub
        }

        private func makeVideoHandle(key: String, in context: JSContext) -> JSValue {
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let append: @Sendable (WPELayerVideoCommand) -> Void = { [weak self] command in
                guard let self, self.evaluationResourceBudget.admitVideoCommand() else { return }
                self.pendingVideo[key, default: []].append(command)
            }
            let play: @convention(block) () -> Void = { append(.play) }
            let pause: @convention(block) () -> Void = { append(.pause) }
            let stop: @convention(block) () -> Void = { append(.stop) }
            let setCurrentTime: @convention(block) (JSValue) -> Void = { arg in append(.seek(arg.toDouble())) }
            let getCurrentTime: @convention(block) () -> Double = { 0 }
            handle.setObject(play, forKeyedSubscript: "play" as NSString)
            handle.setObject(pause, forKeyedSubscript: "pause" as NSString)
            handle.setObject(stop, forKeyedSubscript: "stop" as NSString)
            handle.setObject(setCurrentTime, forKeyedSubscript: "setCurrentTime" as NSString)
            handle.setObject(getCurrentTime, forKeyedSubscript: "getCurrentTime" as NSString)
            return handle
        }

        private func readOutput() -> WPELayerScriptOutput {
            let own = stateFor(handle: thisLayer, key: Self.ownKey)
            var others: [String: WPELayerScriptState] = [:]
            for (name, _) in namedLayers {
                let visible = assignedVisible[name]
                let alpha = assignedAlpha[name]
                let video = pendingVideo[name] ?? []
                // A layer the script only READ (never assigned visible/alpha, no
                // video command) must not be driven — leave its real visibility be.
                guard visible != nil || alpha != nil || !video.isEmpty else { continue }
                others[name] = WPELayerScriptState(
                    visible: visible ?? true,
                    alpha: alpha ?? 1,
                    videoCommands: video,
                    visibleAssigned: visible != nil,
                    alphaAssigned: alpha != nil
                )
            }
            let created = createdLayers.map { createdStateFor(handle: $0.handle, key: $0.key) }
            pendingVideo.removeAll(keepingCapacity: true)
            return WPELayerScriptOutput(
                own: own,
                others: others,
                created: created,
                ownTransform: assignedOwnTransform,
                otherTransforms: assignedOtherTransforms
            )
        }

        /// Neutral defaults for a layer the script never assigned: own layer keeps
        /// its parsed `visible`/`alpha` seeds, other (named) handles stay shown.
        private func defaultVisible(forKey key: String) -> Bool {
            key == Self.ownKey ? initialOwnVisible : true
        }

        private func defaultAlpha(forKey key: String) -> Double {
            key == Self.ownKey ? initialOwnAlpha : 1
        }

        private func stateFor(handle _: JSValue?, key: String) -> WPELayerScriptState {
            // assigned* nil when script only reads — avoids clobbering parsed visible:false seeds.
            let visible = assignedVisible[key]
            let alpha = assignedAlpha[key]
            return WPELayerScriptState(
                visible: visible ?? defaultVisible(forKey: key),
                alpha: alpha ?? defaultAlpha(forKey: key),
                videoCommands: pendingVideo[key] ?? [],
                visibleAssigned: visible != nil,
                alphaAssigned: alpha != nil
            )
        }

        private func createdStateFor(handle: JSValue, key: String) -> WPECreatedLayerScriptState {
            let imagePath = stringProperty(handle.objectForKeyedSubscript("image"), fallback: "")
            let origin = vec3(
                handle.objectForKeyedSubscript("origin"),
                fallback: SIMD3<Double>(0, 0, 0)
            )
            let color = vec3(
                handle.objectForKeyedSubscript("color"),
                fallback: SIMD3<Double>(1, 1, 1)
            )
            let scale = vec3(
                handle.objectForKeyedSubscript("scale"),
                fallback: SIMD3<Double>(1, 1, 1)
            )
            let alphaValue = handle.objectForKeyedSubscript("alpha")
            let alpha = (alphaValue?.isNumber == true) ? (alphaValue?.toDouble() ?? 1) : 1
            let visible = handle.objectForKeyedSubscript("visible")?.toBool() ?? true
            return WPECreatedLayerScriptState(
                key: key,
                imagePath: imagePath,
                origin: origin,
                color: color,
                scale: scale,
                alpha: alpha.isFinite ? alpha : 1,
                visible: visible
            )
        }

        private func vec3(_ value: JSValue?, fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let value, value.isObject else { return fallback }
            let x = value.objectForKeyedSubscript("x")?.toDouble() ?? fallback.x
            let y = value.objectForKeyedSubscript("y")?.toDouble() ?? fallback.y
            let z = value.objectForKeyedSubscript("z")?.toDouble() ?? fallback.z
            return SIMD3<Double>(
                x.isFinite ? x : fallback.x,
                y.isFinite ? y : fallback.y,
                z.isFinite ? z : fallback.z
            )
        }

        private func stringProperty(_ value: JSValue?, fallback: String) -> String {
            guard let value, !value.isUndefined, !value.isNull else { return fallback }
            return value.toString() ?? fallback
        }

    }
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
private func wpeRefreshEngineClock(
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
private func wpeInstallSharedState(_ store: WPESharedScriptState, in context: JSContext) {
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

private struct WPEScriptPropertyPatchOutcome<Value> {
    let applied: Bool
    let value: Value?
}

/// Mutates only the addressed entries on the JS engine's owning lane. The
/// object itself is retained so authored references to `scriptProperties`
/// remain valid; replacing the global would break closures that captured it.
private func wpePatchScriptProperties(
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
private func wpeNormalizeScriptPropertiesDeclaration(_ preprocessed: String) -> String {
    preprocessed
        .replacingOccurrences(of: "let scriptProperties", with: "var scriptProperties")
        .replacingOccurrences(of: "const scriptProperties", with: "var scriptProperties")
}

/// Snapshot a script's declared scriptProperty defaults (from its
/// `createScriptProperties()` object) so an injection can rebuild from them.
private func wpeDeclaredScriptPropertyDefaults(
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
private func wpeInstallScriptProperties(
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
        private var consecutiveRuntimeExceptions = 0
        /// Cap repeated update() exceptions so JSC reporting cannot thrash every tick.
        private let runtimeFault = OSAllocatedUnfairLock(initialState: false)
        var hasRuntimeFault: Bool { runtimeFault.withLock { $0 } }
        private static let runtimeExceptionLimit = 3

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
            let result = updateFunction.call(withArguments: [argument])
            if didThrow {
                consecutiveRuntimeExceptions += 1
                if consecutiveRuntimeExceptions >= Self.runtimeExceptionLimit {
                    // Release the JS callable on its owning queue and stop
                    // scheduling this broken transform until scene reload.
                    self.updateFunction = nil
                    runtimeFault.withLock { $0 = true }
                }
                return nil
            }
            consecutiveRuntimeExceptions = 0
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
