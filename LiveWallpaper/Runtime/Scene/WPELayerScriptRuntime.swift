#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

// Split out of WPESceneScriptRuntime.swift: these types are the visible-script
// video-intro engine, independent of the scene-script engine that file holds.

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

/// Explicit transform assignments made through a layer SceneScript's `thisLayer`. Nil means
/// the script never assigned that field, so the renderer keeps using the authored/keyframed
/// value; angles stay in the JavaScript API's degree domain until the renderer merges them
/// into its radian geometry.
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
    /// Same demand contract as `handlesUserProperties`, for the media handlers.
    let mediaHandlers: WPESceneMediaHandlerSet
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
            case let .ready(hasUpdate, handlesUserProperties, media, output):
                self.hasUpdateFunction = hasUpdate
                self.handlesUserProperties = handlesUserProperties
                self.mediaHandlers = media
                self.initialOutput = output
            }
        }
    }

    /// Bounded-synchronous media delivery, used by the load path and by tests
    /// that need the handler's effect visible to the next `tick()`.
    @discardableResult
    func dispatchMediaEvent(
        _ event: WPESceneMediaEvent,
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard !isPoisoned, handles(event), engine.allows(.event) else { return nil }
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

    /// Frame-path media delivery: fire-and-forget onto the engine queue, so the
    /// render thread never waits on a script engine. The handler's output drains
    /// through the next frame's `batchTick`, exactly like a cursor event.
    func liveDispatchMediaEvent(
        _ event: WPESceneMediaEvent,
        runtimeSeconds: Double? = nil
    ) {
        guard !isPoisoned, handles(event), engine.allows(.event) else { return }
        _ = engine.dispatchMediaEventAsync(
            event,
            runtimeSeconds: runtimeSeconds,
            publishTo: asyncOutcomeSlot
        )
    }

    private func handles(_ event: WPESceneMediaEvent) -> Bool {
        mediaHandlers.handles(event)
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
                media: WPESceneMediaHandlerSet,
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
        private var faultPolicy = WPEScriptFaultPolicy()
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
        /// One-crossing clock updates; nil until setUp (then falls back to
        /// `wpeRefreshEngineClock` should construction ever fail).
        private var engineClockWriter: WPEEngineClockWriter?
        /// Batched cursor write (one crossing for all 5 fields, assigning onto
        /// the two cached cursor objects above); nil → per-field fallback.
        private var cursorHelper: JSValue?
        /// `update(value)` boolean argument reused across ticks — JS booleans
        /// are immutable, so identity reuse is unobservable and saves one
        /// JSValue creation per tick.
        private var cachedTrueArgument: JSValue?
        private var cachedFalseArgument: JSValue?
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

        /// Async media event: same handler as the synchronous path, but the
        /// output is published to the slot instead of returned to a waiting caller.
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

        /// The `alpha` counterpart of `coercedVisible`.
        static func coercedAlpha(_ result: JSValue?) -> Double? {
            guard let result, !result.isUndefined, !result.isNull, result.isNumber else { return nil }
            let value = result.toDouble()
            return value.isFinite ? value : nil
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
                // `init` returns "the modified value to be applied to the property"
                // just as `update` does (lib.sceneScript.d.ts). Routed through the
                // same setters, so `readOutput()` below reports it exactly like a
                // ticked value; a script that assigns `thisLayer.*` instead and
                // returns nothing is unaffected.
                let returned = initFn.call(withArguments: [])
                switch outputMode {
                case .layerState:
                    if let value = Self.coercedVisible(returned) { setOwnLayerVisible(value) }
                case .returnedAlpha:
                    if let value = Self.coercedAlpha(returned) { setOwnLayerAlpha(value) }
                }
            }
            // A script that throws in init() (e.g. an API we don't yet support)
            // must NOT half-apply — degrade to "shown as authored" so a broken
            // script can't hide its layer, and don't tick its update().
            let media = WPESceneMediaHandlerSet(in: context)
            if didThrow {
                return .ready(
                    hasUpdate: false,
                    handlesUserProperties: handlesUserProperties,
                    media: media,
                    output: WPELayerScriptOutput(
                        own: WPELayerScriptState(visible: true, alpha: 1, videoCommands: []),
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
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
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
            audioBridge?.refresh()
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            guard let context, let updateFunction else {
                return WPELayerScriptOutput(own: .init(visible: true, alpha: 1, videoCommands: []), others: [:])
            }
            let now = WPEScriptFaultPolicy.monotonicNow()
            guard faultPolicy.shouldAttempt(entryPoint: "update", at: now) else { return readOutput() }
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
            didThrow = false
            switch outputMode {
            case .layerState:
                // Official contract for property-attached scripts: update(value) receives the
                // current value; its RETURN becomes the new one. 285/392 visible corpus scripts
                // are pure `return <expr>` (2955378002's 186-sprite calendar), silently frozen
                // at the authored seed; undefined/null returns keep the assignment style
                // (`thisLayer.visible = x`) intact. The LIVE property is the argument, not the
                // last return — an assignment-style script never returns one, so replaying it
                // pinned the seed forever, and `thisLayer.visible = !value` re-inverted that seed
                // every frame. Both styles write `assignedVisible` via the same `defineProperty`
                // setter (`setOwnLayerVisible` for the return path).
                let current = assignedVisible[Self.ownKey] ?? initialOwnVisible
                let arg = (current ? cachedTrueArgument : cachedFalseArgument)
                    ?? JSValue(bool: current, in: context)
                    ?? JSValue(nullIn: context)!
                WPEFrameOccupancyMeter.count(.jscCall)
                if let value = Self.coercedVisible(updateFunction.call(withArguments: [arg as Any])) {
                    setOwnLayerVisible(value)
                }
            case .returnedAlpha:
                // Same contract, and the same defect, as `.layerState` above:
                // the LIVE property is the argument, not the last returned
                // value, or `thisLayer.alpha = 1 - value` reads the seed forever.
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

        /// A SceneScript that throws on EVERY tick used to be completely silent, and
        /// it is not cheap: a missing `thisLayer` method costs ~1000us per tick
        /// against ~10us once the call resolves. One line per instance, so a
        /// permanently-broken script is findable without a per-frame log flood.
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
            guard advanceTimers(to: updateEngineRuntime(runtimeSeconds)) else { return readOutput() }
            updateInput(pointerFrame)
            pendingVideo.removeAll(keepingCapacity: true)
            evaluationResourceBudget.beginEvaluation()
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
            if let engineClockWriter {
                engineClockWriter.refresh(runtime: runtime, frameTime: frameTime)
            } else {
                wpeRefreshEngineClock(in: context, runtime: runtime, frameTime: frameTime)
            }
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
            // Rewritten every tick even when the pointer has not moved: a script
            // that assigns into `input.cursorScreenPosition` / `cursorWorldPosition`
            // must see the host value restored, the way it did before the write was
            // batched into one crossing.
            if let cursorHelper {
                WPEFrameOccupancyMeter.count(.jscCall)
                cursorHelper.call(withArguments: [
                    x * canvasSize.x,
                    y * canvasSize.y,
                    x * canvasSize.x,
                    (1.0 - y) * canvasSize.y,
                    0.0,
                ])
            } else {
                WPEFrameOccupancyMeter.count(.jscSetObject, by: 5)
                cursorScreenPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
                cursorScreenPosition?.setObject(y * canvasSize.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(x * canvasSize.x, forKeyedSubscript: "x" as NSString)
                cursorWorldPosition?.setObject((1.0 - y) * canvasSize.y, forKeyedSubscript: "y" as NSString)
                cursorWorldPosition?.setObject(0.0, forKeyedSubscript: "z" as NSString)
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
            // The stub already answers setFrame/play/pause/stop; it was simply not reachable
            // under this name, so `thisLayer.getTextureAnimation()` threw a TypeError on EVERY
            // tick. Measured: 1039us/tick vs 11us for a script that doesn't throw — 30 bindings
            // of one 415-byte script were 31ms of scene 3299228616's 31.8ms per-frame script cost.
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


#endif
