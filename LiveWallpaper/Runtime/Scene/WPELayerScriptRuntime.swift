#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import os


// MARK: - Layer SceneScript (visible-script video intros)

enum WPELayerSoundCommand: Sendable, Equatable {
    case play
    case stop
    case pause
    case setVolume(Double)
}

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

/// Nil means the script never assigned that field, so the renderer keeps the authored/keyframed value. Angles stay in the JS API's degree domain until the renderer merges them into radian geometry.
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

struct WPELayerScriptState: Sendable, Equatable {
    var visible: Bool
    var alpha: Double
    var videoCommands: [WPELayerVideoCommand]
    /// Whether the script explicitly assigned this field. A layer it merely read must not be driven, else the handle's default visible=true clobbers the layer's real state.
    var visibleAssigned: Bool = true
    var alphaAssigned: Bool = true
}

struct WPECreatedLayerScriptState: Sendable, Equatable {
    var key: String
    var imagePath: String
    var origin: SIMD3<Double>
    var color: SIMD3<Double>
    var scale: SIMD3<Double>
    var alpha: Double
    var visible: Bool
    var angles: SIMD3<Double>?
    var alignment: String?
    var parallaxDepth: SIMD2<Double>?
    var sortIndex: Int?
}

struct WPELayerScriptOutput: Sendable, Equatable {
    var own: WPELayerScriptState
    var others: [String: WPELayerScriptState]
    var created: [WPECreatedLayerScriptState] = []
    var presentation: [String: WPELayerScriptPresentationMutation] = [:]
    var ownTransform: WPELayerScriptTransformMutation = .init()
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
    /// Hover transitions, dispatched per-layer from renderer hit-testing — unlike down/up which broadcast.
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

/// Each callback retains the pointer state belonging to its own event.
struct WPELayerScriptCursorInvocation: Sendable {
    let event: WPELayerScriptCursorEvent
    let pointerFrame: WPEPointerFrame
    var hit: WPELayerScriptCursorHit = .init()
    let runtimeSeconds: Double
}

/// Render-owner producers and the existing serial VM worker share only this finite inbox.
/// A busy safety slot leaves the entire burst pending for a later frame.
final class WPELayerScriptCursorInbox: Sendable {
    struct Claim: Sendable { let id: UInt64; let epoch: UInt64 }
    private struct State {
        var epoch: UInt64 = 0
        var nextID: UInt64 = 0
        var scheduled: UInt64?
        var pending: [WPELayerScriptCursorInvocation] = []
        var lastDelivered: WPEPointerFrame = .neutral
        var lastRuntimeSeconds: Double = 0
        var needsCancel = false
        var suppressed = false
        var requiresFreshPress = false
        var closed = false
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(capacity: Int = 1024) {
        self.capacity = min(max(capacity, 1), 1024)
    }

    func append(_ events: [WPELayerScriptCursorInvocation]) {
        state.withLock { value in
            guard !value.closed else { return }
            guard events.count <= capacity - value.pending.count else {
                Self.cancel(&value)
                // The discarded burst itself may already have released both
                // buttons; scripts without update() still observe that boundary.
                value.suppressed = events.last.map {
                    $0.pointerFrame.isDown || $0.pointerFrame.isRightDown
                } ?? true
                value.requiresFreshPress = true
                return
            }
            for event in events {
                if value.suppressed {
                    if !event.pointerFrame.isDown, !event.pointerFrame.isRightDown {
                        value.suppressed = false
                    }
                    // The release/click of a discarded press must not be replayed.
                    continue
                }
                if value.requiresFreshPress {
                    if event.event == .down || event.event == .rightDown {
                        value.requiresFreshPress = false
                    } else if [.up, .click, .rightUp].contains(event.event) {
                        continue
                    }
                }
                value.pending.append(event)
            }
        }
    }

    func claim() -> Claim? {
        state.withLock { value in
            guard !value.closed, value.scheduled == nil,
                  value.needsCancel || !value.pending.isEmpty else { return nil }
            value.nextID &+= 1
            value.scheduled = value.nextID
            return Claim(id: value.nextID, epoch: value.epoch)
        }
    }

    func take(_ claim: Claim) -> [WPELayerScriptCursorInvocation]? {
        state.withLock { value in
            guard !value.closed, value.scheduled == claim.id, value.epoch == claim.epoch else { return nil }
            var result: [WPELayerScriptCursorInvocation] = []
            if value.needsCancel {
                var neutral = value.lastDelivered
                neutral.isDown = false
                neutral.isRightDown = false
                if value.lastDelivered.isDown {
                    result.append(.init(event: .up, pointerFrame: neutral, runtimeSeconds: value.lastRuntimeSeconds))
                }
                if value.lastDelivered.isRightDown {
                    result.append(.init(event: .rightUp, pointerFrame: neutral, runtimeSeconds: value.lastRuntimeSeconds))
                }
                value.needsCancel = false
            }
            result.append(contentsOf: value.pending)
            value.pending.removeAll(keepingCapacity: true)
            return result
        }
    }

    func isCurrent(_ claim: Claim) -> Bool {
        state.withLock { !$0.closed && $0.epoch == claim.epoch }
    }

    func didDeliver(_ event: WPELayerScriptCursorInvocation) {
        state.withLock {
            $0.lastDelivered = event.pointerFrame
            $0.lastRuntimeSeconds = event.runtimeSeconds
        }
    }

    func complete(_ claim: Claim) {
        state.withLock {
            if $0.scheduled == claim.id {
                $0.scheduled = nil
            }
        }
    }

    func cancel() {
        state.withLock { Self.cancel(&$0) }
    }

    func close() {
        state.withLock { Self.cancel(&$0); $0.closed = true }
    }

    private static func cancel(_ value: inout State) {
        value.epoch &+= 1
        value.pending.removeAll(keepingCapacity: true)
        value.needsCancel = true
    }

    func maskingSuppressedButtons(_ frame: WPEPointerFrame?) -> WPEPointerFrame? {
        state.withLock { value in
            guard value.suppressed, var frame else { return frame }
            if !frame.isDown, !frame.isRightDown {
                value.suppressed = false
            }
            frame.isDown = false
            frame.isRightDown = false
            return frame
        }
    }
}

/// Not @MainActor.
final class WPELayerScriptInstance {
    private let engineRelease: WPESceneScriptLaneRelease<LayerEngine>
    private var engine: LayerEngine { engineRelease.value }
    private let hasUpdateFunction: Bool
    let handlesUserProperties: Bool
    let mediaHandlers: WPESceneMediaHandlerSet
    private let tickBudget: TimeInterval
    private var isPoisoned = false
    /// Lifecycle is one-way; only the first teardown path may invoke the authored destroy() handler.
    private var isDestroyed = false
    let initialOutput: WPELayerScriptOutput
    private let cursorInbox = WPELayerScriptCursorInbox()
    private let asyncOutcomeSlot = WPESceneScriptOutcomeSlot<WPELayerScriptOutput>(
        combine: { WPELayerScriptInstance.mergedOutputs(pending: $0, newer: $1) }
    )

    init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shared: WPESharedScriptState? = nil,
        canvasSize: SIMD2<Double> = SIMD2<Double>(1920, 1080),
        /// Real backing-pixel screen resolution. WPE keeps this separate from
        /// the authored scene canvas and passes changes to `resizeScreen`.
        screenSize: SIMD2<Double>? = nil,
        setupBudget: TimeInterval = 2.0,
        tickBudget: TimeInterval = 0.5,
        nowProviderMillis: (@Sendable () -> Double)? = nil,
        outputMode: WPELayerScriptOutputMode = .layerState,
        initialVisible: Bool = true,
        initialAlpha: Double = 1,
        ownLayerName: String? = nil,
        ownObjectID: String? = nil,
        createdLayerBridge: WPECreatedLayerBridgeConfiguration? = nil,
        governor: WPESceneScriptExecutionGovernor = .processShared,
        batchDispatcher: WPESceneScriptBatchDispatcher = .processShared
    ) throws {
        self.tickBudget = tickBudget
        let engine = LayerEngine(
            nowProviderMillis: nowProviderMillis,
            shared: shared,
            canvasSize: canvasSize,
            screenSize: screenSize ?? canvasSize,
            outputMode: outputMode,
            initialVisible: initialVisible,
            initialAlpha: initialAlpha,
            ownLayerName: ownLayerName,
            ownObjectID: ownObjectID,
            createdLayerBridge: createdLayerBridge,
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
            case let .ready(hasUpdate, handlesUserProperties, media, output):
                self.hasUpdateFunction = hasUpdate
                self.handlesUserProperties = handlesUserProperties
                self.mediaHandlers = media
                self.initialOutput = output
            }
        }
    }

    @discardableResult
    func dispatchMediaEvent(
        _ event: WPESceneMediaEvent,
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, handles(event), engine.allows(.event) else { return nil }
        switch engine.dispatchMediaEvent(
            event,
            runtimeSeconds: runtimeSeconds,
            budget: tickBudget
        ) {
        case .timedOut:
            isPoisoned = true
            Logger.warning(
                "Layer SceneScript \(event.handlerName)() exceeded \(tickBudget)s — frozen",
                category: .wpeRender
            )
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            return engine.acceptsCompletion() ? output : nil
        }
    }

    func liveDispatchMediaEvent(
        _ event: WPESceneMediaEvent,
        runtimeSeconds: Double? = nil
    ) {
        guard !isPoisoned, !isDestroyed, handles(event), engine.allows(.event) else { return }
        _ = engine.dispatchMediaEventAsync(
            event,
            runtimeSeconds: runtimeSeconds,
            publishTo: asyncOutcomeSlot
        )
    }

    /// One drain's events in one async hop. Dispatched one at a time, the single in-flight slot admitted only the first event and silently dropped the rest.
    func liveDispatchMediaEvents(
        _ events: [WPESceneMediaEvent],
        runtimeSeconds: Double? = nil
    ) {
        guard !isPoisoned, !isDestroyed else { return }
        let handled = events.filter { handles($0) }
        guard !handled.isEmpty, engine.allows(.event) else { return }
        _ = engine.dispatchMediaEventsAsync(
            handled,
            runtimeSeconds: runtimeSeconds,
            publishTo: asyncOutcomeSlot
        )
    }

    private func handles(_ event: WPESceneMediaEvent) -> Bool {
        mediaHandlers.handles(event)
    }

    /// Returns nil when there's no update(), the instance is poisoned/timed out, or global capacity is momentarily unavailable.
    func tick(
        runtimeSeconds: Double? = nil,
        pointerFrame: WPEPointerFrame? = nil
    ) -> WPELayerScriptOutput? {
        guard hasUpdateFunction, !isPoisoned, !isDestroyed,
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
    #if DEBUG
    @discardableResult
    func dispatchCursorEvent(
        _ event: WPELayerScriptCursorEvent,
        pointerFrame: WPEPointerFrame,
        hit: WPELayerScriptCursorHit = .init(),
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, engine.allows(.event) else { return nil }
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

    #if DEBUG
    @discardableResult
    func applyUserProperties(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, !properties.isEmpty,
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

    /// See `WPESceneScriptInstance.batchTickString`.
    func batchTick(
        runtimeSeconds: Double? = nil,
        pointerFrame: WPEPointerFrame? = nil
    ) -> (output: WPELayerScriptOutput?, job: WPESceneScriptBatchDispatcher.Job?) {
        guard !isPoisoned, !isDestroyed else { return (nil, nil) }
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
            pointerFrame: cursorInbox.maskingSuppressedButtons(pointerFrame),
            claim: claim,
            publishTo: asyncOutcomeSlot
        ) else {
            asyncOutcomeSlot.rejectTick(claim)
            return (fresh, nil)
        }
        return (fresh, WPESceneScriptBatchDispatcher.Job(queue: engine.queue, work: work))
    }

    func batchCursorEvents(
        _ events: [WPELayerScriptCursorInvocation]
    ) -> WPESceneScriptBatchDispatcher.Job? {
        guard !isPoisoned, !isDestroyed, engine.allows(.event) else {
            cursorInbox.close()
            return nil
        }
        cursorInbox.append(events)
        guard let claim = cursorInbox.claim() else { return nil }
        let work = engine.makeCursorBatch(claim: claim, inbox: cursorInbox, publishTo: asyncOutcomeSlot)
        return WPESceneScriptBatchDispatcher.Job(queue: engine.queue, work: work)
    }

    func cancelPendingCursorEvents() {
        cursorInbox.cancel()
    }

    /// Async applyUserProperties: fold through outcome slot so a pending tick cannot clobber it.
    @discardableResult
    func applyUserPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, !properties.isEmpty,
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

    func applyScriptPropertiesSuperseding(
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, !properties.isEmpty,
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

    @discardableResult
    func resizeScreen(_ size: SIMD2<Double>) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, engine.allows(.event) else { return nil }
        let budget = tickBudget * 2
        switch engine.resizeScreen(size, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript resizeScreen() exceeded \(budget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            guard engine.acceptsCompletion(), let output else { return nil }
            return asyncOutcomeSlot.supersede(with: output)
        }
    }

    /// Initial load sends the complete currently-supported settings object;
    /// later renderer notifications call this only when `language` changed.
    @discardableResult
    func applyGeneralSettings(language: String) -> WPELayerScriptOutput? {
        guard !isPoisoned, !isDestroyed, engine.allows(.event) else { return nil }
        let budget = tickBudget * 2
        switch engine.applyGeneralSettings(language: language, budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript applyGeneralSettings() exceeded \(budget)s — frozen", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            guard engine.acceptsCompletion(), let output else { return nil }
            return asyncOutcomeSlot.supersede(with: output)
        }
    }

    /// Calls the authored handler at most once and fences all later ticks/events.
    @discardableResult
    func destroy() -> WPELayerScriptOutput? {
        guard !isDestroyed else { return nil }
        isDestroyed = true
        cursorInbox.close()
        guard !isPoisoned, engine.allows(.event) else { return nil }
        let budget = tickBudget * 2
        switch engine.destroy(budget: budget) {
        case .timedOut:
            isPoisoned = true
            Logger.warning("Layer SceneScript destroy() exceeded \(budget)s", category: .wpeRender)
            return nil
        case .capacityUnavailable:
            return nil
        case let .completed(output):
            return engine.acceptsCompletion() ? output : nil
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
        for (name, pendingPresentation) in pending.presentation {
            var accumulated = pendingPresentation
            if let newerPresentation = merged.presentation[name] {
                accumulated.merge(newerPresentation)
            }
            merged.presentation[name] = accumulated
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

    private final class LayerEngine: @unchecked Sendable, WPESceneScriptEngineExecutionGuarding, WPESceneScriptCanvasSizedEngine {
        enum SetupOutcome {
            case ready(
                hasUpdate: Bool,
                handlesUserProperties: Bool,
                media: WPESceneMediaHandlerSet,
                output: WPELayerScriptOutput
            )
            case contextUnavailable
        }

        /// Key for `thisLayer` in the per-layer command/handle maps (other layers
        /// use their `getLayer(name)` name).
        private static let ownKey = ""
        /// thisScene.createLayer handles share the getLayer handle shape but must stay out of the cross-layer journal.
        private static let createdKeyPrefix = "__created_"

        fileprivate var queue: DispatchQueue { executionLane.queue }
        fileprivate let executionLane: WPESceneScriptBatchDispatcher.Lane
        private let virtualMachine: JSVirtualMachine
        private var context: JSContext?
        /// Rewrites every `registerAudioBuffers` array from the shared audio
        /// broker at the top of each tick; nil until `setUp` builds the context.
        private var audioBridge: WPESceneScriptAudioBridge?
        fileprivate var timerScheduler: WPESceneScriptTimerScheduler?
        private var updateFunction: JSValue?
        fileprivate var screenResolution: JSValue?
        private var thisLayer: JSValue?
        /// Set by the context exception handler so `init()` failures can degrade
        /// safely (run on the engine queue, so no synchronization needed).
        fileprivate var didThrow = false
        private var faultPolicy = WPEScriptFaultPolicy()
        /// One-shot latch for `logFirstThrow` (per instance, not per tick).
        private var hasLoggedThrow = false
        private var namedLayers: [String: JSValue] = [:]
        /// Video handles stored here (not captured by getVideoTexture) to avoid a JSC retain cycle.
        private var videoHandles: [String: JSValue] = [:]
        /// Layers whose visible/alpha the script explicitly assigned. A getLayer(x) the script only read never lands here, so readOutput won't drive it.
        private var assignedVisible: [String: Bool] = [:]
        private var assignedAlpha: [String: Double] = [:]
        /// Deliberately separate from the JS vector objects so a read or nested-object edit does not masquerade as thisLayer.<field> = value.
        private var assignedOwnTransform = WPELayerScriptTransformMutation()
        private var ownOriginValue: JSValue?
        private var ownScaleValue: JSValue?
        private var ownAnglesValue: JSValue?
        private var assignedOtherTransforms: [String: WPELayerScriptTransformMutation] = [:]
        private var otherTransformValues: [String: [OwnTransformField: JSValue]] = [:]
        private var createdLayers: [(key: String, handle: JSValue)] = []
        private var createdLayerCounter = 0
        private let createdLayerBridge: WPECreatedLayerBridgeConfiguration?
        private var currentLayerOrder: [String]
        private var didSortLayers = false
        private var scriptWorkshopID: String?
        private var presentationMutations: [String: WPELayerScriptPresentationMutation] = [:]
        private var createdAngles: [String: SIMD3<Double>] = [:]
        private var hasLoggedUnsupportedLayerOperation = false
        /// Key "" = thisLayer, else the getLayer name. Drained on the engine queue (where the JS blocks also append) so there is no cross-thread race.
        private var pendingVideo: [String: [WPELayerVideoCommand]] = [:]
        /// Last play/stop intent per sound layer, so `isPlaying()` answers without
        /// a read-back channel into the audio graph.
        private var soundIntent: [String: Bool] = [:]
        private var assignedSoundVolume: [String: Double] = [:]
        private let nowProviderMillis: (@Sendable () -> Double)?
        private let shared: WPESharedScriptState?
        fileprivate let canvasSize: SIMD2<Double>
        fileprivate var screenSize: SIMD2<Double>
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
        /// One-crossing clock updates; nil until setUp (then falls back to
        /// `wpeRefreshEngineClock` should construction ever fail).
        private var engineClockWriter: WPEEngineClockWriter?
        /// Batched cursor write (one crossing for all 5 fields, assigning onto
        /// the two cached cursor objects above); nil → per-field fallback.
        private var cursorHelper: JSValue?
        /// JS booleans are immutable, so identity reuse of the update(value) argument is unobservable.
        private var cachedTrueArgument: JSValue?
        private var cachedFalseArgument: JSValue?
        private var neutralLayerStubCache: JSValue?
        private var neutralAnimationStubCache: JSValue?
        /// ownKey is the empty string, so without this thisLayer.name / .size / .origin and thisScene.getLayerIndex(thisLayer) all miss the layer table.
        private let ownLayerName: String?
        private let ownObjectID: String?
        private let particleBridge: WPESceneScriptParticleBridge
        private let cameraBridge: WPESceneScriptCameraBridge

        init(
            nowProviderMillis: (@Sendable () -> Double)?,
            shared: WPESharedScriptState?,
            canvasSize: SIMD2<Double>,
            screenSize: SIMD2<Double>,
            outputMode: WPELayerScriptOutputMode,
            initialVisible: Bool,
            initialAlpha: Double,
            ownLayerName: String?,
            ownObjectID: String?,
            createdLayerBridge: WPECreatedLayerBridgeConfiguration?,
            governor: WPESceneScriptExecutionGovernor,
            batchDispatcher: WPESceneScriptBatchDispatcher
        ) {
            let lane = batchDispatcher.reserveLane()
            executionLane = lane
            virtualMachine = lane.virtualMachine
            self.ownLayerName = ownLayerName
            self.ownObjectID = ownObjectID
            particleBridge = WPESceneScriptParticleBridge(shared: shared)
            cameraBridge = WPESceneScriptCameraBridge(shared: shared)
            self.createdLayerBridge = createdLayerBridge
            currentLayerOrder = createdLayerBridge?.orderedLayerNames
                ?? (shared?.layers.sorted { $0.index < $1.index }.map(\.name) ?? [])
            self.nowProviderMillis = nowProviderMillis
            self.shared = shared
            self.canvasSize = SIMD2<Double>(max(canvasSize.x, 1), max(canvasSize.y, 1))
            self.screenSize = SIMD2<Double>(max(screenSize.x, 1), max(screenSize.y, 1))
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

        func dispatchMediaEvent(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .failFast) {
                self.dispatchMediaEventOnQueue(event, runtimeSeconds: runtimeSeconds)
            }
        }

        func dispatchMediaEventAsync(
            _ event: WPESceneMediaEvent,
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
                let outcome = self.dispatchMediaEventOnQueue(
                    event,
                    runtimeSeconds: runtimeSeconds
                )
                guard self.acceptsCompletion() else { return }
                slot.publishEvent(outcome)
            }
            return true
        }

        func dispatchMediaEventsAsync(
            _ events: [WPESceneMediaEvent],
            runtimeSeconds: Double?,
            publishTo slot: WPESceneScriptOutcomeSlot<WPELayerScriptOutput>
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
                    let outcome = self.dispatchMediaEventOnQueue(
                        event,
                        runtimeSeconds: runtimeSeconds
                    )
                    guard self.acceptsCompletion() else { return }
                    slot.publishEvent(outcome)
                }
            }
            return true
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

        func resizeScreen(
            _ size: SIMD2<Double>,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput?> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.resizeScreenOnQueue(size)
            }
        }

        func applyGeneralSettings(
            language: String,
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput?> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.applyGeneralSettingsOnQueue(language: language)
            }
        }

        func destroy(
            budget: TimeInterval
        ) -> WPESceneScriptBoundedExecutionResult<WPELayerScriptOutput> {
            guard allows(.event) else { return .capacityUnavailable }
            return runWithBudget(budget, operation: .event, admission: .waitUntilDeadline) {
                self.destroyOnQueue()
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

        func makeCursorBatch(
            claim: WPELayerScriptCursorInbox.Claim,
            inbox: WPELayerScriptCursorInbox,
            publishTo slot: WPESceneScriptOutcomeSlot<WPELayerScriptOutput>
        ) -> @Sendable () -> Void {
            { @Sendable [self] in
                defer { inbox.complete(claim) }
                // Reserve on the VM worker, never while building a frame's jobs.
                // Failed admission leaves the inbox intact for the next frame.
                guard allows(.event), let safety = asyncExecutionSafety.begin(
                    sceneToken: instanceLimitToken, operation: .event
                ) else { return }
                defer { asyncExecutionSafety.complete(safety) }
                guard let events = inbox.take(claim) else { return }
                for event in events {
                    guard inbox.isCurrent(claim), acceptsCompletion() else { return }
                    let outcome = dispatchCursorEventOnQueue(
                        event.event, pointerFrame: event.pointerFrame,
                        hit: event.hit, runtimeSeconds: event.runtimeSeconds
                    )
                    inbox.didDeliver(event)
                    guard inbox.isCurrent(claim), acceptsCompletion() else { return }
                    slot.publishEvent(outcome)
                }
            }
        }

        /// The one conversion from a returned JS value to a `visible` flag —
        /// shared by `init` and `update` so the two cannot narrow differently.
        static func coercedVisible(_ result: JSValue?) -> Bool? {
            guard let result, !result.isUndefined, !result.isNull else { return nil }
            if result.isBoolean { return result.toBool() }
            if result.isNumber {
                let number = result.toDouble()
                return number.isFinite ? number != 0 : nil
            }
            return nil
        }

        static func coercedAlpha(_ result: JSValue?) -> Double? {
            guard let result, !result.isUndefined, !result.isNull, result.isNumber else { return nil }
            let value = result.toDouble()
            return value.isFinite ? value : nil
        }

        private func setUpOnQueue(
            script: String,
            scriptProperties: [String: WPESceneScriptPropertyValue]
        ) -> SetupOutcome {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
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
            engineClockWriter = WPEEngineClockWriter(context: context)
            cachedTrueArgument = JSValue(bool: true, in: context)
            cachedFalseArgument = JSValue(bool: false, in: context)
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
                self?.particleBridge.failEvaluation()
                self?.cameraBridge.failEvaluation()
                self?.logFirstThrow(exception)
            }
            evaluationResourceBudget.beginEvaluation()
            _ = context.evaluateScript(script)
            // Exported `let` is a lexical binding, not necessarily a global-object property.
            let namespace = context.evaluateScript("typeof __workshopId === 'string' ? __workshopId : undefined")
            scriptWorkshopID = namespace?.isString == true ? namespace?.toString() : nil
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
                // init returns the modified value to be applied, just as update does. Calling with no argument fed init(value) undefined, so return !value showed an authored-visible layer it meant to hide.
                switch outputMode {
                case .layerState:
                    let returned = initFn.call(withArguments: [initialOwnVisible])
                    if let value = Self.coercedVisible(returned) { setOwnLayerVisible(value) }
                case .returnedAlpha(let initialValue):
                    let returned = initFn.call(withArguments: [initialValue])
                    if let value = Self.coercedAlpha(returned) { setOwnLayerAlpha(value) }
                }
            }
            // A failed init preserves authored visibility and alpha.
            let media = WPESceneMediaHandlerSet(in: context)
            if didThrow {
                let authoredAlpha = switch outputMode {
                case .layerState: initialOwnAlpha
                case let .returnedAlpha(seed): seed.isFinite ? seed : initialOwnAlpha
                }
                assignedVisible[Self.ownKey] = initialOwnVisible
                assignedAlpha[Self.ownKey] = authoredAlpha
                return .ready(
                    hasUpdate: false,
                    handlesUserProperties: handlesUserProperties,
                    media: media,
                    output: WPELayerScriptOutput(
                        own: WPELayerScriptState(visible: initialOwnVisible, alpha: authoredAlpha, videoCommands: []),
                        others: [:]
                    )
                )
            }
            return .ready(
                hasUpdate: updateFunction != nil || timerScheduler.hasPendingTimers,
                handlesUserProperties: handlesUserProperties,
                media: media,
                output: readOutput()
            )
        }

        /// Keyed by handler name, so a throwing media handler backs off alone
        /// and never gates `update()` or the cursor handlers.
        private func dispatchMediaEventOnQueue(
            _ event: WPESceneMediaEvent,
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            evaluationResourceBudget.beginEvaluation()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else {
                return readOutput()
            }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: event.handlerName, at: now) else {
                return readOutput()
            }
            didThrow = false
            WPEFrameOccupancyMeter.count(.jscCall)
            _ = fn.call(withArguments: [wpeMediaEventObject(event, in: context)])
            if didThrow {
                faultPolicy.recordFailure(entryPoint: event.handlerName, at: now)
            } else {
                faultPolicy.recordSuccess(entryPoint: event.handlerName)
            }
            return readOutput()
        }

        private func tickOnQueue(
            runtimeSeconds: Double?,
            pointerFrame: WPEPointerFrame?
        ) -> WPELayerScriptOutput {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            audioBridge?.refresh()
            evaluationResourceBudget.beginEvaluation()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            guard let context, let updateFunction else { return readOutput() }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return readOutput() }
            didThrow = false
            switch outputMode {
            case .layerState:
                // update(value) receives the live current value; its return becomes the new one. The live property is the argument, not the last return — replaying a return pinned the seed, and thisLayer.visible = !value re-inverted every frame.
                let current = assignedVisible[Self.ownKey] ?? initialOwnVisible
                let arg = (current ? cachedTrueArgument : cachedFalseArgument)
                    ?? JSValue(bool: current, in: context)
                    ?? JSValue(nullIn: context)!
                WPEFrameOccupancyMeter.count(.jscCall)
                if let value = Self.coercedVisible(updateFunction.call(withArguments: [arg as Any])) {
                    setOwnLayerVisible(value)
                }
            case .returnedAlpha:
                // Same contract as .layerState: the live property is the argument, not the last returned value, or thisLayer.alpha = 1 - value reads the seed forever.
                let current = assignedAlpha[Self.ownKey] ?? initialOwnAlpha
                let arg = JSValue(object: current, in: context) ?? JSValue(nullIn: context)!
                WPEFrameOccupancyMeter.count(.jscCall)
                if let value = Self.coercedAlpha(updateFunction.call(withArguments: [arg as Any])) {
                    setOwnLayerAlpha(value)
                }
            }
            if didThrow {
                faultPolicy.recordFailure(entryPoint: "update", at: now)
            } else {
                faultPolicy.recordSuccess(entryPoint: "update")
            }
            return readOutput()
        }

        /// One line per instance, so a permanently-broken script is findable without a per-frame log flood.
        private func logFirstThrow(_ exception: JSValue?) {
            guard !hasLoggedThrow else { return }
            hasLoggedThrow = true
            Logger.warning(
                "SceneScript threw: \(exception?.toString() ?? "unknown") — this tick produced nothing; "
                    + "retries back off exponentially (a throwing tick costs ~100x a clean one)",
                category: .wpeRender
            )
        }

        private func dispatchCursorEventOnQueue(
            _ event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            hit: WPELayerScriptCursorHit,
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            evaluationResourceBudget.beginEvaluation()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            guard let context,
                  let fn = context.objectForKeyedSubscript(event.handlerName),
                  !fn.isUndefined, fn.hasProperty("call") else {
                return readOutput()
            }
            // Keyed by handler name, so a throwing cursorClick backs off alone
            // and never gates update() or the other cursor handlers.
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: event.handlerName, at: now) else {
                return readOutput()
            }
            didThrow = false
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
            return readOutput()
        }

        private func applyUserPropertiesOnQueue(
            _ properties: [String: WPESceneScriptPropertyValue],
            runtimeSeconds: Double?
        ) -> WPELayerScriptOutput {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            evaluationResourceBudget.beginEvaluation()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
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

        private func resizeScreenOnQueue(_ requestedSize: SIMD2<Double>) -> WPELayerScriptOutput? {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            let size = SIMD2<Double>(max(requestedSize.x, 1), max(requestedSize.y, 1))
            guard size != screenSize else { return nil }
            screenSize = size
            update(screenResolution, x: size.x, y: size.y)
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            guard let context,
                  let function = context.objectForKeyedSubscript("resizeScreen"),
                  !function.isUndefined, function.hasProperty("call"),
                  let vectorType = context.objectForKeyedSubscript("Vec2"),
                  let argument = vectorType.construct(withArguments: [size.x, size.y]) else {
                return nil
            }
            didThrow = false
            _ = function.call(withArguments: [argument])
            return didThrow ? nil : readOutput()
        }

        private func applyGeneralSettingsOnQueue(language: String) -> WPELayerScriptOutput? {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            guard let context,
                  let function = context.objectForKeyedSubscript("applyGeneralSettings"),
                  !function.isUndefined, function.hasProperty("call"),
                  let settings = JSValue(newObjectIn: context) else { return nil }
            settings.setObject(language, forKeyedSubscript: "language" as NSString)
            didThrow = false
            _ = function.call(withArguments: [settings])
            return didThrow ? nil : readOutput()
        }

        private func destroyOnQueue() -> WPELayerScriptOutput {
            particleBridge.beginEvaluation()
            cameraBridge.beginEvaluation()
            defer {
                let commit = acceptsCompletion()
                particleBridge.finishEvaluation(commit: commit)
                cameraBridge.finishEvaluation(commit: commit)
            }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            if let context,
               let function = context.objectForKeyedSubscript("destroy"),
               !function.isUndefined, function.hasProperty("call") {
                didThrow = false
                _ = function.call(withArguments: [])
            }
            timerScheduler?.invalidate()
            updateFunction = nil
            let output = readOutput()
            currentLayerOrder.removeAll(keepingCapacity: false)
            createdLayers.removeAll(keepingCapacity: false)
            presentationMutations.removeAll(keepingCapacity: false)
            createdAngles.removeAll(keepingCapacity: false)
            return output
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

        private func installInput(in context: JSContext) {
            let input = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let screen = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            let world = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            input.setObject(screen, forKeyedSubscript: "cursorScreenPosition" as NSString)
            input.setObject(world, forKeyedSubscript: "cursorWorldPosition" as NSString)
            context.setObject(input, forKeyedSubscript: "input" as NSString)
            cursorScreenPosition = screen
            cursorWorldPosition = world
            cursorHelper = wpeMakeHostTickHelper(
                in: context,
                factory: """
                (function (screen, world) { return function (sx, sy, wx, wy, wz) {
                    screen.x = sx; screen.y = sy;
                    world.x = wx; world.y = wy; world.z = wz;
                }; })
                """,
                targets: [screen, world]
            )
            updateInput(.neutral)
        }

        private func updateInput(_ pointerFrame: WPEPointerFrame?) {
            guard let pointerFrame else { return }
            let x = clampFinite(pointerFrame.position.x, lower: 0, upper: 1)
            let y = clampFinite(pointerFrame.position.y, lower: 0, upper: 1)
            let world = shared?.cursorWorldPosition(pointer: SIMD2(x, y), canvasSize: canvasSize)
                ?? SIMD3(x * canvasSize.x, (1 - y) * canvasSize.y, 0)
            // Rewritten every tick even when the pointer has not moved: a script that assigns into input.cursorScreenPosition must see the host value restored.
            if let cursorHelper {
                WPEFrameOccupancyMeter.count(.jscCall)
                cursorHelper.call(withArguments: [
                    x * canvasSize.x,
                    y * canvasSize.y,
                    world.x,
                    world.y,
                    world.z,
                ])
            } else {
                WPEFrameOccupancyMeter.count(.jscSetObject, by: 5)
                cursorScreenPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
                cursorScreenPosition?.setObject(y * canvasSize.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(world.x, forKeyedSubscript: "x" as NSString)
                cursorWorldPosition?.setObject(world.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(world.z, forKeyedSubscript: "z" as NSString)
            }
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

        private func installLayerBridge(in context: JSContext) {
            let layer = makeLayerHandle(key: Self.ownKey, in: context)
            context.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
            // Same handle under WPE's other name for it. thisObject is a real global rather than one author's invention — and it was undefined, so those scripts threw.
            context.setObject(layer, forKeyedSubscript: "thisObject" as NSString)
            self.thisLayer = layer

            let scene = JSValue(newObjectIn: context)!
            let getLayer: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] value in
                guard let self, let context, let key = layerKey(value) else { return nil }
                return handle(forLayerKey: key, in: context)
            }
            scene.setObject(getLayer, forKeyedSubscript: "getLayer" as NSString)
            let createLayer: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] spec in
                guard let self, let context else { return nil }
                let requestedImage: String?
                if spec.isString {
                    requestedImage = spec.toString()
                } else if spec.isObject {
                    requestedImage = spec.objectForKeyedSubscript("image")?.isString == true
                        ? spec.objectForKeyedSubscript("image")?.toString() : nil
                } else {
                    reportUnsupportedLayerOperation("createLayer requires an image path or image object")
                    return nil
                }
                if createdLayerBridge != nil, requestedImage == nil {
                    reportUnsupportedLayerOperation("createLayer supports prepared image assets only")
                    return nil
                }
                let resolvedImage: String?
                if let requestedImage, let bridge = createdLayerBridge {
                    guard let resolved = bridge.resolvedImagePath(requestedImage, workshopID: scriptWorkshopID) else {
                        reportUnsupportedLayerOperation("createLayer image is unavailable, ambiguous, or outside the prepared image subset: \(requestedImage)")
                        return nil
                    }
                    resolvedImage = resolved
                } else {
                    resolvedImage = requestedImage
                }
                guard self.instanceLimitToken?.admitCreatedLayer() ?? true else {
                    return self.neutralLayerStub(in: context)
                }
                let key = "\(Self.createdKeyPrefix)\(self.createdLayerCounter)"
                let handle = self.makeLayerHandle(key: key, in: context)
                self.createdLayerCounter += 1
                self.createdLayers.append((key, handle))
                currentLayerOrder.append(key)
                if spec.isObject {
                    for property in ["origin", "color", "scale", "alpha", "visible", "angles", "alignment", "parallaxDepth"] {
                        if let value = spec.objectForKeyedSubscript(property), !value.isUndefined {
                            handle.setObject(value, forKeyedSubscript: property as NSString)
                        }
                    }
                }
                if let resolvedImage {
                    handle.setObject(resolvedImage, forKeyedSubscript: "image" as NSString)
                }
                return handle
            }
            scene.setObject(createLayer, forKeyedSubscript: "createLayer" as NSString)
            let getLayerIndex: @convention(block) (JSValue) -> Int = { [weak self] value in
                guard let self, let key = layerKey(value) else { return -1 }
                return currentLayerOrder.firstIndex(of: key) ?? -1
            }
            scene.setObject(getLayerIndex, forKeyedSubscript: "getLayerIndex" as NSString)
            let sortLayer: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] value, index in
                guard let self else { return false }
                guard createdLayerBridge?.allowsSorting == true else {
                    reportUnsupportedLayerOperation("sortLayer requires a single script owner and independent image passes")
                    return false
                }
                guard let key = layerKey(value), let old = currentLayerOrder.firstIndex(of: key),
                      index.isNumber else { return false }
                let number = index.toDouble()
                guard number.isFinite, number.rounded(.towardZero) == number,
                      number >= 0, number < Double(currentLayerOrder.count) else { return false }
                currentLayerOrder.remove(at: old)
                currentLayerOrder.insert(key, at: Int(number))
                didSortLayers = true
                return true
            }
            scene.setObject(sortLayer, forKeyedSubscript: "sortLayer" as NSString)
            let enumerateLayers: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let self, let context else { return nil }
                return JSValue(object: currentLayerOrder.map { handle(forLayerKey: $0, in: context) }, in: context)
            }
            scene.setObject(enumerateLayers, forKeyedSubscript: "enumerateLayers" as NSString)
            let getLayerCount: @convention(block) () -> Int = { [weak self] in self?.currentLayerOrder.count ?? 0 }
            scene.setObject(getLayerCount, forKeyedSubscript: "getLayerCount" as NSString)
            // `scene.on(event, cb)` isn't a real WPE API (some scenes assume it);
            // a no-op stub keeps such a script from throwing at top-level eval.
            let on: @convention(block) (JSValue, JSValue) -> Void = { _, _ in }
            scene.setObject(on, forKeyedSubscript: "on" as NSString)
            cameraBridge.install(on: scene, in: context)
            context.setObject(scene, forKeyedSubscript: "thisScene" as NSString)
            context.setObject(scene, forKeyedSubscript: "scene" as NSString)

        }

        private func layerKey(_ value: JSValue) -> String? {
            if value.isString {
                guard let key = value.toString(), !key.isEmpty else { return nil }
                return key
            }
            if value.isNumber {
                let n = value.toDouble()
                guard n.isFinite, n.rounded(.towardZero) == n, n >= 0,
                      n < Double(currentLayerOrder.count) else { return nil }
                return currentLayerOrder[Int(n)]
            }
            guard value.isObject else { return nil }
            return value.objectForKeyedSubscript("name")?.toString()
        }

        private func handle(forLayerKey key: String, in context: JSContext) -> JSValue {
            if key == ownLayerName, let thisLayer {
                return thisLayer
            }
            if let created = createdLayers.first(where: { $0.key == key }) {
                return created.handle
            }
            return layerHandle(named: key, in: context)
        }

        private func reportUnsupportedLayerOperation(_ message: String) {
            guard !hasLoggedUnsupportedLayerOperation else { return }
            hasLoggedUnsupportedLayerOperation = true
            Logger.warning("[SceneScript] unsupported dynamic layer operation: \(message)", category: .wpeRender)
        }

        /// One handle per layer name for the scene's lifetime, so enumerateLayers and repeated getLayer calls hand back the same object.
        private func layerHandle(named name: String, in context: JSContext) -> JSValue {
            if let existing = namedLayers[name] { return existing }
            let handle = makeLayerHandle(key: name, in: context)
            namedLayers[name] = handle
            return handle
        }

        private func makeLayerHandle(key: String, in context: JSContext) -> JSValue {
            let handle = JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
            // `key` is "" for the script's own layer, so anything addressed by
            // SCENE name (the layer table, sound commands) needs the resolved one.
            let layerName = key == Self.ownKey ? (ownLayerName ?? key) : key
            // visible/alpha are accessors so explicit assign is distinguishable from a mere read.
            installAssignmentAccessors(on: handle, key: key, layerName: layerName, in: context)
            handle.setObject(layerName, forKeyedSubscript: "name" as NSString)
            // Authored layer size. Zero when the name isn't a scene layer — getLayer mints handles for arbitrary strings.
            let size = JSValue(newObjectIn: context)!
            let info = key == Self.ownKey
                ? (ownObjectID.flatMap { id in shared?.layers.first { $0.id == id } }
                    ?? shared?.layers.first { $0.name == layerName })
                : shared?.layers.first { $0.name == layerName }
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
            // Real parent when the document names one; a stub without an origin would throw on currentPos.x every tick.
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
            // The stub already answers setFrame/play/pause/stop; it was not reachable under this name, so thisLayer.getTextureAnimation() threw a TypeError on every tick.
            let getTextureAnimation: @convention(block) () -> JSValue? = { [weak self] in
                self?.neutralAnimationStubCache
            }
            handle.setObject(getTextureAnimation, forKeyedSubscript: "getTextureAnimation" as NSString)
            let getAnimation: @convention(block) (JSValue) -> JSValue? = { [weak self] _ in
                self?.neutralAnimationStubCache
            }
            handle.setObject(getAnimation, forKeyedSubscript: "getAnimation" as NSString)
            if let info, info.isParticleSystem {
                particleBridge.install(on: handle, objectID: info.id, in: context)
                return handle
            }
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
            // Last intent this engine expressed, not a read-back from the audio graph.
            let isPlaying: @convention(block) () -> Bool = { [weak self] in
                self?.soundIntent[layerName] ?? false
            }
            handle.setObject(isPlaying, forKeyedSubscript: "isPlaying" as NSString)
            return handle
        }

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
            let getAlignment: @convention(block) () -> String = { [weak self] in
                self?.presentationMutations[key]?.alignment
                    ?? self?.shared?.layers.first(where: { $0.name == layerName })?.alignment ?? "center"
            }
            let setAlignment: @convention(block) (JSValue) -> Void = { [weak self] value in
                guard value.isString, let text = value.toString(),
                      ["center", "centre", "top", "bottom", "left", "right", "topleft", "topright", "bottomleft", "bottomright"].contains(text.lowercased()) else { return }
                self?.presentationMutations[key, default: .init()].alignment = text
            }
            let getDepth: @convention(block) () -> JSValue? = { [weak self, weak context] in
                guard let context else { return nil }
                let depth = self?.presentationMutations[key]?.parallaxDepth
                    ?? self?.shared?.layers.first(where: { $0.name == layerName })?.parallaxDepth ?? .zero
                return context.objectForKeyedSubscript("Vec2")?.construct(withArguments: [depth.x, depth.y])
            }
            let setDepth: @convention(block) (JSValue) -> Void = { [weak self] value in
                guard value.isObject, let x = value.objectForKeyedSubscript("x"), x.isNumber,
                      let y = value.objectForKeyedSubscript("y"), y.isNumber,
                      x.toDouble().isFinite, y.toDouble().isFinite else { return }
                self?.presentationMutations[key, default: .init()].parallaxDepth = SIMD2(x.toDouble(), y.toDouble())
            }
            defineAccessor(on: handle, property: "alignment", get: getAlignment, set: setAlignment, in: context)
            defineAccessor(on: handle, property: "parallaxDepth", get: getDepth, set: setDepth, in: context)
        }

        /// Reading a vector or mutating only the returned object's x/y/z does not publish a geometry assignment; the script must assign the vector back to thisLayer.origin/scale/angles.
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

        /// The getLayer(name) counterpart of installOwnTransformAccessors. Assigning one layer's origin onto another silently did nothing while these were plain data properties.
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
            if key.hasPrefix(Self.createdKeyPrefix) {
                if field == .angles {
                    createdAngles[key] = vector
                }
                return
            }
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
            let vector = context.objectForKeyedSubscript("Vec3")?.construct(withArguments: [value.x, value.y, value.z])
                ?? JSValue(newObjectIn: context) ?? JSValue(nullIn: context)!
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
            // Writable playback rate. We don't drive layer timeline animations, so this stores and does nothing — but an assignment to a property of undefined would throw away the rest of update().
            stub.setObject(1.0, forKeyedSubscript: "rate" as NSString)
            for method in ["play", "pause", "stop"] {
                stub.setObject(noop, forKeyedSubscript: method as NSString)
            }
            stub.setObject(noop1, forKeyedSubscript: "setFrame" as NSString)
            // Paired with setFrame. We drive no timeline, so frame 0 is the only answer we can give, and it beats killing the rest of update().
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
            var presentation = presentationMutations.filter { !$0.key.hasPrefix(Self.createdKeyPrefix) }
            if didSortLayers {
                for (index, name) in currentLayerOrder.enumerated() where !name.hasPrefix(Self.createdKeyPrefix) {
                    let key = name == ownLayerName ? Self.ownKey : name
                    presentation[key, default: .init()].sortIndex = index
                }
            }
            pendingVideo.removeAll(keepingCapacity: true)
            return WPELayerScriptOutput(
                own: own,
                others: others,
                created: created,
                presentation: presentation,
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
                visible: visible,
                angles: createdAngles[key],
                alignment: presentationMutations[key]?.alignment,
                parallaxDepth: presentationMutations[key]?.parallaxDepth,
                sortIndex: didSortLayers ? currentLayerOrder.firstIndex(of: key) : nil
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


#endif
