#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit
import os

/// Path + layer name so the H1 diagnostic mapper blames the failing layer, not the scene entry.
struct WPEMetalTextureLoadContextError: Error {
    let layerName: String
    let path: String
    let underlying: any Error
}

// Not `@MainActor`: lives in one `WPEDisplayRenderActor`. Sync tails (audio,
// on-demand video, static reload) re-enter via the weakly-held `displayActor`.
final class WPEMetalSceneRenderer: NSObject {
    /// Weak back-pointer so Sendable tails re-enter actor isolation instead of capturing `self`.
    weak var displayActor: WPEDisplayRenderActor?

    #if DEBUG
    /// Test-only convenience-init surface. Production init takes Sendable seams so this stays nil.
    var debugSurface: WPERenderSurface?
    #endif

    /// Updated on every committed property patch (actor-side) so an in-place
    /// reload — hibernate wake, detail-view retry — rebuilds the PATCHED scene;
    /// reloading the original would silently revert incremental edits.
    var descriptor: SceneDescriptor
    let cacheRootURL: URL
    let dependencyMounts: [WPEAssetMount]
    /// Install root that contains `assets/`. This object owns the security scope for its lifetime.
    private let engineAssetsRootURL: URL?
    /// Usable engine-assets root: nil if an external scope failed to open. Builders must use this, not the raw root.
    let effectiveEngineAssetsRootURL: URL?
    /// `(unsafe)`: `deinit` is nonisolated and must drop the security scope.
    /// Other writes stay on the display-actor isolation, so mutation is single-threaded.
    nonisolated(unsafe) var activeEngineAssetsRootURL: URL?
    let entryResolver: SceneResourceResolver
    let resourceResolver: WPEMultiRootResourceResolver
    let sceneAssetProvider: (any WPESceneAssetProvider)?
    let projectManifestRootURL: URL?
    let resolutionTracer: WPEResolutionTracer
    /// Sendable surface handle: keeps the renderer region separate so it stays `sending`-adoptable.
    let surfaceControl: any WPESurfaceControl
    let mailbox: WPEPointerMailbox
    /// Last click-capture value this renderer pushed. The mailbox copy is
    /// written on the main thread, so a profile change racing that delivery
    /// would recompute the pointer-monitor gate from a stale read; this keeps
    /// the gate's input in renderer order.
    var lastPushedClickCaptureEnabled: Bool?
    /// Sendable `CAMetalLayer` wrapper so the renderer region does not reach the main-thread surface.
    let metalLayer: WPEPresentLayer
    var surfaceDrawableSize: CGSize
    let executor: WPEMetalRenderExecutor
    let textureLoader: WPEMetalTextureLoader
    var outputTexture: MTLTexture?
    /// Transient producer-chain completion; published with the texture so static-frame re-presents keep the proof.
    var outputFrameProduction: WPEMetalFrameProductionCompletion?
    var latestFrameProduction: WPEMetalFrameProductionCompletion?
    var presentFitMode: WPEPresentFitMode = .cover
    var particleSystems: [WPEParticleSystem] = []
    var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// REFRACT `g_Texture1`. Absent ⇒ the system renders as a flat sprite.
    var particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:]
    var textMeshRenderer: WPETextMeshRenderer?
    var textObjects: [WPESceneTextObject] = []
    /// Plain text is Direct; effect/background text uses Offscreen surfaces from the normal target pool.
    var textRenderPlans: [WPETextRenderPlan] = []
    /// Shared with `textMeshRenderer` so sizing and glyph rasterization resolve the same typeface.
    var textFontResolver: WPETextFontResolver?
    var textLayoutCache: [String: WPETextLayoutCacheEntry] = [:]
    var soundRuntime: WPESoundRuntime?
    /// `WPEAudioDebugLog -bool YES`: throttled log of what this renderer sees on the audio broker.
    let audioDebugLogEnabled = UserDefaults.standard.bool(forKey: "WPEAudioDebugLog")
    var audioDiagCounter = 0
    var textScriptInstances: [String: WPESceneScriptInstance] = [:]
    var layerScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Kept outside `lastStableScriptTransforms` so unassigned authored animation keeps advancing.
    var layerTransformMutationJournal = WPESceneScriptTransformMutationJournal()
    /// TEXT visible/alpha scripts (3509243656 login-intro fades). Outputs land in `liveTextVisibility`/`liveTextAlpha`.
    var textVisibleScriptInstances: [String: WPELayerScriptInstance] = [:]
    var textAlphaScriptInstances: [String: WPELayerScriptInstance] = [:]
    var liveTextAlpha: [String: Double] = [:]
    var layerHoverStates: [String: Bool] = [:]
    var sceneScriptSharedState: WPESharedScriptState?
    /// Per-renderer workers so a script-heavy display cannot delay a light one's ticks.
    let sceneScriptBatchDispatcher = WPESceneScriptBatchDispatcher(
        width: WPESceneScriptContainmentDefaults.batchWorkerWidth
    )
    var pendingSceneScriptBatchJobs: [WPESceneScriptBatchDispatcher.Job] = []
    let sceneScriptLoadState = WPESceneScriptLoadState()
    /// Last complete cross-family presentation. A mid-family resource-ceiling latch keeps transforms/text here instead of baking them while layers freeze.
    var lastStableScriptTransforms = LiveScriptTransforms()
    var lastStableScriptTextByID: [String: String] = [:]
    var sceneScriptVideoCommandBuffer = WPESceneScriptVideoCommandBuffer()
    /// Staged with the SceneScript video transaction. AVPlayer seek waits until every script family and frame encode succeed.
    var sceneScriptIntroPhaseAlignPending = false
    /// Signpost identity derived without touching actor state, so two displays' frames stay distinct in a trace.
    nonisolated var rendererSignpostID: UInt64 {
        UInt64(UInt(bitPattern: ObjectIdentifier(self)))
    }
    /// Alpha-field scripts. They return a scalar and intentionally do not affect visibility.
    var layerAlphaScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    var dynamicOriginScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Keyframed `origin` on the same live-transform map as origin scripts (3448877775 meteor host gates its stars).
    var dynamicOriginAnimations: [String: WPESceneAnimatedValue] = [:]
    var dynamicScaleScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    var dynamicAnglesScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    var dynamicColorScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    var effectConstantScriptInstances: [WPEEffectConstantScriptKey: WPEDynamicTransformScriptInstance] = [:]
    /// Keyed by `WPEPassVisibilityGate.id` so clones of one effect share a single JS instance.
    var effectVisibilityScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:]
    /// Load-scoped memo of installed-script layer IDs. Cleared by `didSet` on every mutation of those dictionaries.
    var cachedInstalledScriptLayerIDs: Set<String>?
    /// WPE `solid` groups: no pixels, but they compose into child layers.
    var transformHostLocalTransformsByID: [String: WPERenderObjectTransform] = [:]
    /// Video source key for `getVideoTexture()`. Populated for ALL video layers, not just scripted ones.
    var layerVideoSourceKey: [String: String] = [:]
    var layerObjectIDByName: [String: String] = [:]
    /// Scene-output-only videos, resident while visible. Each 4K source is ~300 MB; `reconcileVideoResidency` flips per frame.
    var onDemandVideoKeyByID: [String: String] = [:]
    /// In-flight rebuilds, so a still-visible layer does not spawn a duplicate Task.
    var onDemandVideoLoading: Set<String> = []
    var liveLayerAlpha: [String: Double] = [:]
    var liveCreatedLayers: [String: WPECreatedLayerScriptState] = [:]
    /// Hidden template layers are retained only when a script references them.
    var createdLayerTemplatesByImagePath: [String: WPEPreparedRenderLayer] = [:]
    /// Intro and loop are often the same clip out of phase. Measure `intro@t ≈ loop@(t+offset)` once and slave the loop playhead.
    var introPhaseSource: WPEVideoTextureSource?
    var loopPhaseSource: WPEVideoTextureSource?
    var introLoopOffset: TimeInterval?
    /// Bumped per reload so a slow async measurement from a prior scene is ignored.
    var introPhaseToken = 0
    var loadedTextures: [String: MTLTexture] = [:]
    /// VRAM-budget bookkeeping. Dynamic/video sources are never tracked here.
    struct StaticTextureCacheRecord: Sendable {
        let layerName: String
        let candidates: [String]
        var bytes: Int
    }
    var staticTextureCacheRecords: [String: StaticTextureCacheRecord] = [:]
    var textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: 0)
    var textureCacheBudgetBytesInUse: Int?
    /// Per-load snapshot of `Self.textureCacheBudgetBytes`. The frame path must never read UserDefaults.
    var textureCacheBudgetBytesResolved: Int?
    var staticTexturePlaceholderPaths: Set<String> = []
    let staticTextureReloadTaskOwner = WPEStaticTextureReloadTaskOwner()
    var staticTextureReloadThrottles: [String: WPEStaticTextureReloadThrottle] = [:]
    /// Memo of `activeStaticTexturePaths`. A hash collision only mis-protects for one frame; placeholder+reload self-heals.
    var cachedActiveStaticPaths: Set<String> = []
    var cachedActiveStaticSignature: Int?
    var staticTextureRecordsEpoch = 0
    var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:] {
        didSet {
            cachedDynamicTextureNames = nil
            // On-demand video release/rebuild flips frame demand at runtime (the
            // released-videos-only scene may pause; a rebuilt one must resume).
            // Load-time churn is skipped: the load tail re-applies the profile.
            if didLoad { synchronizeFrameDemand() }
        }
    }
    /// Memo of `dynamicTextureSources.keys`. Mutations are cold and clear it via `didSet`; the frame path only reads.
    private var cachedDynamicTextureNames: Set<String>?
    var dynamicTextureNames: Set<String> {
        if let cached = cachedDynamicTextureNames { return cached }
        let names = Set(dynamicTextureSources.keys)
        cachedDynamicTextureNames = names
        return names
    }
    var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
    var cameraUniforms: WPEMetalCameraUniforms = .identity
    var frameClock: WPEMetalFrameClock
    /// Oracle-only frozen frame globals (read once at load). `nil` in production.
    let oracleFrameOverride = WPEOracleMode.loadFrameOverride()
    let pointerSampler: WPEMetalPointerSampler
    let snapshotter: WPEMetalTextureSnapshotter
    var cachedSnapshot: NSImage?
    var pendingLivePosterCaptures: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
    var didLoad = false
    /// Bumped on load/teardown so a deferred task can bail on a stale scene.
    var loadGeneration = 0
    /// Sound scenes only; consumed by the first successful `present` so audio starts after the first on-screen frame.
    var pendingAudioStartupDocument: WPESceneDocument?
    var deferredAudioStartupTask: Task<Void, Never>?

    #if DEBUG
    var debugAudioStartupPending: Bool { pendingAudioStartupDocument != nil }
    var debugSoundRuntimeActive: Bool { soundRuntime != nil }
    #endif
    /// Scene-level camera parallax plus the per-frame ramp that drives each layer's depth shift.
    var cameraParallaxSettings: WPESceneCameraParallaxSettings = .disabled
    var cameraParallaxSmoother = WPECameraParallaxSmoother()
    /// Per-machine parallax multiplier. `defaults write com.loomscreen.pro WPEParallaxGain <number>` then reload.
    let cameraParallaxGain = WPEMetalSceneRenderer.resolvedParallaxGain()
    var currentProfile: WallpaperPerformanceProfile = .quality
    /// False pins the pointer to screen center. Default on preserves historical Follow-Cursor behavior.
    var mouseInteractionEnabled = true
    var previousPointer = SIMD2<Double>(0.5, 0.5)
    /// Live/inactive edge so pointer-spawned particles drop as soon as the cursor leaves this screen.
    var previousPointerWasLive = false
    /// Previous pointer/button frame so SceneScript cursor down/up edges fire once per transition.
    var previousLayerScriptPointerFrame = WPEPointerFrame.neutral
    var userPreferredFPS: Int = WPEMetalSceneRenderer.defaultPreferredFPS
    var adaptiveThrottleActive = false
    /// Cached so callers arriving before deferred audio startup still record mute/volume; re-applied just before `play()`.
    var pendingAudioMuted: Bool = false
    var pendingAudioVolume: Double = 1.0
    /// Last pacing decision derived from `needsContinuousFrames`, so the per-frame
    /// demand re-check touches pacing only on a transition. Nil while suspended
    /// (the next `.quality` application must re-apply unconditionally).
    var lastAppliedContinuousFrames: Bool?
    /// Session-facing push fired when frame/audio demand changes (App Nap mirror).
    /// Set once by the builder before the actor adopts the renderer.
    var onRuntimeActivityChange: (@Sendable (WPESceneRuntimeActivity) -> Void)?
    /// Dedupe for `onRuntimeActivityChange`.
    var lastPublishedRuntimeActivity: WPESceneRuntimeActivity?
    /// Preset level multiplies the master volume; it does not replace it.
    var presetAudioSettings: WPEEngineAudioSettings?

    var hasPresentedFrame: Bool {
        completedPresentGeneration == loadGeneration
    }
    /// Last load generation whose present command buffer completed. Readiness keys off this, not `commit()`, because Metal can fail asynchronously afterwards.
    var completedPresentGeneration: Int?
    /// Terminal present failure for a not-yet-ready load, so session prep fails promptly instead of waiting out its timeout.
    var failedPresentGeneration: Int?
    var loadDiagnostics: SceneLoadDiagnostic?
    var renderGraph: WPERenderGraph?
    var renderPipeline: WPEPreparedRenderPipeline?
    /// Effect / custom-shader passes animate via `g_Time` / `g_AudioSpectrum*`. Without this the view draws one frame and freezes.
    var hasAnimatedShaderPasses = false
    /// WPE `general.supportsaudioprocessing`. `pipelineHasAnimatedPasses` misses custom-path audio shaders, which would otherwise freeze on the static path.
    var sceneSupportsAudioProcessing = false
    var liveEffectConstants: [String: [String: WPESceneShaderConstantValue]] = [:]
    var liveEffectVisibility: [String: Bool] = [:]
    var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
    var lastFramePipeline: WPEPreparedRenderPipeline?
    var scenePropertyBindings: [String: [WPEScenePropertyBinding]] = [:]
    var liveLayerVisibility: [String: Bool] = [:]
    var liveTextVisibility: [String: Bool] = [:]
    /// Fold a layer script's `visible` against ancestors' CURRENT visibility so a script cannot show a layer under a hidden ancestor.
    var objectParentByID: [String: String] = [:]
    var ownVisibilityByID: [String: Bool] = [:]
    /// Authored parallax depth/origin for every object, including groups, for the rigid-subtree root walk.
    var parallaxAuthoredDepthByObjectID: [String: SIMD2<Double>] = [:]
    var parallaxAuthoredOriginByObjectID: [String: SIMD2<Double>] = [:]

    /// Test hook: assert a HIDDEN text object's compute script still ran (`shared` populated).
    func sharedScriptValueForTesting(_ key: String) -> Any? {
        sceneScriptSharedState?.get(key)
    }

    var onProgress: (@Sendable (String) -> Void)?
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot {
        resolutionTracer.snapshot()
    }
    /// GPU command-buffer errors since load. They fire post-return on a GPU thread and never reach `loadDiagnostics`.
    var gpuErrorSummary: (count: Int, last: String?) {
        executor.gpuErrorSink.summary
    }

    /// Custom-shader compile failures (the only Release-visible signal). A failed pass is silently skipped.
    var shaderErrorSummary: (count: Int, entries: [(shader: String, reason: String)]) {
        executor.shaderErrorSink.summary
    }

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        assetProvider: (any WPESceneAssetProvider)? = nil,
        projectManifestRootURL: URL? = nil,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        surfaceControl: any WPESurfaceControl,
        mailbox: WPEPointerMailbox,
        presentLayer: WPEPresentLayer,
        drawableSize: CGSize,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler? = nil,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.dependencyMounts = dependencyMounts
        self.engineAssetsRootURL = engineAssetsRootURL
        let executor = try WPEMetalRenderExecutor(device: device)
        let resolutionTracer = WPEResolutionTracer()
        // Container-internal installs have no security scope; `startAccessingSecurityScopedResource()` returns false for them.
        let needsScope = engineAssetsRootURL.map { !WPEEngineAssetsLibrary.isContainerInternal($0) } ?? false
        let didStartEngineAssetsAccess = needsScope
            ? (engineAssetsRootURL?.startAccessingSecurityScopedResource() ?? false)
            : false
        // Only feed the resolver a root that needs no scope or whose scope actually opened.
        let effectiveEngineAssetsRootURL: URL? = engineAssetsRootURL.flatMap {
            (!needsScope || didStartEngineAssetsAccess) ? $0 : nil
        }
        // Only the scoped case has access to stop on teardown.
        self.activeEngineAssetsRootURL = didStartEngineAssetsAccess ? engineAssetsRootURL : nil
        self.effectiveEngineAssetsRootURL = effectiveEngineAssetsRootURL
        self.sceneAssetProvider = assetProvider
        self.projectManifestRootURL = projectManifestRootURL
        if let assetProvider {
            self.entryResolver = SceneResourceResolver(provider: assetProvider, cacheRootURL: cacheRootURL)
            self.resourceResolver = WPEMultiRootResourceResolver(
                primaryProvider: assetProvider,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: effectiveEngineAssetsRootURL,
                tracer: resolutionTracer
            )
        } else {
            self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
            self.resourceResolver = WPEMultiRootResourceResolver(
                primaryRootURL: cacheRootURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: effectiveEngineAssetsRootURL,
                tracer: resolutionTracer
            )
        }
        self.resolutionTracer = resolutionTracer
        self.executor = executor
        self.textureLoader = WPEMetalTextureLoader(device: device)
        self.surfaceControl = surfaceControl
        self.mailbox = mailbox
        self.metalLayer = presentLayer
        self.surfaceDrawableSize = drawableSize
        self.frameClock = frameClock
        self.pointerSampler = pointerSampler ?? .mailbox(mailbox)
        self.snapshotter = snapshotter
        super.init()

        if needsScope && !didStartEngineAssetsAccess {
            Logger.warning(
                "Wallpaper Engine assets security scope could not be started — engine fallback disabled for this session",
                category: .fileAccess
            )
        }

    }

    /// Legacy/test convenience: builds the main-thread surface here (hence `@MainActor`) and forwards Sendable seams.
    @MainActor
    convenience init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        assetProvider: (any WPESceneAssetProvider)? = nil,
        projectManifestRootURL: URL? = nil,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        frame: CGRect,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler? = nil,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        let surface = WPERenderSurface(frame: frame, device: device)
        try self.init(
            descriptor: descriptor,
            cacheRootURL: cacheRootURL,
            assetProvider: assetProvider,
            projectManifestRootURL: projectManifestRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            frameClock: frameClock,
            pointerSampler: pointerSampler,
            snapshotter: snapshotter
        )
        #if DEBUG
        self.debugSurface = surface
        #endif
    }

    func updateSurfaceGeometry(drawableSize: CGSize) {
        surfaceDrawableSize = drawableSize
    }

    #if DEBUG
    var didDumpScenePassesOverTime = false
    #endif

    /// `WPEParallaxGain` from `com.loomscreen.pro` then `.standard`. Present values go through `clampedGain`.
    private static func resolvedParallaxGain() -> Double {
        for defaults in [UserDefaults.appSuite, .standard] {
            guard defaults.object(forKey: "WPEParallaxGain") != nil else { continue }
            return WPECameraParallaxFrame.clampedGain(defaults.double(forKey: "WPEParallaxGain"))
        }
        return WPECameraParallaxFrame.defaultGain
    }

    var hoverDebugCounter = 0

    deinit {
        sceneScriptLoadState.retireCurrent()
        stopEngineAssetsAccessIfNeeded()
        // Backstop if cleanup()/reload() never ran: AVFoundation retains AVQueuePlayer on CoreMedia threads, so ARC will not stop the decoder.
        releaseDynamicTextureSources()
    }

    /// Suppresses repeat `draw(in:)` failure logs so a broken pipeline warns once, not once per frame.
    var didLogFrameFailure = false

}

#endif
