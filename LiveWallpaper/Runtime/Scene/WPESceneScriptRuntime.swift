#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import os
import simd

struct WPESceneScriptGeneralSettingsDeliveryState: Sendable {
    private(set) var language: String
    private var appliedLanguage: String?

    init(language: String) {
        self.language = language
    }

    @discardableResult
    mutating func updateLanguage(_ language: String) -> Bool {
        guard language != self.language else { return false }
        self.language = language
        return true
    }

    mutating func takeInitialLanguage() -> String {
        appliedLanguage = language
        return language
    }

    mutating func takeChangedLanguage() -> String? {
        guard appliedLanguage != language else { return nil }
        appliedLanguage = language
        return language
    }

    mutating func resetGeneration() {
        appliedLanguage = nil
    }
}

protocol WPESceneScriptEngineExecutionGuarding: AnyObject {
    var queue: DispatchQueue { get }
    var executionLane: WPESceneScriptBatchDispatcher.Lane { get }
    var governor: WPESceneScriptExecutionGovernor { get }
    var participant: WPESceneScriptExecutionGovernor.Participant { get }
    var instanceLimitToken: WPESceneScriptInstanceLimitToken? { get }
    var asyncExecutionSafety: WPESceneScriptAsyncExecutionSafety { get }
    var timerScheduler: WPESceneScriptTimerScheduler? { get set }
    var didThrow: Bool { get set }
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

    func advanceTimers(to runtimeSeconds: Double?) -> Bool {
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

    func update(_ vector: JSValue?, x: Double, y: Double) {
        vector?.setObject(x, forKeyedSubscript: "x" as NSString)
        vector?.setObject(y, forKeyedSubscript: "y" as NSString)
    }
}

protocol WPESceneScriptCanvasSizedEngine: WPESceneScriptEngineExecutionGuarding {
    var canvasSize: SIMD2<Double> { get }
    var screenSize: SIMD2<Double> { get }
    var screenResolution: JSValue? { get set }
}

extension WPESceneScriptCanvasSizedEngine {
    func installCanvasSize(in context: JSContext) {
        guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject,
              let canvas = JSValue(newObjectIn: context),
              let screen = JSValue(newObjectIn: context) else { return }
        update(canvas, x: canvasSize.x, y: canvasSize.y)
        update(screen, x: screenSize.x, y: screenSize.y)
        engine.setObject(canvas, forKeyedSubscript: "canvasSize" as NSString)
        engine.setObject(screen, forKeyedSubscript: "screenResolution" as NSString)
        screenResolution = screen
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
        nonisolated(unsafe) let laneOwnedValue = value
        queue.async {
            withExtendedLifetime(laneOwnedValue) {}
        }
    }
}

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
        var lastCompletedTickGeneration: UInt64?
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

    /// A retained event outcome is not proof that this particular tick completed.
    func didComplete(_ claim: Claim) -> Bool {
        state.withLock { $0.lastCompletedTickGeneration == claim.generation }
    }

    /// Queue-side tick finish; stale generation discarded.
    @discardableResult
    func publishTick(_ outcome: Outcome, for claim: Claim) -> Bool {
        state.withLock { s in
            guard s.inFlightTickGeneration == claim.generation else { return false }
            s.inFlightTickGeneration = nil
            s.tickStartedAtUptimeNanos = nil
            Self.store(outcome, into: &s, combine: combine)
            s.lastCompletedTickGeneration = claim.generation
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

/// Not DEBUG-gated: a Release build is where JSContext liveness is asked.
final class WPESceneScriptContextBeacon: NSObject {
    private static let liveLock = OSAllocatedUnfairLock(initialState: 0)
    static var liveCount: Int { liveLock.withLock { $0 } }

    override init() {
        super.init()
        Self.liveLock.withLock { $0 += 1 }
    }

    deinit { Self.liveLock.withLock { $0 -= 1 } }
}

final class WPESceneScriptAudioBridge {
    /// WPE AUDIO_RESOLUTION_* constants (broker width = largest).
    private static let resolutions = [16, 32, 64]
    /// FIFO cap: registerAudioBuffers() from update() would otherwise pin 3 JSValues per frame.
    private static let maxRegisteredBuffers = 16

    private struct Buffer {
        let bands: Int
        let average: JSValue
        let left: JSValue
        let right: JSValue
        /// JSC-owned `Float64Array` of `bands * 3` (left | right | average).
        let packed: JSValue?
        let fanOut: JSValue?
    }

    /// `n` is bound at registration, never re-read from `avg.length` (a shrink would copy the wrong packed slice).
    private static let fanOutFactory = """
    (function (avg, left, right, packed, n) { return function () {
        var twoN = n * 2, i = 0;
        for (; i < n; i++) {
            left[i] = packed[i];
            right[i] = packed[n + i];
            avg[i] = packed[twoN + i];
        }
    }; })
    """

    private var buffers: [Buffer] = []
    /// One trailing zero pass after capture stops; later ticks only read isCapturing.
    private var wasSilent = true

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
            if let self {
                let packed = Self.makePackedSnapshot(bands: bands, in: context)
                let fanOut = packed.flatMap {
                    wpeMakeHostTickHelper(
                        in: context,
                        factory: Self.fanOutFactory,
                        targets: [average, left, right, $0, JSValue(int32: Int32(bands), in: context)]
                    )
                }
                self.buffers.append(
                    Buffer(
                        bands: bands,
                        average: average,
                        left: left,
                        right: right,
                        packed: packed,
                        fanOut: fanOut
                    )
                )
                // Over-cap drops the oldest registrations (a per-update registrant keeps its newest).
                if self.buffers.count > Self.maxRegisteredBuffers {
                    let dropped = self.buffers.count - Self.maxRegisteredBuffers
                    self.buffers.removeFirst(dropped)
                    Logger.warning(
                        "[SceneScript] registerAudioBuffers exceeded \(Self.maxRegisteredBuffers) registrations — dropped \(dropped) oldest; those buffers stop updating",
                        category: .wpeRender
                    )
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

    func refresh() {
        guard !buffers.isEmpty else { return }
        guard SystemAudioCaptureManager.isCapturing else {
            guard !wasSilent else { return }
            for buffer in buffers { write(buffer, left: nil, right: nil) }
            wasSilent = true
            return
        }
        let frame = SystemAudioCaptureManager.broker.snapshot(clampedTo01: false)
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
        let frame = SystemAudioCaptureManager.broker.snapshot(clampedTo01: false)
        return zip(frame.left, frame.right).map { (Double($0) + Double($1)) * 0.5 }
    }

    private func write(_ buffer: Buffer, left: [Float]?, right: [Float]?) {
        if let packed = buffer.packed, let fanOut = buffer.fanOut,
           let ptr = Self.packedBytes(packed, count: buffer.bands * 3) {
            WPEFrameOccupancyMeter.count(.audioBandWrite)
            let n = buffer.bands
            for band in 0..<n {
                let l = Double(left?[band] ?? 0)
                let r = Double(right?[band] ?? 0)
                ptr[band] = l
                ptr[n + band] = r
                ptr[n * 2 + band] = (l + r) * 0.5
            }
            WPEFrameOccupancyMeter.count(.jscCall)
            fanOut.call(withArguments: [])
            return
        }
        WPEFrameOccupancyMeter.count(.audioBandWrite, by: buffer.bands * 3)
        for band in 0..<buffer.bands {
            let l = Double(left?[band] ?? 0)
            let r = Double(right?[band] ?? 0)
            buffer.left.setValue(l, at: band)
            buffer.right.setValue(r, at: band)
            buffer.average.setValue((l + r) * 0.5, at: band)
        }
    }

    private static func makePackedSnapshot(bands: Int, in context: JSContext) -> JSValue? {
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(
            context.jsGlobalContextRef,
            kJSTypedArrayTypeFloat64Array,
            bands * 3,
            &exception
        ), exception == nil else { return nil }
        return JSValue(jsValueRef: object, in: context)
    }

    /// `JSObjectGetTypedArrayBytesPtr` is valid until the next GC — fill
    /// immediately and don't store the pointer across a JSC call.
    private static func packedBytes(
        _ packed: JSValue,
        count: Int
    ) -> UnsafeMutablePointer<Double>? {
        guard let context = packed.context else { return nil }
        var exception: JSValueRef?
        guard let object = JSValueToObject(
            context.jsGlobalContextRef,
            packed.jsValueRef,
            &exception
        ), exception == nil,
           let raw = JSObjectGetTypedArrayBytesPtr(
            context.jsGlobalContextRef,
            object,
            &exception
           ), exception == nil else { return nil }
        return raw.bindMemory(to: Double.self, capacity: count)
    }

    /// Pairwise max halving matching WPEMetalRuntimeUniforms.halve (scripts = shaders; see the capture evidence cited there).
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

/// Deliberately never creates a Timer/run-loop source; callbacks stay on the JSContext lane and advance from engine.runtime.
final class WPESceneScriptTimerScheduler {
    enum AdvanceResult: Equatable {
        case completed
        case callbackLimitExceeded
    }

    /// Hitting the per-advance callback limit is a scene fail-close, never a silent callback drop.
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
    /// false until the first advance; timers registered before it are relative to that first runtime, not 0.
    private var hasRuntimeBase = false
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
        if !hasRuntimeBase {
            hasRuntimeBase = true
            // A reloaded scene's runtime starts far from 0; catching up from 0 would blow the callback limit.
            let offset = proposedRuntimeSeconds - currentRuntimeSeconds
            for entry in heap {
                entry.deadline += offset
            }
            currentRuntimeSeconds = proposedRuntimeSeconds
        }
        currentRuntimeSeconds = max(currentRuntimeSeconds, proposedRuntimeSeconds)
        var callbackCount = 0
        // Re-inserted only after the sweep, so an interval fires at most once per advance even when now + interval <= now.
        var rescheduled: [Entry] = []

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
            WPEFrameOccupancyMeter.count(.jscCall)
            let result = entry.callback.call(withArguments: [])
            if result == nil || callbackDidThrow() {
                entry.isCancelled = true
            }
            if entry.isCancelled || !entry.repeating || entry.interval <= 0 {
                entriesByHandle.removeValue(forKey: entry.handle)
                continue
            }

            // From now, not the prior deadline: WPE never catches up missed periods, so intervals drift to the frame grid.
            entry.deadline = currentRuntimeSeconds + entry.interval
            rescheduled.append(entry)
        }
        rescheduled.forEach(insert)
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

enum WPESceneScriptInitializationMode: Equatable, Sendable {
    case immediate
    case deferred
}

final class WPESceneScriptInstance {
    private let engineRelease: WPESceneScriptLaneRelease<Engine>
    private var engine: Engine {
        engineRelease.value
    }

    private var hasUpdateFunction: Bool
    private(set) var mediaHandlers: WPESceneMediaHandlerSet
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    private var isDestroyed = false
    private var requiresInitialization: Bool
    private var remainingSetupBudget: TimeInterval
    private(set) var lastValue: String
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<String?>()
    /// Keep at most the latest event per handler until the governor admits it, or a busy frame loses the title.
    private var pendingMediaEvents: [WPESceneMediaEvent] = []

    /// Setup covers the module body + init(); per-frame update overrun only ever means a runaway loop.
    init(
        script: String,
        initialValue: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared,
        // `nil` leaves the sandbox's 1920x1080; every caller that knows the real canvas must pass it.
        canvasSize: SIMD2<Double>? = nil,
        screenSize: SIMD2<Double>? = nil,
        ownLayerName: String? = nil,
        ownObjectID: String? = nil,
        initializationMode: WPESceneScriptInitializationMode = .immediate
    ) throws {
        self.lastValue = initialValue
        self.tickBudget = tickBudget
        requiresInitialization = initializationMode == .deferred
        remainingSetupBudget = setupBudget
        let engine = Engine(
            shared: shared,
            governor: governor,
            batchDispatcher: batchDispatcher,
            canvasSize: canvasSize,
            screenSize: screenSize ?? canvasSize,
            ownLayerName: ownLayerName,
            ownObjectID: ownObjectID
        )
        self.engineRelease = WPESceneScriptLaneRelease(value: engine, queue: engine.queue)
        var prepared = Self.preprocess(script: script)
        // Normalize `let/const scriptProperties` → `var` only when injecting, so
        // the scene's overrides reach a reassignable global.
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let setupResult = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            initialValue: initialValue,
            initialize: initializationMode == .immediate,
            budget: setupBudget
        )
        remainingSetupBudget = max(0, setupBudget - (ProcessInfo.processInfo.systemUptime - setupStarted))
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
            case .setupFailed:
                throw WPESceneScriptError.scriptEvaluationFailed
            case let .ready(hasUpdate, initialResult, media):
                self.hasUpdateFunction = hasUpdate
                self.mediaHandlers = media
                // Applied here, not via a fake tick: `nil` (init returned nothing) leaves the authored value.
                if let initialResult { self.lastValue = initialResult }
            }
        }
    }

    func initializePreparedScript() throws {
        guard requiresInitialization, !isDestroyed else { return }
        requiresInitialization = false
        switch engine.initialize(initialValue: lastValue, budget: remainingSetupBudget) {
        case .timedOut:
            isPoisoned = true
            engine.instanceLimitToken?.failClosed(.executionTimedOut(operation: .setup))
            throw WPESceneScriptError.executionTimedOut
        case .capacityUnavailable:
            isPoisoned = true
            engine.instanceLimitToken?.failClosed(.capacityUnavailable(operation: .setup))
            throw WPESceneScriptError.capacityUnavailable(operation: .setup)
        case let .completed(outcome):
            switch outcome {
            case .contextUnavailable:
                isPoisoned = true
                throw WPESceneScriptError.contextUnavailable
            case .setupFailed:
                isPoisoned = true
                throw WPESceneScriptError.scriptEvaluationFailed
            case let .ready(hasUpdate, initialResult, media):
                hasUpdateFunction = hasUpdate
                mediaHandlers = media
                if let initialResult {
                    lastValue = initialResult
                }
            }
        }
    }

    @discardableResult
    func applyUserProperties(_ properties: [String: WPESceneScriptPropertyValue]) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !properties.isEmpty, engine.allows(.userProperties) else { return false }
        switch engine.applyUserProperties(properties, budget: tickBudget) {
        case .timedOut:
            isPoisoned = true
            return false
        case .capacityUnavailable:
            return false
        case let .completed(applied):
            return applied
        }
    }

    func dispatchMediaEvent(_ event: WPESceneMediaEvent, runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, handles(event), engine.allows(.event) else { return }
        if let index = pendingMediaEvents.firstIndex(where: { $0.handlerName == event.handlerName }) {
            pendingMediaEvents[index] = event
        } else {
            pendingMediaEvents.append(event)
        }
        flushPendingMediaEvents(runtimeSeconds: runtimeSeconds)
    }

    private func flushPendingMediaEvents(runtimeSeconds: Double?) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, engine.allows(.event) else { return }
        while let event = pendingMediaEvents.first {
            switch engine.dispatchMediaEvent(event, runtimeSeconds: runtimeSeconds, budget: tickBudget) {
            case .timedOut:
                isPoisoned = true
                pendingMediaEvents.removeAll()
                Logger.warning(
                    "SceneScript \(event.handlerName)() exceeded \(tickBudget)s — frozen",
                    category: .wpeRender
                )
                return
            case .capacityUnavailable:
                return
            case .completed:
                pendingMediaEvents.removeFirst()
            }
        }
    }

    func handles(_ event: WPESceneMediaEvent) -> Bool {
        mediaHandlers.handles(event)
    }

    /// Other-layer writes accumulated since the last call; nil when no evaluation has finished since.
    func takeLayerOutput() -> WPELayerScriptOutput? {
        engine.layerOutputs.takeLatest()
    }

    // MARK: Synchronous Oracle (DEBUG only)
    #if DEBUG
    func tickString(
        runtimeSeconds: Double? = nil
    ) -> String {
        guard !requiresInitialization, hasUpdateFunction, !isPoisoned, !isDestroyed,
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

    /// Mutation and one update() share the instance lane, then supersede so a stale tick cannot restore old text.
    @discardableResult
    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !properties.isEmpty,
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

    @discardableResult
    func resizeScreen(_ size: SIMD2<Double>) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, engine.allows(.event) else { return false }
        let budget = tickBudget * 2
        switch engine.resizeScreen(size, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Text SceneScript resizeScreen() exceeded \(budget)s — frozen", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    @discardableResult
    func applyGeneralSettings(language: String) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, engine.allows(.event) else { return false }
        let budget = tickBudget * 2
        switch engine.applyGeneralSettings(language: language, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Text SceneScript applyGeneralSettings() exceeded \(budget)s — frozen", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    @discardableResult
    func destroy() -> Bool {
        guard !isDestroyed else { return false }
        isDestroyed = true
        guard !requiresInitialization, !isPoisoned, engine.allows(.event) else {
            engine.discardPreparedResources()
            return false
        }
        let budget = tickBudget * 2
        switch engine.destroy(budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Text SceneScript destroy() exceeded \(budget)s", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    // MARK: Async Tick

    func seedAsyncTick(runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, hasUpdateFunction, !isPoisoned, !isDestroyed,
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
        guard !requiresInitialization, !isPoisoned, !isDestroyed else { return (lastValue, nil) }
        if let overrun = engine.quarantineAsyncIfOverdue(budget: tickBudget) {
            isPoisoned = true
            Logger.warning(
                "SceneScript \(overrun.operation.rawValue) exceeded \(tickBudget)s — frozen at its last value",
                category: .wpeRender
            )
            return (lastValue, nil)
        }
        flushPendingMediaEvents(runtimeSeconds: runtimeSeconds)
        guard !isPoisoned, hasUpdateFunction else { return (lastValue, nil) }
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
            case ready(hasUpdate: Bool, initialResult: String?, media: WPESceneMediaHandlerSet)
            case contextUnavailable
            case setupFailed
        }

        fileprivate var queue: DispatchQueue { executionLane.queue }
        fileprivate let executionLane: WPESceneScriptBatchDispatcher.Lane
        private let virtualMachine: JSVirtualMachine
        private var context: JSContext?
        /// Rewrites every `registerAudioBuffers` array from the shared audio
        /// broker at the top of each tick; nil until `setUp` builds the context.
        private var audioBridge: WPESceneScriptAudioBridge?
        fileprivate var timerScheduler: WPESceneScriptTimerScheduler?
        private var updateFunction: JSValue?
        private var didInitialize = false
        private var screenResolution: JSValue?
        private var lastRuntimeSeconds: Double?
        /// One-crossing clock updates; nil until setUp (then falls back to
        /// `wpeRefreshEngineClock` should construction ever fail).
        private var engineClockWriter: WPEEngineClockWriter?
        private let shared: WPESharedScriptState?
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let participant: WPESceneScriptExecutionGovernor.Participant
        let instanceLimitToken: WPESceneScriptInstanceLimitToken?
        let asyncExecutionSafety = WPESceneScriptAsyncExecutionSafety()
        private var didLogException = false
        fileprivate var didThrow = false
        private var faultPolicy = WPEScriptFaultPolicy()
        /// Scene render size, or nil to leave the sandbox's 1920x1080.
        private let canvasSize: SIMD2<Double>?
        private var screenSize: SIMD2<Double>?
        /// Layer side effects share the same journal as visible/transform hosts;
        /// the returned text value remains on this engine's string output path.
        private let layerBridge: WPELayerScriptBridge
        fileprivate let layerOutputs = WPESceneScriptOutcomeSlot<WPELayerScriptOutput>(
            combine: { WPELayerScriptInstance.mergedOutputs(pending: $0, newer: $1) }
        )

        init(
            shared: WPESharedScriptState?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher,
            canvasSize: SIMD2<Double>?,
            screenSize: SIMD2<Double>?,
            ownLayerName: String?,
            ownObjectID: String?
        ) {
            layerBridge = WPELayerScriptBridge(
                shared: shared,
                initialVisible: true,
                initialAlpha: 1,
                ownLayerName: ownLayerName,
                ownObjectID: ownObjectID,
                createdLayerBridge: nil,
                preservesOwnLayerWritesAfterFailure: true
            )
            self.canvasSize = canvasSize
            self.screenSize = screenSize.map { SIMD2(max($0.x, 1), max($0.y, 1)) }
            self.shared = shared
            self.governor = governor
            self.participant = governor.makeParticipant()
            self.instanceLimitToken = shared?.sceneScriptLoadToken
            let lane = shared?.executionLane(using: batchDispatcher) ?? batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
            layerBridge.configureOutputPublisher { [weak self] output, _ in
                self?.layerOutputs.publishEvent(output)
            }
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialValue: String,
            initialize: Bool,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.setUpOnQueue(
                    script: script,
                    scriptProperties: scriptProperties,
                    initialValue: initialValue,
                    initialize: initialize
                )
            }
        }

        func initialize(initialValue: String, budget: TimeInterval) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.layerBridge.beginEvaluation()
                defer { self.publishLayerOutput() }
                return self.initializeOnQueue(initialValue: initialValue)
            }
        }

        func discardPreparedResources() {
            queue.async { [self] in
                timerScheduler?.invalidate()
                layerBridge.releaseCreatedLayerResources()
            }
        }

        func applyUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue], budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.userProperties) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .userProperties, admission: .waitUntilDeadline) {
                self.layerBridge.beginEvaluation()
                defer { self.publishLayerOutput() }
                guard let context = self.context,
                      let function = context.objectForKeyedSubscript("applyUserProperties"),
                      !function.isUndefined, function.hasProperty("call"),
                      let bag = JSValue(newObjectIn: context) else { return false }
                for (name, value) in properties {
                    bag.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
                }
                self.didThrow = false
                _ = function.call(withArguments: [bag])
                return !self.didThrow
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

        func dispatchMediaEvent(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .failFast) {
                self.dispatchMediaEventOnQueue(event, runtimeSeconds: runtimeSeconds)
            }
        }

        func resizeScreen(
            _ size: SIMD2<Double>,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.resizeScreenOnQueue(size)
            }
        }

        func applyGeneralSettings(
            language: String,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.applyGeneralSettingsOnQueue(language: language)
            }
        }

        func destroy(budget: TimeInterval) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.destroyOnQueue()
            }
        }

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

        private func installCanvasSize(in context: JSContext) {
            guard let engine = context.objectForKeyedSubscript("engine"), engine.isObject else { return }
            if let canvasSize, let canvas = JSValue(newObjectIn: context) {
                update(canvas, x: canvasSize.x, y: canvasSize.y)
                engine.setObject(canvas, forKeyedSubscript: "canvasSize" as NSString)
            }
            if let screenSize, let screen = JSValue(newObjectIn: context) {
                update(screen, x: screenSize.x, y: screenSize.y)
                engine.setObject(screen, forKeyedSubscript: "screenResolution" as NSString)
                screenResolution = screen
            }
        }

        /// A quarantined evaluation publishes nothing, matching the string outcome's fence.
        private func publishLayerOutput() {
            layerBridge.finishEvaluation(commit: acceptsCompletion())
        }

        private func resizeScreenOnQueue(_ requestedSize: SIMD2<Double>) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            let size = SIMD2(max(requestedSize.x, 1), max(requestedSize.y, 1))
            guard size != screenSize else { return false }
            screenSize = size
            update(screenResolution, x: size.x, y: size.y)
            guard let context,
                  let function = context.objectForKeyedSubscript("resizeScreen"),
                  !function.isUndefined, function.hasProperty("call"),
                  let vectorType = context.objectForKeyedSubscript("Vec2"),
                  let argument = vectorType.construct(withArguments: [size.x, size.y]) else {
                return false
            }
            didThrow = false
            _ = function.call(withArguments: [argument])
            return !didThrow
        }

        private func applyGeneralSettingsOnQueue(language: String) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard let context,
                  let function = context.objectForKeyedSubscript("applyGeneralSettings"),
                  !function.isUndefined, function.hasProperty("call"),
                  let settings = JSValue(newObjectIn: context) else { return false }
            settings.setObject(language, forKeyedSubscript: "language" as NSString)
            didThrow = false
            _ = function.call(withArguments: [settings])
            return !didThrow
        }

        private func destroyOnQueue() -> Bool {
            layerBridge.beginEvaluation()
            defer { layerBridge.releaseCreatedLayerResources() }
            defer { publishLayerOutput() }
            var invoked = false
            if let context,
               let function = context.objectForKeyedSubscript("destroy"),
               !function.isUndefined, function.hasProperty("call") {
                didThrow = false
                _ = function.call(withArguments: [])
                invoked = !didThrow
            }
            timerScheduler?.invalidate()
            updateFunction = nil
            return invoked
        }

        private func setUpOnQueue(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialValue: String,
            initialize: Bool
        ) -> SetupOutcome {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
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
            layerBridge.installLayerBridge(in: context)
            engineClockWriter = WPEEngineClockWriter(context: context)
            _ = updateEngineRuntime(0)
            if let shared {
                wpeInstallSharedState(shared, in: context)
            }
            context.exceptionHandler = { [weak self] _, ex in
                guard let self else { return }
                didThrow = true
                layerBridge.failEvaluation()
                guard !didLogException else { return }
                didLogException = true
                Logger.warning(
                    "Text SceneScript raised an uncaught JS exception — keeping last value; retries back off exponentially (logged once): \(ex?.toString() ?? "unknown")",
                    category: .wpeRender
                )
            }
            _ = context.evaluateScript(wpeLowerBuiltinImports(script, in: context, acceptsCompletion: acceptsCompletion))
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

            let updateValue = context.objectForKeyedSubscript("update")
            if let updateValue, !updateValue.isUndefined, updateValue.hasProperty("call") {
                updateFunction = updateValue
            } else {
                updateFunction = nil
            }
            if initialize {
                return initializeOnQueue(initialValue: initialValue)
            }
            return .ready(hasUpdate: updateFunction != nil || timerScheduler.hasPendingTimers, initialResult: nil,
                          media: WPESceneMediaHandlerSet(in: context))
        }

        private func initializeOnQueue(initialValue: String) -> SetupOutcome {
            guard let context else { return .contextUnavailable }
            guard !didInitialize else {
                return .ready(hasUpdate: updateFunction != nil || timerScheduler?.hasPendingTimers == true,
                              initialResult: nil, media: WPESceneMediaHandlerSet(in: context))
            }
            didInitialize = true
            didThrow = false
            // Call init with the authored value; a missing argument leaves audio templates multiplying by undefined.
            var initialResult: String?
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                let seed = JSValue(object: initialValue, in: context) ?? JSValue(undefinedIn: context)!
                initialResult = Self.coercedResult(initFn.call(withArguments: [seed as Any]))
            }
            return .ready(
                hasUpdate: updateFunction != nil || timerScheduler?.hasPendingTimers == true,
                initialResult: initialResult,
                media: WPESceneMediaHandlerSet(in: context)
            )
        }

        /// Keyed by handler name, so a throwing `mediaPropertiesChanged` backs
        /// off alone and never gates `update()` or the other media handler.
        private func dispatchMediaEventOnQueue(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?
        ) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return false }
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else { return false }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: event.handlerName, at: now) else {
                return false
            }
            didThrow = false
            WPEFrameOccupancyMeter.count(.jscCall)
            _ = fn.call(withArguments: [wpeMediaEventObject(event, in: context)])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: event.handlerName, at: now)
                return false
            }
            faultPolicy.recordSuccess(entryPoint: event.handlerName)
            return true
        }

        private func tickOnQueue(
            lastValue: String,
            runtimeSeconds: Double?
        ) -> String? {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            audioBridge?.refresh()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return nil }
            guard let context, let updateFunction else { return nil }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return nil }
            let arg = JSValue(object: lastValue, in: context) ?? JSValue(nullIn: context)!
            didThrow = false
            WPEFrameOccupancyMeter.count(.jscCall)
            let result = updateFunction.call(withArguments: [arg as Any])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: "update", at: now)
                return nil
            }
            faultPolicy.recordSuccess(entryPoint: "update")
            return Self.coercedResult(result)
        }

        /// init and update must coerce identically — a second, looser path is how the two drift apart.
        static func coercedResult(_ result: JSValue?) -> String? {
            guard let result, !result.isUndefined, !result.isNull else {
                return nil
            }
            if result.isString, let s = result.toString() {
                return s
            }
            if result.isNumber {
                // isNumber is true for NaN/±Infinity too; String(nan) would be drawn and latched into lastValue.
                let number = result.toDouble()
                return number.isFinite ? String(number) : nil
            }
            return nil
        }

        private func updateEngineRuntime(_ runtimeSeconds: Double?) -> Double? {
            guard let context else { return nil }
            let supplied = runtimeSeconds.flatMap { $0.isFinite ? $0 : nil }
            let runtime = max(lastRuntimeSeconds ?? 0, supplied ?? lastRuntimeSeconds ?? 0)
            let frameTime = lastRuntimeSeconds.map { max(runtime - $0, 0) } ?? 0
            lastRuntimeSeconds = runtime
            if let engineClockWriter {
                engineClockWriter.refresh(runtime: runtime, frameTime: frameTime)
            } else {
                wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
            }
            return supplied == nil ? nil : runtime
        }

        deinit {
            timerScheduler?.invalidate()
        }

    }

    /// Lower built-in module bindings before evaluating in a non-module context.
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
        return s
    }

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
        // Official IConsole.error is variadic and returns void. Keep authored diagnostics observable
        // without changing the existing console.log policy or turning a logged error into a JS exception.
        let error: @convention(block) (String) -> Void = { message in
            Logger.authoredScriptError(String(message.prefix(2048)))
        }
        let installError = context.evaluateScript("""
        (function (writeError) {
            console.error = function (...args) { writeError(args.map(String).join(' ')); };
        })
        """)
        installError?.call(withArguments: [error])

        context.setObject(
            WPESceneScriptContextBeacon(),
            forKeyedSubscript: "__contextBeacon" as NSString
        )

        let engine = JSValue(newObjectIn: context)!
        let getTimeOfDay: @convention(block) () -> Double = {
            // Deliberately not wpeDayFraction(): that also consults the oracle frame override, which this legacy API never did.
            wpeDayFraction(of: WPEOracleMode.isEnabled ? WPEOracleMode.frozenWallClock : Date())
        }
        engine.setObject(getTimeOfDay, forKeyedSubscript: "getTimeOfDay" as NSString)
        engine.setObject(getTimeOfDay(), forKeyedSubscript: "timeOfDay" as NSString)
        // userProperties must exist even when empty: engine.userProperties.foo on undefined throws out of update().
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
        // `openUserShortcut` stub must exist (an undefined call throws out of cursorClick mid-handler).
        let openUserShortcut: @convention(block) (String) -> Bool = { _ in false }
        engine.setObject(openUserShortcut, forKeyedSubscript: "openUserShortcut" as NSString)
        // isRunningInEditor is always false here; an undefined call throws and discards the rest of update().
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
        let storageDelete: @convention(block) (String) -> Bool = { key in
            let existed = storageBacking[key] != nil
            storageBacking.removeObject(forKey: key)
            return existed
        }
        let storageClear: @convention(block) () -> Void = { storageBacking.removeAllObjects() }
        // Install order is observable: WPE's Object.keys(localStorage) is exactly set,get,delete,clear.
        storage.setObject(storageSet, forKeyedSubscript: "set" as NSString)
        storage.setObject(storageGet, forKeyedSubscript: "get" as NSString)
        storage.setObject(storageDelete, forKeyedSubscript: "delete" as NSString)
        storage.setObject(storageClear, forKeyedSubscript: "clear" as NSString)
        for (name, value) in [("LOCATION_GLOBAL", "global"), ("LOCATION_SCREEN", "screen")] {
            storage.defineProperty(name as NSString, descriptor: [
                JSPropertyDescriptorValueKey: value,
                JSPropertyDescriptorWritableKey: true,
                JSPropertyDescriptorConfigurableKey: true,
                JSPropertyDescriptorEnumerableKey: false,
            ])
        }
        context.setObject(storage, forKeyedSubscript: "localStorage" as NSString)
        context.setObject(storage, forKeyedSubscript: "localstorage" as NSString)

        let createScriptProperties: @convention(block) () -> JSValue? = { [weak context] in
            guard let context, let proxy = JSValue(newObjectIn: context) else {
                return nil
            }
            // add* exposes default value on scriptProperties; use currentThis (not capture) to avoid a JSC retain cycle.
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

/// JSC validates each candidate's preceding program without executing it.
/// Incomplete string/regex/template/function prefixes cannot be top-level
/// declarations; a line-comment prefix also accepts an otherwise illegal '@'.
func wpeLowerBuiltinImports(
    _ script: String,
    in context: JSContext,
    acceptsCompletion: () -> Bool = { true }
) -> String {
    let identifier = #"[$_\p{L}][$_\p{L}\p{N}]*"#
    let trivia = #"(?:\s|/\*[\s\S]*?\*/|//[^\n]*(?:\n|$))*"#
    let separator = #"(?:\s|/\*[\s\S]*?\*/|//[^\n]*(?:\n|$))+"#
    let namespace = #"\*"# + trivia + "as" + separator + identifier
    let named = #"\{(?:/\*[\s\S]*?\*/|//[^\n]*(?:\n|$)|[^}])*\}"#
    guard let declaration = try? NSRegularExpression(
        pattern: #"(?<![$_\p{L}\p{N}])import"# + trivia
            + "(?:(" + namespace + separator + "|" + named + ")" + trivia + "from" + trivia + ")?"
            + #"(['"])(WEMath|WEColor)\2("# + trivia + ");?"
    ) else { return script }
    func compiles(_ prefix: String) -> Bool {
        let units = Array(prefix.utf16)
        guard let text = units.withUnsafeBufferPointer({ JSStringCreateWithCharacters($0.baseAddress, $0.count) }) else { return false }
        defer { JSStringRelease(text) }
        var exception: JSValueRef?
        return JSCheckScriptSyntax(context.jsGlobalContextRef, text, nil, 1, &exception)
    }
    let source = NSMutableString(string: script)
    var cursor = 0
    var candidates = 0
    var inspectedPrefixUnits = 0
    while cursor < source.length,
          let match = declaration.firstMatch(
              in: source as String, range: NSRange(location: cursor, length: source.length - cursor)
          ) {
        candidates += 1
        // Prefixes are compiled twice at most. Bound the extra parsing work;
        // the existing setup deadline/quarantine still contains a slow JSC parse.
        inspectedPrefixUnits += (match.range.location + 1) * 2
        guard candidates <= 128, inspectedPrefixUnits <= 1_048_576 else {
            return "throw new RangeError('Built-in import preparation limit exceeded');"
        }
        guard acceptsCompletion() else {
            return "throw new Error('Built-in import preparation was cancelled');"
        }
        let trailing = source.substring(with: match.range(at: 4))
        let terminated = source.substring(with: match.range).hasSuffix(";")
            || NSMaxRange(match.range) == source.length
            || ["\n", "\r", "\u{2028}", "\u{2029}"].contains(where: trailing.contains)
        guard terminated else {
            cursor = NSMaxRange(match.range)
            continue
        }
        let prefix = source.substring(to: match.range.location)
        guard compiles(prefix), !compiles(prefix + "@") else {
            cursor = NSMaxRange(match.range)
            continue
        }
        let module = source.substring(with: match.range(at: 3))
        let binding = match.range(at: 1)
        let lowered: String? = if binding.location == NSNotFound {
            ";"
        } else {
            wpeBuiltinImportBindings(source.substring(with: binding), module: module, identifier: identifier)
        }
        guard let lowered else {
            cursor = NSMaxRange(match.range)
            continue
        }
        source.replaceCharacters(in: match.range, with: lowered)
        cursor = match.range.location + (lowered as NSString).length
    }
    return source as String
}

private func wpeBuiltinImportBindings(_ binding: String, module: String, identifier: String) -> String? {
    let binding = binding.replacingOccurrences(
        of: #"/\*[\s\S]*?\*/|//[^\n]*(?:\n|$)"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    if binding.hasPrefix("*") {
        guard let regex = try? NSRegularExpression(pattern: #"^\*\s*as\s+("# + identifier + ")$"),
              let match = regex.firstMatch(in: binding, range: NSRange(binding.startIndex..., in: binding)) else { return nil }
        return "var " + (binding as NSString).substring(with: match.range(at: 1)) + " = " + module + ";"
    }
    if binding.hasPrefix("{") {
        let inner = binding.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return ";"
        }
        var members = inner.split(separator: ",", omittingEmptySubsequences: false)
        if members.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            members.removeLast()
        }
        guard !members.isEmpty else { return nil }
        var lowered: [String] = []
        let pattern = "^(" + identifier + #")(?:\s+as\s+("# + identifier + "))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for member in members {
            let member = member.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: member, range: NSRange(member.startIndex..., in: member)) else { return nil }
            let source = member as NSString
            let name = source.substring(with: match.range(at: 1))
            let alias = match.range(at: 2).location == NSNotFound ? name : source.substring(with: match.range(at: 2))
            lowered.append("var " + alias + " = " + module + "." + name + ";")
        }
        return lowered.joined()
    }
    return nil
}

enum WPESceneScriptError: Error, Equatable {
    case contextUnavailable
    /// No process-wide execution permit was available, so setup was not
    /// dispatched and no JavaScriptCore worker/context was touched.
    case capacityUnavailable(operation: WPESceneScriptOperation)
    /// The script exceeded its wall-clock execution budget (runaway loop);
    /// the instance was disabled before it could hang the render thread.
    case executionTimedOut
    case scriptEvaluationFailed
}

#if DEBUG
/// Queue-confined oracle input, not a settings patch or a script callback.
func wpeInjectOracleUserProperties(
    _ properties: [String: WPESceneScriptPropertyValue],
    in context: JSContext?,
    on queue: DispatchQueue
) -> [String: WPESceneScriptPropertyValue]? {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let context,
          let bag = context.objectForKeyedSubscript("engine")?.objectForKeyedSubscript("userProperties"),
          bag.isObject else { return nil }
    for (name, value) in properties {
        bag.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
    }
    var receipt: [String: WPESceneScriptPropertyValue] = [:]
    for name in properties.keys {
        guard let value = bag.objectForKeyedSubscript(name) else { return nil }
        if value.isBoolean {
            receipt[name] = .bool(value.toBool())
        } else if value.isNumber {
            receipt[name] = .number(value.toDouble())
        } else if value.isString, let text = value.toString() {
            receipt[name] = .string(text)
        } else {
            return nil
        }
    }
    return context.exception == nil ? receipt : nil
}
#endif

extension WPESceneScriptPropertyValue {
    var jsBridged: Any {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value
        case .string(let value): return value
        }
    }

    /// Re-type a scene override to match what the script declared; createScriptProperties() is the type authority.
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
    /// Parent object id — `getChildren()` matches on this, not the name,
    /// which can repeat across layers.
    let parentID: String?
    let alignment: String
    let parallaxDepth: SIMD2<Double>
    let isParticleSystem: Bool
    let particleInstanceSeed: WPEParticleInstanceValues
    /// Resolved own presentation seeds; initialConfiguration retains authored envelopes.
    let initialVisible: Bool?
    let initialAlpha: Double?
    /// Complete load-time configuration, never synthesized from mutable layer state.
    let initialConfiguration: WPESceneJSONValue?

    init(
        id: String,
        name: String,
        size: SIMD2<Double>,
        origin: SIMD2<Double>,
        originZ: Double = 0,
        scale: SIMD3<Double> = SIMD3<Double>(repeating: 1),
        angles: SIMD3<Double> = .zero,
        index: Int,
        parentName: String?,
        parentID: String? = nil,
        alignment: String = "center",
        parallaxDepth: SIMD2<Double> = .zero,
        isParticleSystem: Bool = false,
        particleInstanceSeed: WPEParticleInstanceValues = .init(),
        initialVisible: Bool? = nil,
        initialAlpha: Double? = nil,
        initialConfiguration: WPESceneJSONValue? = nil
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
        self.parentID = parentID
        self.alignment = alignment
        self.parallaxDepth = parallaxDepth
        self.isParticleSystem = isParticleSystem
        self.particleInstanceSeed = particleInstanceSeed
        self.initialVisible = initialVisible
        self.initialAlpha = initialAlpha
        self.initialConfiguration = initialConfiguration
    }
}

struct WPESceneScriptLayerOrderSnapshot: Sendable, Equatable {
    fileprivate let stateIdentity: UUID
    let objectIDs: [String]
    let revision: UInt64
    let hasOverride: Bool
}

final class WPESharedScriptState: @unchecked Sendable {
    let sceneScriptLoadToken: WPESceneScriptInstanceLimitToken?
    let userProperties: [String: WPESceneScriptPropertyValue]
    let layers: [WPESceneScriptLayerInfo]
    let timelineAnimations = WPESceneTimelineStore()
    private let ambiguousLayerNames: Set<String>
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    private let executionLaneLock = NSLock()
    private var sharedExecutionLane: WPESceneScriptBatchDispatcher.Lane?
    private final class BridgeReference {
        weak var value: WPELayerScriptBridge?
        init(_ value: WPELayerScriptBridge) {
            self.value = value
        }
    }

    // Queue-confined. References are weak so shared functions cannot keep a
    // retired engine or its context alive through the host bridge registry.
    private var bridges: [ObjectIdentifier: BridgeReference] = [:]
    private var contextBridges: [UInt: BridgeReference] = [:]
    private var bridgeDependencies: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
    private var evaluationOwners: [BridgeReference] = []
    private var evaluationParticipants: [BridgeReference] = []
    private var evaluationParticipantIDs: Set<ObjectIdentifier> = []
    private var evaluationFailed = false

    func registerScriptBridge(_ bridge: WPELayerScriptBridge, in context: JSContext) {
        let identity = ObjectIdentifier(bridge)
        if bridges[identity]?.value == nil {
            bridgeDependencies[identity] = []
        }
        let reference = BridgeReference(bridge)
        bridges[identity] = reference
        contextBridges[UInt(bitPattern: context.jsGlobalContextRef)] = reference
    }

    func beginScriptEvaluation(_ bridge: WPELayerScriptBridge) {
        if evaluationOwners.isEmpty {
            evaluationFailed = false
            evaluationParticipants.removeAll(keepingCapacity: true)
            evaluationParticipantIDs.removeAll(keepingCapacity: true)
        }
        evaluationOwners.append(BridgeReference(bridge))
        enlistScriptBridge(bridge)
    }

    private func enlistScriptBridge(_ bridge: WPELayerScriptBridge) {
        var pending = [bridge]
        while let next = pending.popLast() {
            let identity = ObjectIdentifier(next)
            guard evaluationParticipantIDs.insert(identity).inserted else { continue }
            evaluationParticipants.append(BridgeReference(next))
            next.beginLocalEvaluation()
            for dependency in bridgeDependencies[identity] ?? [] {
                if let value = bridges[dependency]?.value {
                    pending.append(value)
                }
            }
        }
    }

    func failScriptEvaluation() {
        evaluationFailed = true
    }

    func finishScriptEvaluation(commit: Bool) {
        guard let owner = evaluationOwners.popLast() else { return }
        if !commit {
            evaluationFailed = true
        }
        guard evaluationOwners.isEmpty else { return }
        if !evaluationFailed {
            refreshLiveScriptSnapshots()
        }
        let accepted = !evaluationFailed && (sceneScriptLoadToken?.acceptsCompletion() ?? true)
        for participant in evaluationParticipants {
            guard let bridge = participant.value else { continue }
            bridge.finishLocalEvaluation(commit: accepted, ownsEntry: bridge === owner.value)
        }
        evaluationParticipants.removeAll(keepingCapacity: true)
        evaluationParticipantIDs.removeAll(keepingCapacity: true)
    }

    private func registerScriptRead(_ publisher: WPELayerScriptBridge?, in context: JSContext) {
        guard let publisher, let consumer = contextBridges[UInt(bitPattern: context.jsGlobalContextRef)]?.value else { return }
        bridgeDependencies[ObjectIdentifier(consumer), default: []].insert(ObjectIdentifier(publisher))
        if !evaluationOwners.isEmpty {
            enlistScriptBridge(publisher)
        }
    }

    /// Functions retain their lexical context. All contexts sharing this scene's
    /// values must therefore share both its VM and its serial execution queue.
    func executionLane(using dispatcher: WPESceneScriptBatchDispatcher) -> WPESceneScriptBatchDispatcher.Lane {
        executionLaneLock.lock(); defer { executionLaneLock.unlock() }
        if let sharedExecutionLane {
            return sharedExecutionLane
        }
        let lane = dispatcher.reserveLane()
        sharedExecutionLane = lane
        return lane
    }

    private var liveLayerTransformsByID: [String: LiveLayerTransform] = [:]
    private var cursorProjectionMatrix: [Double]?
    private var inverseCursorProjection: simd_double4x4?
    private var cursorSceneMotion: WPESceneCameraMotionSample?

    // Kept separate from shared-value storage, whose lock may acquire the load token.
    // Order mutations always acquire completion permission before this lock.
    private let layerOrderLock = NSLock()
    private let layerOrderIdentity = UUID()
    private var authoredLayerOrder: [String]
    private var authoredLayerOrderOwners: Set<String> = []
    private var authoredLayerOrderRevision: UInt64 = 0
    private var authoredLayerOrderHasOverride = false

    var isAuthoredLayerOrderingEnabled: Bool {
        layerOrderLock.lock(); defer { layerOrderLock.unlock() }
        return !authoredLayerOrderOwners.isEmpty
    }

    /// The renderer must first prove independent authored images and visible-only owners.
    /// Single-owner created-layer sorting retains its existing bridge admission.
    @discardableResult
    func configureAuthoredLayerOrdering(ownerIDs: Set<String>) -> Bool {
        var configured = false
        let configure = {
            self.layerOrderLock.lock(); defer { self.layerOrderLock.unlock() }
            let identities = Set(self.authoredLayerOrder)
            guard self.authoredLayerOrderOwners.isEmpty, ownerIDs.count >= 2,
                  ownerIDs.isSubset(of: identities), identities.count == self.layers.count else { return }
            self.authoredLayerOrderOwners = ownerIDs
            configured = true
        }
        if let sceneScriptLoadToken {
            _ = sceneScriptLoadToken.withCompletionPermission(configure)
        } else {
            configure()
        }
        return configured
    }

    func authoredLayerOrderSnapshot() -> WPESceneScriptLayerOrderSnapshot {
        layerOrderLock.lock(); defer { layerOrderLock.unlock() }
        return .init(stateIdentity: layerOrderIdentity, objectIDs: authoredLayerOrder,
                     revision: authoredLayerOrderRevision, hasOverride: authoredLayerOrderHasOverride)
    }

    /// Rollback remains available after fail-close. Snapshots cannot cross load/state identity.
    @discardableResult
    func restoreAuthoredLayerOrder(_ snapshot: WPESceneScriptLayerOrderSnapshot) -> Bool {
        layerOrderLock.lock(); defer { layerOrderLock.unlock() }
        guard snapshot.stateIdentity == layerOrderIdentity,
              snapshot.revision <= authoredLayerOrderRevision else { return false }
        guard authoredLayerOrder != snapshot.objectIDs || authoredLayerOrderHasOverride != snapshot.hasOverride else { return true }
        authoredLayerOrder = snapshot.objectIDs
        authoredLayerOrderHasOverride = snapshot.hasOverride
        authoredLayerOrderRevision &+= 1
        return true
    }

    @discardableResult
    func moveAuthoredLayer(objectID: String, to index: Int, ownerID: String) -> Bool {
        var moved = false
        let move = {
            self.layerOrderLock.lock(); defer { self.layerOrderLock.unlock() }
            guard self.authoredLayerOrderOwners.contains(ownerID),
                  self.authoredLayerOrder.indices.contains(index),
                  let previous = self.authoredLayerOrder.firstIndex(of: objectID) else { return }
            if previous != index {
                self.authoredLayerOrder.remove(at: previous)
                self.authoredLayerOrder.insert(objectID, at: index)
                self.authoredLayerOrderRevision &+= 1
                self.authoredLayerOrderHasOverride = true
            }
            moved = true
        }
        if let sceneScriptLoadToken {
            _ = sceneScriptLoadToken.withCompletionPermission(move)
        } else {
            move()
        }
        return moved
    }

    func orderedLayerInfos() -> [WPESceneScriptLayerInfo] {
        layerOrderLock.lock()
        let enabled = !authoredLayerOrderOwners.isEmpty
        let order = authoredLayerOrder
        layerOrderLock.unlock()
        guard enabled else { return layers }
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    private var staticCameraState = WPEStaticCameraScriptSnapshot()

    /// Resolved `general.cameraparallax*` (with user-prop envelopes folded) so
    /// `thisScene.cameraparallaxamount` & friends see the same values the
    /// renderer uses. Patched live by incremental general-field bindings.
    private var cameraParallaxSettings = WPESceneCameraParallaxSettings.disabled

    func seedCameraParallax(_ settings: WPESceneCameraParallaxSettings) {
        lock.lock(); defer { lock.unlock() }
        cameraParallaxSettings = settings
    }

    func cameraParallaxSnapshot() -> WPESceneCameraParallaxSettings {
        lock.lock(); defer { lock.unlock() }
        return cameraParallaxSettings
    }

    func updateCameraParallax(_ update: (inout WPESceneCameraParallaxSettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        update(&cameraParallaxSettings)
    }

    func seedStaticCamera(_ camera: WPESceneCamera, allowsMutation: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        staticCameraState = .init(transforms: .init(eye: camera.eye, center: camera.center, up: camera.up, zoom: 1), allowsMutation: allowsMutation)
    }

    func staticCameraSnapshot() -> WPEStaticCameraScriptSnapshot {
        lock.lock(); defer { lock.unlock() }
        return staticCameraState
    }

    func restoreStaticCamera(_ snapshot: WPEStaticCameraScriptSnapshot) {
        lock.lock(); defer { lock.unlock() }
        staticCameraState = snapshot
    }

    func publishStaticCamera(_ transforms: WPEScriptCameraTransforms) {
        lock.lock(); defer { lock.unlock() }
        guard sceneScriptLoadToken?.acceptsCompletion() ?? true else { return }
        guard staticCameraState.allowsMutation else { return }
        staticCameraState = .init(transforms: transforms, hasOverride: true)
    }

    /// Observed WPE 2.8 3D compatibility behavior: cursorWorldPosition is a
    /// point on the camera's far plane, not a ray hit or a canvas pixel. The
    /// public API documents only the 2D case. Use the rendered reversed-Z
    /// matrix so camera pose, FOV, aspect and clip distances stay consistent.
    func setCursorWorldProjection(_ matrix: [Double]?, sceneMotion: WPESceneCameraMotionSample? = nil) {
        lock.lock(); defer { lock.unlock() }
        cursorSceneMotion = matrix == nil ? sceneMotion : nil
        guard matrix != cursorProjectionMatrix else { return }
        cursorProjectionMatrix = matrix
        inverseCursorProjection = nil
        guard let matrix, matrix.count == 16, matrix.allSatisfy(\.isFinite) else { return }
        let projection = simd_double4x4(
            SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]),
            SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
            SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]),
            SIMD4(matrix[12], matrix[13], matrix[14], matrix[15])
        )
        guard abs(simd_determinant(projection)) > Double.leastNormalMagnitude else { return }
        inverseCursorProjection = simd_inverse(projection)
    }

    func cursorWorldPosition(pointer: SIMD2<Double>, canvasSize: SIMD2<Double>, fallbackZ: Double = 0) -> SIMD3<Double> {
        if let projected = projectedCursorWorldPosition(pointer: pointer) {
            return projected
        }
        lock.lock()
        let motion = cursorSceneMotion
        lock.unlock()
        let screen = SIMD2(pointer.x * canvasSize.x, (1 - pointer.y) * canvasSize.y)
        guard let motion else { return SIMD3(screen.x, screen.y, fallbackZ) }
        // Zoom pivots about the canvas centre.
        return WPECameraMotionProjection.cursor(pointer: pointer, size: canvasSize, motion: motion)
            ?? SIMD3(screen.x, screen.y, fallbackZ)
    }

    func projectedCursorWorldPosition(pointer: SIMD2<Double>) -> SIMD3<Double>? {
        lock.lock()
        let inverse = inverseCursorProjection
        lock.unlock()
        guard let inverse else { return nil }
        let point = inverse * SIMD4(pointer.x * 2 - 1, 1 - pointer.y * 2, 0, 1)
        guard point.w.isFinite, abs(point.w) > Double.leastNormalMagnitude else { return nil }
        let world = SIMD3(point.x, point.y, point.z) / point.w
        return world.x.isFinite && world.y.isFinite && world.z.isFinite ? world : nil
    }

    // Separate from shared-value storage: shared.set checks the token while
    // holding its own lock; particle commits hold the token before this lock.
    private let particleLock = NSLock()
    private let videoLock = NSLock()
    private var videoPlaybackByID: [String: WPEVideoPlaybackSnapshot] = [:]
    private var videoSourceKeyByID: [String: String] = [:]

    func publishVideoPlayback(_ snapshots: [String: WPEVideoPlaybackSnapshot], sourceKeys: [String: String]? = nil) {
        videoLock.lock(); defer { videoLock.unlock() }
        videoPlaybackByID = snapshots
        if let sourceKeys {
            videoSourceKeyByID = sourceKeys
        }
    }

    func videoPlaybackSnapshot(objectID: String) -> WPEVideoPlaybackSnapshot? {
        videoLock.lock(); defer { videoLock.unlock() }
        return videoPlaybackByID[objectID]
    }

    func videoSourceKey(objectID: String) -> String? {
        videoLock.lock(); defer { videoLock.unlock() }
        return videoSourceKeyByID[objectID]
    }

    private var particlePlaybackByID: [String: WPEParticlePlaybackSnapshot] = [:]
    private var particleInstanceByID: [String: WPEParticleInstanceValues] = [:]

    func publishParticleInstanceValues(_ values: [String: WPEParticleInstanceValues]) {
        particleLock.lock(); defer { particleLock.unlock() }
        particleInstanceByID = values
    }

    func particleInstanceValues(objectID: String) -> WPEParticleInstanceValues {
        particleLock.lock(); defer { particleLock.unlock() }
        var result = particleInstanceByID[objectID]
            ?? layers.first(where: { $0.id == objectID })?.particleInstanceSeed ?? .init()
        for event in pendingParticleCommands where event.objectID == objectID {
            if case let .modify(mutation) = event.command {
                result.apply(mutation)
            }
        }
        return result
    }

    private var pendingParticleCommands: [WPESceneScriptParticleCommand] = []
    static let maximumPendingParticleCommands = 4096

    func publishParticlePlayback(_ snapshots: [String: WPEParticlePlaybackSnapshot]) {
        particleLock.lock(); defer { particleLock.unlock() }
        particlePlaybackByID = snapshots
    }

    func particlePlaybackSnapshot(objectID: String) -> WPEParticlePlaybackSnapshot? {
        particleLock.lock(); defer { particleLock.unlock() }
        return particlePlaybackByID[objectID]
    }

    func enqueueParticleCommands(_ commands: [WPESceneScriptParticleCommand]) {
        guard !commands.isEmpty else { return }
        var overflow = false
        let commit = {
            self.particleLock.lock(); defer { self.particleLock.unlock() }
            guard commands.count <= Self.maximumPendingParticleCommands - self.pendingParticleCommands.count else {
                overflow = true
                return
            }
            self.pendingParticleCommands.append(contentsOf: commands)
        }
        if let sceneScriptLoadToken {
            _ = sceneScriptLoadToken.withCompletionPermission(commit)
        } else {
            commit()
        }
        // Never re-enter the token while holding its completion lock.
        if overflow {
            sceneScriptLoadToken?.failClosed(.particleCommandLimitExceeded(limit: Self.maximumPendingParticleCommands))
        }
    }

    /// The renderer drains under the current load's completion permission.
    func drainParticleCommands() -> [WPESceneScriptParticleCommand] {
        particleLock.lock(); defer { particleLock.unlock() }
        defer { pendingParticleCommands.removeAll(keepingCapacity: true) }
        return pendingParticleCommands
    }

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
        authoredLayerOrder = layers.enumerated().sorted {
            $0.element.index == $1.element.index ? $0.offset < $1.offset : $0.element.index < $1.element.index
        }.map(\.element.id)
        var names: Set<String> = []
        var ambiguous: Set = [""]
        for layer in layers where !names.insert(layer.name).inserted {
            ambiguous.insert(layer.name)
        }
        ambiguousLayerNames = ambiguous
    }

    func layerHandleKey(_ info: WPESceneScriptLayerInfo) -> String {
        ambiguousLayerNames.contains(info.name) ? wpeScriptLayerIDKey(info.id) : info.name
    }

    func layerInfo(forHandleKey key: String) -> WPESceneScriptLayerInfo? {
        if let id = wpeScriptLayerObjectID(key) {
            return layers.first(where: { $0.id == id })
        }
        return layers.first(where: { $0.name == key })
    }

    func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        let value = storage[key]
        return (value as? WPESharedLiveScriptValue)?.hostSnapshot ?? (value is WPESharedLiveScriptValue ? nil : value)
    }

    fileprivate func scriptValue(_ key: String, in context: JSContext) -> Any? {
        lock.lock()
        let value = storage[key]
        lock.unlock()
        if let live = value as? WPESharedLiveScriptValue {
            guard live.virtualMachine === context.virtualMachine else { return nil }
            registerScriptRead(live.publisher, in: context)
            // A shared closure executes in its defining context. An init-only
            // animation controller never ticks its own clock, so give its
            // captured engine the caller's current frame before returning it.
            if let definingContext = live.value.context, definingContext !== context,
               let engine = context.objectForKeyedSubscript("engine"), !engine.isUndefined,
               let runtime = engine.objectForKeyedSubscript("runtime")?.toDouble(), runtime.isFinite,
               let frameTime = engine.objectForKeyedSubscript("frametime")?.toDouble(), frameTime.isFinite {
                wpeRefreshEngineClock(in: definingContext, runtime: runtime, frameTime: frameTime)
            }
            return live.value
        }
        return value
    }

    fileprivate func setScriptValue(_ key: String, _ value: JSValue, live: Bool, snapshot: JSValue) {
        if live {
            executionLaneLock.lock()
            let lane = sharedExecutionLane
            executionLaneLock.unlock()
            guard let lane, lane.virtualMachine === value.context.virtualMachine else { return }
            set(key, WPESharedLiveScriptValue(
                value: value, snapshot: snapshot, lane: lane,
                publisher: contextBridges[UInt(bitPattern: value.context.jsGlobalContextRef)]?.value
            ))
        } else {
            set(key, wpeBridgeJSValueToHost(value))
        }
    }

    /// Compute on the scene VM lane, publish only detached data under the host
    /// lock. Shared read fans never touch a JSValue from the render actor.
    func refreshLiveScriptSnapshots() {
        lock.lock()
        let live = storage.compactMap { key, value in
            (value as? WPESharedLiveScriptValue).map { (key, $0) }
        }
        lock.unlock()
        for (key, value) in live {
            guard let snapshot = value.snapshot() else { continue }
            lock.lock()
            if storage[key] as? WPESharedLiveScriptValue === value,
               sceneScriptLoadToken?.acceptsCompletion() ?? true {
                value.hostSnapshot = snapshot
            }
            lock.unlock()
        }
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

    /// Publish a detached snapshot; script lanes must not reach into renderer-owned dictionaries.
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
        return (info, liveTransform(id: info.id))
    }

    /// ID-keyed variant for a script's OWN layer: the name lookup above cannot
    /// see an unnamed object, and scene authors routinely leave text/widget
    /// layers unnamed.
    func layerTransform(id: String) -> (info: WPESceneScriptLayerInfo, transform: LiveLayerTransform)? {
        guard let info = layers.first(where: { $0.id == id }) else { return nil }
        return (info, liveTransform(id: id))
    }

    private func liveTransform(id: String) -> LiveLayerTransform {
        lock.lock()
        defer { lock.unlock() }
        return liveLayerTransformsByID[id] ?? LiveLayerTransform()
    }
}

/// The store is never exported to JS and every installed block captures it
/// weakly, so strong values preserve closures without a JS -> store cycle.
/// Final release remains on the owning lane, including a quarantined VM.
private final class WPESharedLiveScriptValue {
    weak var publisher: WPELayerScriptBridge?
    let virtualMachine: JSVirtualMachine
    private let queue: DispatchQueue
    private final class References {
        let value: JSValue
        let snapshotter: JSValue?
        init(value: JSValue, snapshotter: JSValue?) {
            self.value = value
            self.snapshotter = snapshotter
        }
    }

    private let references: WPESceneScriptLaneRelease<References>
    var value: JSValue {
        references.value.value
    }

    var hostSnapshot: Any?

    init(value: JSValue, snapshot: JSValue, lane: WPESceneScriptBatchDispatcher.Lane, publisher: WPELayerScriptBridge?) {
        self.publisher = publisher
        virtualMachine = lane.virtualMachine
        queue = lane.queue
        hostSnapshot = wpeBridgeJSValueToHost(snapshot)
        references = WPESceneScriptLaneRelease(value: References(
            value: value,
            snapshotter: snapshot.isUndefined ? nil : value.context.objectForKeyedSubscript("__sharedSnapshot")
        ), queue: lane.queue)
    }

    func snapshot() -> Any? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let function = references.value.snapshotter,
              let result = function.call(withArguments: [value]), !result.isUndefined else { return nil }
        return wpeBridgeJSValueToHost(result)
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

/// One `Calendar.dateComponents` per wall-clock second. Locked: script workers tick concurrently.
private let wpeDayFractionCache = OSAllocatedUnfairLock(
    initialState: (second: Int.min, value: 0.0)
)

private func wpeDayFraction(of date: Date) -> Double {
    let second = Int(date.timeIntervalSinceReferenceDate.rounded(.down))
    return wpeDayFractionCache.withLock { cache in
        if cache.second == second { return cache.value }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
        cache = (second: second, value: seconds / 86_400.0)
        return cache.value
    }
}

func wpeRefreshEngineClock(
    in context: JSContext?,
    runtime: Double,
    frameTime: Double
) {
    guard let engine = context?.objectForKeyedSubscript("engine"), !engine.isUndefined else { return }
    WPEFrameOccupancyMeter.count(.jscRead)
    WPEFrameOccupancyMeter.count(.jscSetObject, by: 3)
    engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
    engine.setObject(frameTime, forKeyedSubscript: "frametime" as NSString)
    engine.setObject(wpeDayFraction(), forKeyedSubscript: "timeOfDay" as NSString)
}

/// Assigns onto the exact targets objects, never replacing them, so script-held captures keep observing new values; nil → per-field fallback.
func wpeMakeHostTickHelper(
    in context: JSContext,
    factory: String,
    targets: [JSValue]
) -> JSValue? {
    // Must be a no-op block, not nil: JSC notifyException calls the handler unconditionally, so nil crashes on the first throw.
    let priorException = context.exception
    let priorHandler = context.exceptionHandler
    context.exceptionHandler = { _, _ in }
    defer {
        context.exception = priorException
        context.exceptionHandler = priorHandler
    }
    guard let factoryValue = context.evaluateScript(factory),
          factoryValue.isObject, factoryValue.hasProperty("call"),
          let helper = factoryValue.call(withArguments: targets),
          helper.isObject, helper.hasProperty("call") else {
        return nil
    }
    return helper
}

/// The helper reaches engine as a free variable, not a bound argument, so a script that replaces the global still gets the clock.
struct WPEEngineClockWriter {
    private let context: JSContext
    private let helper: JSValue?

    static let defaultFactory = """
    (function () { return function (rt, ft, tod) {
        engine.runtime = rt; engine.frametime = ft; engine.timeOfDay = tod;
    }; })
    """

    init?(context: JSContext, factory: String = WPEEngineClockWriter.defaultFactory) {
        guard context.objectForKeyedSubscript("engine")?.isUndefined == false else {
            return nil
        }
        self.context = context
        helper = wpeMakeHostTickHelper(in: context, factory: factory, targets: [])
    }

    var usesBatchedHelper: Bool { helper != nil }

    func refresh(runtime: Double, frameTime: Double) {
        if let helper {
            WPEFrameOccupancyMeter.count(.jscCall)
            helper.call(withArguments: [runtime, frameTime, wpeDayFraction()])
        } else {
            wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
        }
    }
}

func wpeInstallSharedState(_ store: WPESharedScriptState, in context: JSContext) {
    let get: @convention(block) (String) -> Any? = { [weak store, weak context] key in
        guard let context else { return nil }
        return store?.scriptValue(key, in: context)
    }
    let set: @convention(block) (String, JSValue, Bool, JSValue) -> Void = { [weak store] key, value, live, snapshot in
        store?.setScriptValue(key, value, live: live, snapshot: snapshot)
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
                        if (__sharedMutators[p] === 1) { __sharedPublish(rootKey, root); }
                        return __sharedWrap(rootKey, root, res);
                    };
                }
                return __sharedWrap(rootKey, root, v);
            },
            set: function(t, p, v) { t[p] = v; __sharedPublish(rootKey, root); return true; },
            deleteProperty: function(t, p) { delete t[p]; __sharedPublish(rootKey, root); return true; }
        });
    }
    function __sharedNeedsLive(v) {
        var queue = [v], seen = new WeakSet(), inspected = 0;
        for (var i = 0; i < queue.length; ++i) {
            var node = queue[i];
            if (typeof node === 'function') { return true; }
            if (node === null || typeof node !== 'object') { continue; }
            if (seen.has(node)) { return true; }
            seen.add(node);
            if (!Array.isArray(node) && Object.getPrototypeOf(node) !== Object.prototype) { return true; }
            var keys = Object.keys(node);
            inspected += keys.length;
            if (inspected > 16384) { throw new RangeError('shared value graph is too large'); }
            for (var k = 0; k < keys.length; ++k) {
                var descriptor = Object.getOwnPropertyDescriptor(node, keys[k]);
                if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) { return true; }
                queue.push(descriptor.value);
            }
        }
        return false;
    }
    function __sharedSnapshot(root) {
        if (typeof root === 'function') { return undefined; }
        var output = Array.isArray(root) ? [] : Object.create(null), queue = [[root, output]], seen = new WeakSet(), inspected = 0;
        seen.add(root);
        for (var i = 0; i < queue.length; ++i) {
            var source = queue[i][0], target = queue[i][1], keys = Object.keys(source);
            inspected += keys.length;
            if (inspected > 16384) { throw new RangeError('shared snapshot graph is too large'); }
            for (var k = 0; k < keys.length; ++k) {
                var key = keys[k], descriptor = Object.getOwnPropertyDescriptor(source, key);
                if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) { continue; }
                var value = descriptor.value;
                if (typeof value === 'function' || typeof value === 'undefined') { continue; }
                if (value !== null && typeof value === 'object') {
                    if (seen.has(value)) { continue; }
                    seen.add(value);
                    Object.defineProperty(target, key, {value: Array.isArray(value) ? [] : Object.create(null), enumerable: true, configurable: true, writable: true});
                    queue.push([value, target[key]]);
                } else if (value === null || typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
                    Object.defineProperty(target, key, {value: value, enumerable: true, configurable: true, writable: true});
                }
            }
        }
        return output;
    }
    function __sharedPublish(key, value) {
        var live = __sharedNeedsLive(value);
        __sharedSet(key, value, live, live ? __sharedSnapshot(value) : undefined);
    }
    var shared = new Proxy({}, {
        get: function(_t, k) {
            var v = __sharedGet(k);
            if (__sharedNeedsLive(v)) { return v; }
            return (v !== null && typeof v === 'object') ? __sharedWrap(k, v, v) : v;
        },
        set: function(_t, k, v) {
            __sharedPublish(k, v);
            return true;
        },
        has: function(_t, k) {
            return __sharedGet(k) !== undefined;
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
    private let queue: DispatchQueue
    private let virtualMachine: JSVirtualMachine
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

    private static let maxCachedContexts = 64

    private final class ExceptionFlag { var didThrow = false }
    private final class ResultBox: @unchecked Sendable { var value: SIMD3<Double>? }

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
        let queue = DispatchQueue(
            label: "com.livewallpaper.wpe-transform-evaluator",
            qos: .userInitiated
        )
        self.queue = queue
        virtualMachine = WPESceneScriptBatchDispatcher.makeVirtualMachine(on: queue)
    }

    // No deinit teardown on purpose: a worker that overran its budget still owns queue and may be executing JS on this VM.

    static func reportKeptBakedOrigins(count: Int, reason: String) {
        Logger.warning(
            "Static transform scripts unresolved (\(reason)) — \(count) object(s) keep their baked origin; scripted layout will be wrong",
            category: .wpeRender
        )
    }

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

    /// Must stay an override: the protocol default resolveBatch delegates to resolveVec3, so deleting this recurses.
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
        _ = context.evaluateScript(wpeLowerBuiltinImports(prepared, in: context, acceptsCompletion: { !self.isPoisoned }))
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
        // Set both canvasSize and screenResolution, or the sandbox's hardcoded 1920x1080 screenResolution survives and contradicts canvasSize.
        engine.setObject(size, forKeyedSubscript: "screenResolution" as NSString)
    }
}

final class WPEDynamicTransformScriptInstance: @unchecked Sendable {
    let ownObjectID: String?
    private let engineRelease: WPESceneScriptLaneRelease<Engine>
    private var engine: Engine { engineRelease.value }
    private let tickBudget: TimeInterval
    private var lastValue: SIMD3<Double>
    private var isPoisoned = false
    /// A module exporting only `init` (and cursor/media handlers) has nothing to
    /// run per frame. Ticking it anyway would publish `nil` on the next frame and
    /// snap the layer back off the value `init` returned.
    private var hasUpdateFunction: Bool
    private(set) var mediaHandlers: WPESceneMediaHandlerSet
    private var requiresInitialization: Bool
    private var remainingSetupBudget: TimeInterval
    private var isDestroyed = false
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<SIMD3<Double>?>()
    /// Latest completed inner result: nil mirrors the legacy "script returned no
    /// value this tick" contract (caller falls back to the baked transform).
    private var lastAsyncInner: SIMD3<Double>?
    private var hasAsyncOutcome = false
    private var pendingMediaEvents: [WPESceneMediaEvent] = []
    private let cursorInbox = WPELayerScriptCursorInbox()
    /// Cursor handlers the module exports; other events are never queued.
    private var cursorHandlers: Set<WPELayerScriptCursorEvent> = []
    /// The arity WPE authored for the bound property. Vec3 is the transform
    /// default; shader constants are usually scalars.
    private let valueShape: WPEScriptValueShape

    /// Narrows a ticked Vec3 back to that arity, so a scalar uniform gets a
    /// Number rather than a 3-component vector the shader would misread.
    func initializePreparedScript() throws {
        guard requiresInitialization, !isDestroyed else { return }
        requiresInitialization = false
        switch engine.initialize(budget: remainingSetupBudget) {
        case .timedOut:
            isPoisoned = true
            engine.instanceLimitToken?.failClosed(.executionTimedOut(operation: .setup))
            throw WPESceneScriptError.executionTimedOut
        case .capacityUnavailable:
            isPoisoned = true
            engine.instanceLimitToken?.failClosed(.capacityUnavailable(operation: .setup))
            throw WPESceneScriptError.capacityUnavailable(operation: .setup)
        case let .completed(outcome):
            switch outcome {
            case .contextUnavailable:
                isPoisoned = true
                throw WPESceneScriptError.contextUnavailable
            case .setupFailed:
                isPoisoned = true
                throw WPESceneScriptError.scriptEvaluationFailed
            case let .ready(hasUpdate, initialResult, media, cursor):
                hasUpdateFunction = hasUpdate
                mediaHandlers = media
                cursorHandlers = cursor
                if let initialResult {
                    lastValue = initialResult
                    lastAsyncInner = initialResult
                    hasAsyncOutcome = true
                }
            }
        }
    }

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
        screenSize: SIMD2<Double>? = nil,
        ownLayerName: String? = nil,
        ownObjectID: String? = nil,
        createdLayerBridge: WPECreatedLayerBridgeConfiguration? = nil,
        shared: WPESharedScriptState? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared,
        initializationMode: WPESceneScriptInitializationMode = .immediate
    ) throws {
        self.ownObjectID = ownObjectID
        requiresInitialization = initializationMode == .deferred
        remainingSetupBudget = setupBudget
        self.tickBudget = tickBudget
        self.valueShape = valueShape
        self.lastValue = seed
        let engine = Engine(
            seed: seed,
            valueShape: valueShape,
            canvasSize: canvasSize,
            screenSize: screenSize ?? canvasSize,
            ownLayerName: ownLayerName,
            ownObjectID: ownObjectID,
            createdLayerBridge: createdLayerBridge,
            shared: shared,
            governor: governor,
            batchDispatcher: batchDispatcher
        )
        self.engineRelease = WPESceneScriptLaneRelease(value: engine, queue: engine.queue)
        var prepared = WPESceneScriptInstance.preprocess(script: script)
        if !scriptProperties.isEmpty {
            prepared = wpeNormalizeScriptPropertiesDeclaration(prepared)
        }
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let setupResult = engine.setUp(
            script: prepared,
            scriptProperties: scriptProperties,
            initialize: initializationMode == .immediate,
            budget: setupBudget
        )
        remainingSetupBudget = max(0, setupBudget - (ProcessInfo.processInfo.systemUptime - setupStarted))
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
            case let .ready(hasUpdate, initialResult, media, cursor):
                self.mediaHandlers = media
                self.hasUpdateFunction = hasUpdate
                cursorHandlers = cursor
                // Publish init's return as the first completed outcome so the first frame does not show the baked transform; nil leaves the authored seed.
                if let initialResult {
                    lastValue = initialResult
                    lastAsyncInner = initialResult
                    hasAsyncOutcome = true
                }
            }
        }
    }

    func takeLayerOutput() -> WPELayerScriptOutput? {
        engine.layerOutputs.takeLatest()
    }

    func dispatchMediaEvent(_ event: WPESceneMediaEvent, runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault,
              mediaHandlers.handles(event), engine.allows(.event) else { return }
        switch engine.dispatchMediaEvent(
            event,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "Transform SceneScript \(event.handlerName)() exceeded \(tickBudget)s — frozen",
                category: .wpeRender
            )
        case .capacityUnavailable, .completed:
            break
        }
    }

    func liveDispatchMediaEvent(_ event: WPESceneMediaEvent, runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault,
              mediaHandlers.handles(event), engine.allows(.event) else { return }
        _ = engine.dispatchMediaEventAsync(event, runtimeSeconds: runtimeSeconds)
    }

    /// One drain's worth of events in one hop; see the layer runtime's batch
    /// entry for why per-event dispatch dropped everything after the first.
    func liveDispatchMediaEvents(_ events: [WPESceneMediaEvent], runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault else { return }
        for event in events where mediaHandlers.handles(event) {
            pendingMediaEvents.coalesce(event)
        }
        guard !pendingMediaEvents.isEmpty, engine.allows(.event) else { return }
        // A refused batch stays pending; the next frame's drain retries it.
        if engine.dispatchMediaEventsAsync(pendingMediaEvents, runtimeSeconds: runtimeSeconds) {
            pendingMediaEvents.removeAll(keepingCapacity: true)
        }
    }

    /// Property scripts export cursor handlers too (click-to-switch poses on an
    /// `angles` script, workshop 3809609151). Same bounded inbox as layer scripts.
    func enqueueCursorEvents(
        _ events: [WPELayerScriptCursorInvocation],
        allowSubmission: Bool = true
    ) -> WPESceneScriptBatchDispatcher.Job? {
        guard !requiresInitialization else { return nil }
        guard !isPoisoned, !isDestroyed, !engine.hasRuntimeFault, engine.allows(.event) else {
            cursorInbox.close()
            return nil
        }
        cursorInbox.append(events.filter { cursorHandlers.contains($0.event) })
        guard allowSubmission, let claim = cursorInbox.claim() else { return nil }
        return WPESceneScriptBatchDispatcher.Job(
            queue: engine.queue,
            work: engine.makeCursorBatch(claim: claim, inbox: cursorInbox)
        )
    }

    func cancelPendingCursorEvents() {
        cursorInbox.cancel()
    }


    // MARK: Synchronous Oracle (DEBUG only)
    #if DEBUG
    /// Oracle-only VM input with typed readback; does not evaluate the gate.
    func injectOracleUserProperties(
        _ properties: [String: WPESceneScriptPropertyValue]
    ) -> [String: WPESceneScriptPropertyValue]? {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault, !properties.isEmpty,
              engine.allows(.userProperties) else { return nil }
        switch engine.injectOracleUserProperties(properties, budget: tickBudget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Transform SceneScript oracle input injection exceeded its budget - frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(receipt):
            return engine.acceptsCompletion() ? receipt : nil
        }
    }

    func tick(
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> SIMD3<Double>? {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault else { return nil }
        guard hasUpdateFunction else { return hasAsyncOutcome ? lastValue : nil }
        guard engine.allows(.tick) else { return nil }
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

    @discardableResult
    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault, !properties.isEmpty,
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

    @discardableResult
    func resizeScreen(_ size: SIMD2<Double>) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault,
              engine.allows(.event) else { return false }
        let budget = tickBudget * 2
        switch engine.resizeScreen(size, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Transform SceneScript resizeScreen() exceeded \(budget)s — frozen", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    @discardableResult
    func applyGeneralSettings(language: String) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault,
              engine.allows(.event) else { return false }
        let budget = tickBudget * 2
        switch engine.applyGeneralSettings(language: language, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Transform SceneScript applyGeneralSettings() exceeded \(budget)s — frozen", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    @discardableResult
    func applyUserProperties(_ properties: [String: WPESceneScriptPropertyValue]) -> Bool {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault,
              engine.allows(.event) else { return false }
        let budget = tickBudget * 2
        switch engine.applyUserProperties(properties, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Transform SceneScript applyUserProperties() exceeded \(budget)s — frozen", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    @discardableResult
    func destroy() -> Bool {
        guard !isDestroyed else { return false }
        isDestroyed = true
        cursorInbox.close()
        guard !requiresInitialization, !isPoisoned, !engine.hasRuntimeFault,
              engine.allows(.event) else {
            engine.discardPreparedResources()
            return false
        }
        let budget = tickBudget * 2
        switch engine.destroy(budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Transform SceneScript destroy() exceeded \(budget)s", category: .wpeRender)
            return false
        case .capacityUnavailable:
            return false
        case let .completed(invoked):
            return engine.acceptsCompletion() && invoked
        }
    }

    // MARK: Async Tick

    func seedAsyncTick(pointerPosition: SIMD2<Double>, runtimeSeconds: Double? = nil) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault, hasUpdateFunction,
              engine.allows(.tick) else { return }
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

    func batchTick(
        pointerPosition: SIMD2<Double>,
        runtimeSeconds: Double? = nil
    ) -> (value: SIMD3<Double>?, job: WPESceneScriptBatchDispatcher.Job?) {
        guard !requiresInitialization, !isPoisoned, !isDestroyed, !engine.hasRuntimeFault else { return (nil, nil) }
        // Overdue check BEFORE the no-update return: an init-only module still
        // hosts media handlers, and a hung one must poison the instance rather
        // than keep its engine lane and governor permit occupied forever.
        if let overrun = engine.quarantineAsyncIfOverdue(budget: tickBudget) {
            isPoisoned = true
            Logger.warning(
                "Transform SceneScript \(overrun.operation.rawValue) exceeded \(tickBudget)s — frozen",
                category: .wpeRender
            )
            return (nil, nil)
        }
        // No `update` to run: hold whatever `init` returned rather than schedule a
        // per-frame job whose nil result would overwrite it.
        guard hasUpdateFunction else { return (hasAsyncOutcome ? lastValue : nil, nil) }
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

    private final class Engine: @unchecked Sendable, WPESceneScriptEngineExecutionGuarding, WPESceneScriptCanvasSizedEngine {
        enum SetupOutcome {
            case ready(
                hasUpdate: Bool,
                initialResult: SIMD3<Double>?,
                media: WPESceneMediaHandlerSet,
                cursor: Set<WPELayerScriptCursorEvent>
            )
            case contextUnavailable
            case setupFailed
        }

        fileprivate var queue: DispatchQueue { executionLane.queue }
        fileprivate let executionLane: WPESceneScriptBatchDispatcher.Lane
        private let virtualMachine: JSVirtualMachine
        private let seed: SIMD3<Double>
        private let valueShape: WPEScriptValueShape
        fileprivate let canvasSize: SIMD2<Double>
        fileprivate var screenSize: SIMD2<Double>
        private let ownLayerName: String?
        private let ownObjectID: String?
        private let shared: WPESharedScriptState?
        private let layerBridge: WPELayerScriptBridge
        fileprivate let layerOutputs = WPESceneScriptOutcomeSlot<WPELayerScriptOutput>(
            combine: { WPELayerScriptInstance.mergedOutputs(pending: $0, newer: $1) }
        )
        fileprivate let governor: WPESceneScriptExecutionGovernor
        fileprivate let participant: WPESceneScriptExecutionGovernor.Participant
        let instanceLimitToken: WPESceneScriptInstanceLimitToken?
        let asyncExecutionSafety = WPESceneScriptAsyncExecutionSafety()
        private var context: JSContext?
        /// Rewrites every `registerAudioBuffers` array from the shared audio
        /// broker at the top of each tick; nil until `setUp` builds the context.
        private var audioBridge: WPESceneScriptAudioBridge?
        fileprivate var timerScheduler: WPESceneScriptTimerScheduler?
        private var updateFunction: JSValue?
        fileprivate var screenResolution: JSValue?
        private var didInitialize = false
        private var cursorScreenPosition: JSValue?
        private var cursorWorldPosition: JSValue?
        /// One-crossing clock updates; nil until setUp (then falls back to
        /// `wpeRefreshEngineClock` should construction ever fail).
        private var engineClockWriter: WPEEngineClockWriter?
        /// Batched cursor write (one crossing for x/y/z, assigning onto the
        /// `cursorWorldPosition` object above); nil → per-field fallback.
        private var cursorHelper: JSValue?
        /// Reused `update(value)` argument for vec2/vec3. x/y/z are overwritten
        /// each tick (same shape as `cursorWorldPosition`).
        private var updateArgument: JSValue?
        private var lastRuntimeSeconds: Double?
        /// One diagnostic per instance, including the actual JS error and its authored source location.
        private var didLogException = false
        fileprivate var didThrow = false
        private var faultPolicy = WPEScriptFaultPolicy()
        /// Set on hard quarantine so callers can stop scheduling without a queue hop.
        private let runtimeFault = OSAllocatedUnfairLock(initialState: false)
        var hasRuntimeFault: Bool { runtimeFault.withLock { $0 } }

        init(
            seed: SIMD3<Double>,
            valueShape: WPEScriptValueShape,
            canvasSize: SIMD2<Double>,
            screenSize: SIMD2<Double>,
            ownLayerName: String?,
            ownObjectID: String?,
            createdLayerBridge: WPECreatedLayerBridgeConfiguration?,
            shared: WPESharedScriptState?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher
        ) {
            let lane = shared?.executionLane(using: batchDispatcher) ?? batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
            self.seed = seed
            self.valueShape = valueShape
            self.canvasSize = canvasSize
            self.screenSize = SIMD2(max(screenSize.x, 1), max(screenSize.y, 1))
            self.ownLayerName = ownLayerName
            self.ownObjectID = ownObjectID
            self.shared = shared
            layerBridge = WPELayerScriptBridge(
                shared: shared, initialVisible: true, initialAlpha: 1,
                ownLayerName: ownLayerName, ownObjectID: ownObjectID,
                createdLayerBridge: createdLayerBridge, readsLiveTransforms: true
            )
            self.governor = governor
            participant = governor.makeParticipant()
            instanceLimitToken = shared?.sceneScriptLoadToken
            layerBridge.configureOutputPublisher { [weak self] output, _ in
                self?.layerOutputs.publishEvent(output)
            }
        }

        func setUp(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialize: Bool,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.setUpOnQueue(script: script, scriptProperties: scriptProperties, initialize: initialize)
            }
        }

        func initialize(budget: TimeInterval) -> WPESceneScriptBoundedExecutionResult<SetupOutcome> {
            guard allows(.setup) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline) {
                self.layerBridge.beginEvaluation()
                defer { self.publishLayerOutput() }
                return self.initializeOnQueue()
            }
        }

        func discardPreparedResources() {
            queue.async { [self] in
                timerScheduler?.invalidate()
                layerBridge.releaseCreatedLayerResources()
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

        #if DEBUG
        func injectOracleUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<[String: WPESceneScriptPropertyValue]?> {
            guard allows(.userProperties) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .userProperties, admission: .waitUntilDeadline) {
                guard self.acceptsCompletion() else { return nil }
                let receipt = wpeInjectOracleUserProperties(properties, in: self.context, on: self.queue)
                return self.acceptsCompletion() ? receipt : nil
            }
        }
        #endif

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

        func dispatchMediaEvent(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Void> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .failFast) {
                self.dispatchMediaEventOnQueue(event, runtimeSeconds: runtimeSeconds)
            }
        }

        func dispatchMediaEventAsync(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?
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
                self.dispatchMediaEventOnQueue(event, runtimeSeconds: runtimeSeconds)
            }
            return true
        }

        /// Batch the whole drain in one hop: one-at-a-time admitted only the first event of a cold-start burst and dropped the rest.
        func dispatchMediaEventsAsync(
            _ events: [WPESceneMediaEvent],
            runtimeSeconds: Double?
        ) -> Bool {
            guard !events.isEmpty, allows(.event) else { return false }
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
                for event in events {
                    self.dispatchMediaEventOnQueue(event, runtimeSeconds: runtimeSeconds)
                }
            }
            return true
        }

        /// Mirrors the layer engine's `makeCursorBatch`.
        func makeCursorBatch(
            claim: WPELayerScriptCursorInbox.Claim,
            inbox: WPELayerScriptCursorInbox
        ) -> @Sendable () -> Void {
            { @Sendable [self] in
                guard allows(.event) else { inbox.complete(claim); return }
                // Reserve on the VM worker: a reservation taken while building the frame would refuse this lane's earlier tick.
                guard let safety = asyncExecutionSafety.begin(
                    sceneToken: instanceLimitToken, operation: .event
                ) else {
                    if shared?.isAuthoredLayerOrderingEnabled == true {
                        inbox.complete(claim)
                        return
                    }
                    if inbox.isCurrent(claim) {
                        queue.asyncAfter(deadline: .now() + .milliseconds(1),
                                         execute: makeCursorBatch(claim: claim, inbox: inbox))
                    } else if let next = inbox.complete(claim, reclaimPending: true) {
                        queue.async(execute: makeCursorBatch(claim: next, inbox: inbox))
                    }
                    return
                }
                defer {
                    asyncExecutionSafety.complete(safety)
                    if let next = inbox.complete(claim, reclaimPending: shared?.isAuthoredLayerOrderingEnabled != true) {
                        queue.async(execute: makeCursorBatch(claim: next, inbox: inbox))
                    }
                }
                guard let events = inbox.take(claim) else { return }
                for event in events {
                    guard inbox.isCurrent(claim), acceptsCompletion() else { return }
                    dispatchCursorEventOnQueue(
                        event.event,
                        pointerFrame: event.pointerFrame,
                        hit: event.hit,
                        runtimeSeconds: event.runtimeSeconds
                    )
                    inbox.didDeliver(event)
                }
            }
        }

        func resizeScreen(
            _ size: SIMD2<Double>,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.resizeScreenOnQueue(size)
            }
        }

        func applyGeneralSettings(
            language: String,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.applyGeneralSettingsOnQueue(language: language)
            }
        }

        func applyUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue],
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.applyUserPropertiesOnQueue(properties)
            }
        }

        func destroy(budget: TimeInterval) -> WPESceneScriptBoundedExecutionResult<Bool> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.destroyOnQueue()
            }
        }

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
            scriptProperties: [String: WPESceneScriptPropertyValue],
            initialize: Bool
        ) -> SetupOutcome {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard let context = JSContext(virtualMachine: virtualMachine) else { return .contextUnavailable }
            self.context = context
            updateArgument = nil
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
            engineClockWriter = WPEEngineClockWriter(context: context)
            _ = updateEngineRuntime(0)
            if let shared {
                wpeInstallSharedState(shared, in: context)
            }
            // A stable source token distinguishes property scripts on the same object without logging their source or properties.
            let sourceToken = script.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            let sourceURL = URL(string: "loomscreen-scenescript://transform/\(ownObjectID ?? "unbound")/\(String(sourceToken, radix: 16))")
            context.exceptionHandler = { [weak self] _, exception in
                guard let self else { return }
                didThrow = true
                layerBridge.failEvaluation()
                guard !didLogException else { return }
                // Set the latch before reading JS properties: a custom error getter may itself throw.
                didLogException = true
                let message = String((exception?.toString() ?? "unknown").prefix(512))
                let stack = exception?.objectForKeyedSubscript("stack")
                let stackText = stack?.isString == true ? String((stack?.toString() ?? "").prefix(2048)) : "unavailable"
                Logger.warning(
                    "Transform SceneScript raised an uncaught JS exception (logged once) object=\(ownObjectID ?? "unbound") layer=\(ownLayerName ?? "unnamed") shape=\(valueShape) source=\(sourceURL?.absoluteString ?? "unavailable"): \(message); stack=\(stackText)",
                    category: .wpeRender
                )
            }

            didThrow = false
            _ = context.evaluateScript(wpeLowerBuiltinImports(script, in: context, acceptsCompletion: acceptsCompletion),
                                       withSourceURL: sourceURL)
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
            if initialize {
                return initializeOnQueue()
            }
            return .ready(hasUpdate: updateFunction != nil || timerScheduler.hasPendingTimers, initialResult: nil,
                          media: WPESceneMediaHandlerSet(in: context), cursor: Self.cursorHandlers(in: context))
        }

        private static func cursorHandlers(in context: JSContext) -> Set<WPELayerScriptCursorEvent> {
            Set(WPELayerScriptCursorEvent.allCases.filter { wpeExportsFunction(named: $0.handlerName, in: context) })
        }

        private func initializeOnQueue() -> SetupOutcome {
            guard let context else { return .contextUnavailable }
            guard !didInitialize else {
                return .ready(hasUpdate: updateFunction != nil || timerScheduler?.hasPendingTimers == true,
                              initialResult: nil, media: WPESceneMediaHandlerSet(in: context),
                              cursor: Self.cursorHandlers(in: context))
            }
            didInitialize = true
            didThrow = false
            // Call init with the authored value; without it audio templates leave initialValue undefined → NaN. Do not reuse the update object.
            var initialResult: SIMD3<Double>?
            if let initFn = context.objectForKeyedSubscript("init"),
               !initFn.isUndefined, initFn.hasProperty("call") {
                let returned = initFn.call(
                    withArguments: [jsValue(for: seed, in: context, reuseUpdateArgument: false) as Any]
                )
                initialResult = Self.coercedResult(returned, currentValue: seed)
            }
            if didThrow {
                initialResult = nil
                // The exception handler already logged the error once; keep the authored seed and later callbacks.
            }
            return .ready(
                hasUpdate: updateFunction != nil || timerScheduler?.hasPendingTimers == true,
                initialResult: initialResult,
                media: WPESceneMediaHandlerSet(in: context),
                cursor: Self.cursorHandlers(in: context)
            )
        }

        /// Keyed by handler name, so a throwing media handler backs off alone and
        /// never gates `update()`.
        private func dispatchMediaEventOnQueue(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?
        ) {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return }
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else { return }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: event.handlerName, at: now) else { return }
            didThrow = false
            WPEFrameOccupancyMeter.count(.jscCall)
            _ = fn.call(withArguments: [wpeMediaEventObject(event, in: context)])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: event.handlerName, at: now)
            } else {
                faultPolicy.recordSuccess(entryPoint: event.handlerName)
            }
        }

        /// Same dispatch shape as dispatchMediaEventOnQueue: beginEvaluation so
        /// `thisLayer`/`getLayer` writes publish, fresh cursor input, then the
        /// exported handler keyed by name in faultPolicy.
        private func dispatchCursorEventOnQueue(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            runtimeSeconds: Double?
        ) {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            updateInput(pointerFrame.position)
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return }
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else { return }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: event.handlerName, at: now) else { return }
            didThrow = false
            WPEFrameOccupancyMeter.count(.jscCall)
            _ = fn.call(withArguments: [cursorEventObject(
                event,
                pointerFrame: pointerFrame,
                hit: hit,
                in: context
            )])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: event.handlerName, at: now)
            } else {
                faultPolicy.recordSuccess(entryPoint: event.handlerName)
            }
        }

        /// Same event shape the layer engine hands cursorClick & friends.
        private func cursorEventObject(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            in context: JSContext
        ) -> JSValue {
            let object = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            object.setObject(event.handlerName, forKeyedSubscript: "type" as NSString)
            object.setObject(event.button, forKeyedSubscript: "button" as NSString)
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

        /// init must not reuse the update object — scripts snapshot `initial = value` and would otherwise alias the live argument.
        private func jsValue(
            for value: SIMD3<Double>,
            in context: JSContext,
            reuseUpdateArgument: Bool = false
        ) -> JSValue? {
            switch valueShape {
            case .boolean:
                return JSValue(bool: value.x > 0.5, in: context)
            case .scalar:
                return JSValue(double: value.x, in: context)
            case .vector2, .vector3:
                let object: JSValue
                if reuseUpdateArgument, let existing = updateArgument {
                    object = existing
                } else {
                    let constructorName = valueShape == .vector3 ? "Vec3" : "Vec2"
                    let arguments = valueShape == .vector3 ? [value.x, value.y, value.z] : [value.x, value.y]
                    guard let created = context.objectForKeyedSubscript(constructorName)?.construct(withArguments: arguments) else { return nil }
                    if reuseUpdateArgument {
                        updateArgument = created
                    }
                    object = created
                }
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
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard let context else { return nil }
            audioBridge?.refresh()
            // Before timers: a timer-only module has no update() but its callbacks read input.
            updateInput(pointerPosition)
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return nil }
            guard let updateFunction else { return nil }

            didThrow = false
            guard let argument = jsValue(for: currentValue, in: context, reuseUpdateArgument: true) else { return nil }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return nil }
            WPEFrameOccupancyMeter.count(.jscCall)
            let result = updateFunction.call(withArguments: [argument])
            if didThrow {
                let verdict = faultPolicy.recordFailure(entryPoint: "update", at: now)
                if verdict == .quarantined {
                    self.updateFunction = nil
                    runtimeFault.withLock { $0 = true }
                }
                return nil
            }
            faultPolicy.recordSuccess(entryPoint: "update")
            return Self.coercedResult(result, currentValue: currentValue)
        }

        /// init and update must coerce identically — a second, looser path is how the two drift apart.
        static func coercedResult(
            _ result: JSValue?,
            currentValue: SIMD3<Double>
        ) -> SIMD3<Double>? {
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
            if let engineClockWriter {
                engineClockWriter.refresh(runtime: runtime, frameTime: frameTime)
            } else {
                wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
            }
            return runtimeSeconds?.isFinite == true ? runtime : nil
        }

        deinit {
            timerScheduler?.invalidate()
        }

        private func resizeScreenOnQueue(_ requestedSize: SIMD2<Double>) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            let size = SIMD2(max(requestedSize.x, 1), max(requestedSize.y, 1))
            guard size != screenSize else { return false }
            screenSize = size
            update(screenResolution, x: size.x, y: size.y)
            guard let context,
                  let function = context.objectForKeyedSubscript("resizeScreen"),
                  !function.isUndefined, function.hasProperty("call"),
                  let vectorType = context.objectForKeyedSubscript("Vec2"),
                  let argument = vectorType.construct(withArguments: [size.x, size.y]) else {
                return false
            }
            didThrow = false
            _ = function.call(withArguments: [argument])
            return !didThrow
        }

        private func applyGeneralSettingsOnQueue(language: String) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard let context,
                  let function = context.objectForKeyedSubscript("applyGeneralSettings"),
                  !function.isUndefined, function.hasProperty("call"),
                  let settings = JSValue(newObjectIn: context) else { return false }
            settings.setObject(language, forKeyedSubscript: "language" as NSString)
            didThrow = false
            _ = function.call(withArguments: [settings])
            return !didThrow
        }

        private func destroyOnQueue() -> Bool {
            layerBridge.beginEvaluation()
            defer { layerBridge.releaseCreatedLayerResources() }
            defer { publishLayerOutput() }
            var invoked = false
            if let context,
               let function = context.objectForKeyedSubscript("destroy"),
               !function.isUndefined, function.hasProperty("call") {
                didThrow = false
                _ = function.call(withArguments: [])
                invoked = !didThrow
            }
            timerScheduler?.invalidate()
            updateFunction = nil
            return invoked
        }

        /// Mirrors the layer engine's handler so effect-constant and dynamic
        /// transform scripts see the same bag. `false` when the module does not
        /// export it, so the caller can tell "not interested" from "ran".
        fileprivate func applyUserPropertiesOnQueue(
            _ properties: [String: WPESceneScriptPropertyValue]
        ) -> Bool {
            layerBridge.beginEvaluation()
            defer { publishLayerOutput() }
            guard let context,
                  let function = context.objectForKeyedSubscript("applyUserProperties"),
                  !function.isUndefined, function.hasProperty("call"),
                  let bag = JSValue(newObjectIn: context) else { return false }
            for (name, value) in properties {
                bag.setObject(value.jsBridged, forKeyedSubscript: name as NSString)
            }
            didThrow = false
            _ = function.call(withArguments: [bag])
            return !didThrow
        }

        /// Rewrites both cursor inputs every entry, including after a script
        /// mutates them; screen stays in canvas pixels, world is projected.
        private func updateInput(_ pointer: SIMD2<Double>) {
            let world = shared?.cursorWorldPosition(pointer: pointer, canvasSize: canvasSize, fallbackZ: seed.z)
                ?? SIMD3(pointer.x * canvasSize.x, (1 - pointer.y) * canvasSize.y, seed.z)
            if let cursorHelper {
                WPEFrameOccupancyMeter.count(.jscCall)
                cursorHelper.call(withArguments: [
                    pointer.x * canvasSize.x,
                    pointer.y * canvasSize.y,
                    world.x,
                    world.y,
                    world.z,
                ])
            } else {
                WPEFrameOccupancyMeter.count(.jscSetObject, by: 5)
                cursorScreenPosition?.setObject(pointer.x * canvasSize.x, forKeyedSubscript: "x" as NSString)
                cursorScreenPosition?.setObject(pointer.y * canvasSize.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(world.x, forKeyedSubscript: "x" as NSString)
                cursorWorldPosition?.setObject(world.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(world.z, forKeyedSubscript: "z" as NSString)
            }
        }

        private func installInput(in context: JSContext) {
            let input = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let screen = context.objectForKeyedSubscript("Vec2")?.construct(withArguments: [0, 0])
                ?? JSValue(nullIn: context)!
            let world = shared?.projectedCursorWorldPosition(pointer: SIMD2(0.5, 0.5)) ?? seed
            // Keep this native Vec3 alive across ticks: scripts may capture it before the first input update.
            let cursor = context.objectForKeyedSubscript("Vec3")?.construct(withArguments: [world.x, world.y, world.z])
                ?? JSValue(nullIn: context)!
            input.setObject(screen, forKeyedSubscript: "cursorScreenPosition" as NSString)
            input.setObject(cursor, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorScreenPosition = screen
            cursorWorldPosition = cursor
            cursorHelper = wpeMakeHostTickHelper(
                in: context,
                factory: """
                (function (screen, world) { return function (sx, sy, wx, wy, wz) {
                    screen.x = sx; screen.y = sy;
                    world.x = wx; world.y = wy; world.z = wz;
                }; })
                """,
                targets: [screen, cursor]
            )
            updateInput(SIMD2(0.5, 0.5))
        }

        private func installLayerBridge(in context: JSContext) {
            layerBridge.installLayerBridge(in: context)
        }

        private func publishLayerOutput() {
            layerBridge.finishEvaluation(commit: acceptsCompletion())
        }

    }
}
#endif
