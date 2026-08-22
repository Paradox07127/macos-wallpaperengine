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
    /// Set at construction from the screen's configuration. A default here would
    /// be indistinguishable from a real user choice, and the MetalFX plan reads
    /// it during `load()` — which races the async config submit that used to be
    /// the only way it arrived.
    var presentFitMode: WPEPresentFitMode
    /// MetalFX render-scale verdict for the loaded scene. Decided once in
    /// `performLoad` from the world canvas, drawable, fit mode and HDR flag,
    /// then read by the executor (target sizes) and the texture loader (upload
    /// caps). `.inactive` before a scene loads.
    /// The MetalFX verdict lives on the executor — the per-frame consumer, and
    /// the place a present-time decline is discovered. Keeping a second copy
    /// here meant a demote written by `encodePresent` never reached the
    /// re-planning path, which then read a stale `.active` and un-stuck it.
    var upscalePlan: WPEMetalUpscalePlan { executor.upscalePlan }
    /// Set once a plan has been decided. Distinguishes "never planned" from a
    /// real `.settingOff` verdict, which the plan value alone cannot.
    var hasPlannedUpscale = false
    /// Adopt the drawable size a presented frame actually used. This is the only
    /// moment the true size is guaranteed knowable — `nextDrawable()` is what
    /// finally sizes the layer — so it backstops a seed that was wrong or a
    /// display that was reconfigured. Cheap: a CGSize compare per frame.
    func adoptPresentedDrawableSize() {
        let presented = executor.lastPresentedDrawableSize
        guard presented.width > 0, presented != surfaceDrawableSize else { return }
        updateSurfaceGeometry(drawableSize: presented)
    }

    /// Drains a present-side demote. `refreshUpscalePlan` cannot cover this
    /// transition: `demotedToNative()` already wrote scale 1.0 and `adopting`
    /// keeps `.declinedAtPresent` sticky, so the next refresh sees no change and
    /// returns early. Called at the end of the frame, after present committed.
    func adoptPresentSideDemotion() {
        guard executor.takePresentSideDemotion() else { return }
        executor.releaseRenderScaleDependentResources()
        pendingForcedRerender = true
        surfaceControl.setNeedsRedraw()
    }

    /// Forces exactly one full re-render even for a scene with no frame demand.
    /// A static scene re-presents its cached `outputTexture`, which is at the
    /// OLD render scale after the plan changes — `.center` would then show a
    /// downsampled frame at 1:1 forever.
    var pendingForcedRerender = false
    /// The source-texture cap actually used for this scene's uploads, latched at
    /// `loadTextures`. Uploads are the one irreversible step, so the cap is
    /// decided there rather than when the plan is first computed — by then the
    /// fit mode or drawable may still be in flight.
    var latchedTextureCap: Int?
    var didLatchTextureCap = false
    var particleSystems: [WPEParticleSystem] = []
    var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// REFRACT `g_Texture1`. Absent ⇒ the system renders as a flat sprite.
    var particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Load-scoped sprite/normal atlas cache. Sibling systems sharing a path
    /// keep one `MTLTexture`; keys keep linear normals distinct from sRGB sprites.
    struct ParticleTextureLoadKey: Hashable {
        let path: String
        let colorSpace: WPEMetalColorSpace
    }
    var particleTextureLoadCache: [ParticleTextureLoadKey: WPELoadedTextureResource] = [:]
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
    /// Every video layer's texture key. Each 4K source is ~300 MB; residency is decided by
    /// `onDemandVideoKeysByConsumerID`, which `reconcileVideoResidency` flips per frame.
    var onDemandVideoKeyByID: [String: Set<String>] = [:]
    /// Load-time consumer graph: layer objectID → the video keys that layer's
    /// visibility keeps resident (it samples the video, or samples an FBO the
    /// video's pixels reach). Static — only visibility is per frame.
    var onDemandVideoKeysByConsumerID: [String: Set<String>] = [:]
    /// Image path → consumed video keys, so a script-created clone (fresh
    /// objectID, absent from the graph above) inherits its template's entry.
    var onDemandVideoKeysByImagePath: [String: Set<String>] = [:]
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
    /// Consecutive static/on-demand `nextDrawable` misses for the current output.
    /// Non-zero keeps the paused display link ticking until present succeeds or
    /// `WPEStaticPresentRetry` fails the generation. Not a `WPEFrameDemand` bit:
    /// the scene itself is idle; only the first present is outstanding.
    var pendingPresentRetryCount = 0
    /// Scene content demand, or a bounded present retry for a cached static frame.
    var needsPacingLoop: Bool { needsContinuousFrames || pendingPresentRetryCount > 0 }
    #if DEBUG
    /// `renderAndPresentFrame` took the re-encode branch. Tests pin that a present
    /// retry does not increment this.
    var frameEncodeCountForTesting = 0
    #endif
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
        presentFitMode: WPEPresentFitMode = .cover,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler? = nil,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        self.presentFitMode = presentFitMode
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
        presentFitMode: WPEPresentFitMode = .cover,
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
            // `backingDrawableSize`, never the layer: a CAMetalLayer reads 0x0
            // until the first `nextDrawable()`, which would leave every scene
            // built through this initializer permanently unable to plan.
            drawableSize: surface.backingDrawableSize,
            presentFitMode: presentFitMode,
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
        // A sizeless report means "not laid out yet", never "the surface is now
        // zero". `WPERenderSurface.attach` pushes exactly that immediately after
        // construction — before the view is in a window — and letting it through
        // would clobber the size the builder seeded from the screen, leaving the
        // MetalFX plan with no drawable for the scene's whole life.
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard drawableSize != surfaceDrawableSize else { return }
        surfaceDrawableSize = drawableSize
        refreshUpscalePlan(reason: "geometry")
    }

    /// The ONE place the MetalFX verdict is decided. Its three inputs arrive at
    /// different times — the world canvas from scene parsing, the drawable size
    /// from window layout (async), the fit mode from a runtime config submit —
    /// so the plan is a derived value refreshed on every input change rather
    /// than computed once and patched afterwards.
    ///
    /// `isInitial` marks the load-time call, the only one allowed to establish
    /// the source-texture cap: those uploads happen during load and cannot be
    /// redone, so every later refresh carries the original cap forward.
    func refreshUpscalePlan(reason: String, isInitial: Bool = false) {
        guard isInitial || hasPlannedUpscale else { return }
        let drawableSize = surfaceDrawableSize
        let fresh = WPEMetalUpscalePlan.make(
            worldCanvas: sceneRenderSize,
            drawableSize: drawableSize,
            fitMode: presentFitMode,
            isHDR: cameraUniforms.sceneHDR,
            renderScale: WPEMetalFXSpatialUpscaler.renderScale,
            deviceSupportsScaler: WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler
        )
        let previous = executor.upscalePlan
        let updated = isInitial ? fresh : previous.adopting(fresh)
        hasPlannedUpscale = true
        executor.upscalePlan = updated
        guard isInitial || updated.renderPixelScale != previous.renderPixelScale else { return }
        if !isInitial {
            // Every pixel-keyed resource is stale now — not just the composite
            // cache. Leaving them stranded the old allocations for the scene's
            // life and kept serving old-resolution textures to `.previous`.
            executor.releaseRenderScaleDependentResources()
            // The presented frame is at the old scale too. A continuous scene
            // redraws next tick; a static one would re-present it forever.
            pendingForcedRerender = true
            surfaceControl.setNeedsRedraw()
        }
        guard updated.verdict != .settingOff else { return }
        Logger.notice(
            "[metalfx] plan \(updated.verdict.rawValue) scale=\(updated.renderPixelScale) "
                + "canvas=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height)) "
                + "drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) "
                + "textureCap=\(updated.maxSourceTextureEdge.map(String.init) ?? "none") "
                + "(\(reason))",
            category: .wpeRender
        )
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
