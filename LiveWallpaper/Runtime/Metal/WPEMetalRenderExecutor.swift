#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

final class WPEMetalRenderExecutor {
    /// Every offscreen target and the on-screen swapchain share
    /// a single sRGB pixel format so render pipelines built for the offscreen
    /// pass can be reused by `present()` without re-creation, and so the
    /// rendered gamma stays stable across offscreen and onscreen passes.
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb
    /// Per-scene output format: `.rgba16Float` for HDR scenes so >1 emissive
    /// survives to the bloom prefilter (an 8-bit target clamps at scene write,
    /// which killed the sun glow); SDR scenes keep the 8-bit sRGB target.
    /// `WPEMetalTextureSnapshotter` clamp+sRGB-encodes rgba16Float, so HDR
    /// scenes get posters/first-frame.png too (fixed 2026-07-06).
    var currentOutputPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat

    /// Optional developer override for the per-puppet deferred-warp decision (see
    /// `shouldDeferPuppetMeshWarp`). `nil` (the default, and always in Release) means "decide
    /// automatically per puppet"; an explicit DEBUG `defaults write com.loomscreen.pro
    /// WPEPuppetDeferMeshWarp -bool YES|NO` forces the warp deferred/direct for every non-clip puppet
    /// (A/B testing). Clip-composite puppets ignore this and never defer.
    static var deferPuppetMeshWarpOverride: Bool? {
        #if DEBUG
        return puppetDefaultsFlagOptional("WPEPuppetDeferMeshWarp")
        #else
        return nil
        #endif
    }

    /// WPE genericimage4 puppet clip-composite (clip-mask RT + CLIPPINGTARGET) so an eye
    /// puppet's pupil is occluded when the blink closes. Default ON; opt out with
    /// `defaults write com.loomscreen.pro WPEPuppetClipComposite -bool NO`.
    /// Still only takes effect when the builder injected a clip-mask binding (texture slot 8).
    static let puppetClipCompositeEnabled: Bool = puppetDefaultsFlagOptional("WPEPuppetClipComposite") ?? true

    /// Reads a puppet bool override from the app's `com.loomscreen.pro` suite first, falling back to
    /// the process `.standard` domain while preserving "unset" (`nil`). Puppet flags MUST share this
    /// so `defaults write com.loomscreen.pro …` is honoured uniformly even when the renderer runs in
    /// a process whose standard domain isn't the app's.
    static func puppetDefaultsFlagOptional(
        _ key: String,
        suite: UserDefaults = .appSuite,
        standard: UserDefaults = .standard
    ) -> Bool? {
        if suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        if standard.object(forKey: key) != nil {
            return standard.bool(forKey: key)
        }
        return nil
    }

    static let staticLayerCacheDefaultsKey = "WPEMetalStaticLayerCacheEnabled"
    static let staticLayerCacheBudgetMiBDefaultsKey = "WPEMetalStaticLayerCacheBudgetMiB"

    /// Opt-in exact composite cache for static WPE layers. Default OFF so the
    /// existing render path stays byte-identical unless explicitly enabled
    /// (`defaults write … WPEMetalStaticLayerCacheEnabled -bool YES`).
    /// Read once on first use, then cached — restart to apply. `readStaticLayerCacheEnabled()`
    /// exposes the live read for tests.
    static let isStaticLayerCacheEnabled: Bool = readStaticLayerCacheEnabled()
    static func readStaticLayerCacheEnabled() -> Bool {
        UserDefaults.standard.object(forKey: staticLayerCacheDefaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: staticLayerCacheDefaultsKey)
    }

    /// VRAM budget for cached composites (MiB; default 256). Over budget → LRU
    /// eviction, and the evicted layer falls back to re-rendering (slower, never wrong).
    /// Read once on first use, then cached — restart to apply.
    static let staticLayerCacheBudgetBytes: Int = {
        let raw = UserDefaults.standard.object(forKey: staticLayerCacheBudgetMiBDefaultsKey)
        let mib = (raw as? NSNumber)?.intValue ?? 256
        return max(0, mib) * 1_048_576
    }()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// The app's compiled `.metallib`, fetched once in `init` — `makeDefaultLibrary()`
    /// re-loads the library bundle on every call, so per-pipeline fetches were pure waste.
    let defaultLibrary: MTLLibrary
    lazy var gpuPassProfiler = WPEMetalPassGPUProfiler.makeIfEnabled(device: device)
    /// nil unless `WPEMetalFXRenderScale` is on.
    lazy var metalFXUpscaler = WPEMetalFXSpatialUpscaler.makeIfEnabled(device: device, library: defaultLibrary)
    let targetPool: WPEMetalRenderTargetPool
    let depthCache: WPEMetalDepthStateCache
    private let pipelineCache: WPEMetalPipelineCache
    let shaderCompiler: WPESwiftShaderCompiler
    var translatedShaderCache: [String: WPEShaderCompileResult] = [:]

    /// Per-pass fast path keyed by `WPEPreparedRenderPass.id`. `translatedShaderCache`
    /// is keyed by a hash of the *preprocessed* source, so reaching it requires
    /// running the (expensive) GLSL preprocessor every frame just to compute the
    /// key — which dominated the main thread in profiling (custom-shader passes
    /// re-preprocessed every frame). The prepared pipeline is built once at load
    /// and reused per frame, so a pass's result is invariant; caching by pass id
    /// skips the preprocess entirely on the hot path. Pass ids can recur across
    /// scenes, so this is cleared on reload (via `releaseTransientResources`).
    var compiledShaderResultByPassID: [String: WPEShaderCompileResult] = [:]

    /// Frame-global uniforms for the current `render` call. Single render thread.
    var frameUniformContext: WPEFrameUniformContext = .empty

    /// Case-insensitive uniform-key index, keyed by pass id. Rebuilds when a
    /// dict count changes. Cleared on reload.
    struct UniformKeyIndex {
        let uniformCount: Int
        let constantsCount: Int
        /// lowercased → canonical. Case-variant collisions pick one and freeze it.
        let uniformKeys: [String: String]
        let constantsKeys: [String: String]
    }

    private var uniformKeyIndexByPassID: [String: UniformKeyIndex] = [:]

    func uniformKeyIndex(for pass: WPEPreparedRenderPass) -> UniformKeyIndex {
        if let cached = uniformKeyIndexByPassID[pass.id],
           cached.uniformCount == pass.uniformValues.count,
           cached.constantsCount == pass.pass.constants.count {
            return cached
        }
        let index = UniformKeyIndex(
            uniformCount: pass.uniformValues.count,
            constantsCount: pass.pass.constants.count,
            uniformKeys: Self.lowercasedKeyMap(pass.uniformValues),
            constantsKeys: Self.lowercasedKeyMap(pass.pass.constants)
        )
        uniformKeyIndexByPassID[pass.id] = index
        return index
    }

    func invalidateUniformKeyIndexes() {
        uniformKeyIndexByPassID.removeAll()
    }

    /// Compiled per-slot uniform source plans. Cleared on reload.
    var uniformPlansByPassID: [String: PassUniformPlans] = [:]

    /// Test seam: cache hit vs silent per-frame recompile.
    var uniformPlanCompileCount = 0

    func invalidateUniformPlans() {
        uniformPlansByPassID.removeAll()
        uniformPlanCompileCount = 0
    }

    private static func lowercasedKeyMap(
        _ values: [String: WPESceneShaderConstantValue]
    ) -> [String: String] {
        var map = [String: String](minimumCapacity: values.count)
        for key in values.keys {
            let lowered = key.lowercased()
            if map[lowered] == nil { map[lowered] = key }
        }
        return map
    }

    /// Blend-string facts, memoized per raw spelling. Content-keyed, never invalidated.
    private struct BlendStringFacts {
        let lowercased: String
        let requiresExistingDestination: Bool
    }

    private var blendStringFactsCache: [String: BlendStringFacts] = [:]

    private var skewShaderPathCache: [String: Bool] = [:]

    /// Per-frame alias-interval scratch. Valid only within one `fboAliasIntervals` call.
    final class FBOAliasIntervalScratch {
        var keys: [WPEMetalRenderTargetKey?] = []
        var firstPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var secondaryKeys: Set<WPEMetalRenderTargetKey> = []
        var nonAliasKeys: Set<WPEMetalRenderTargetKey> = []

        func removeAll(keepingCapacity: Bool) {
            keys.removeAll(keepingCapacity: keepingCapacity)
            firstPassByKey.removeAll(keepingCapacity: keepingCapacity)
            lastPassByKey.removeAll(keepingCapacity: keepingCapacity)
            secondaryKeys.removeAll(keepingCapacity: keepingCapacity)
            nonAliasKeys.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    let fboAliasIntervalScratch = FBOAliasIntervalScratch()

    /// Structural half of the alias-interval scan. Revalidated against the pipeline.
    var cachedFBOAliasTopology: FBOAliasTopology?
    /// Test seam: cache hit vs silent rebuild.
    var fboAliasTopologyRebuildCount = 0

    /// One prepared pass can drive several pipeline states; (variant, pass id) names one.
    enum PassPSOVariant: UInt8 {
        case solidColor, solidLayer, blendComposite, copy
        case localSceneCapture, composeLayer, compose
        case genericImage2, genericImage4, godraysCombine, effect
    }

    /// First-level PSO cache. A miss still goes through `WPEMetalPipelineCache`.
    struct PassPSOKey: Hashable {
        let passID: String
        let variant: PassPSOVariant
        /// Vertex function flips with live camera parallax.
        let objectQuad: Bool
        /// `replacingBlending` can change the spelling under the same pass id.
        let blending: String
        let alphaWritePolicy: WPEMetalAlphaWritePolicy
        let colorPixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat
    }

    private var passPipelineStates: [PassPSOKey: MTLRenderPipelineState] = [:]

    /// Test seam: first-level hit vs re-resolve through `WPEMetalPipelineCache`.
    private(set) var passPipelineResolveCount = 0

    func passPipelineState(
        passID: String,
        variant: PassPSOVariant,
        objectQuad: Bool = false,
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String,
        alphaWritePolicy: WPEMetalAlphaWritePolicy,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = PassPSOKey(
            passID: passID,
            variant: variant,
            objectQuad: objectQuad,
            blending: blendMode,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        if let cached = passPipelineStates[key] {
            return cached
        }
        passPipelineResolveCount += 1
        let state = try renderPipeline(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        passPipelineStates[key] = state
        return state
    }

    func invalidatePassPipelineStates() {
        passPipelineStates.removeAll()
    }

    /// Reusable fragment-texture slot table for one dispatch.
    let customTextureSlotScratch = WPEMetalTextureSlotTable()

    private func blendFacts(_ blendMode: String) -> BlendStringFacts {
        if let cached = blendStringFactsCache[blendMode] { return cached }
        let facts = BlendStringFacts(
            lowercased: blendMode.lowercased(),
            requiresExistingDestination: Self.blendModeRequiresExistingDestination(blendMode)
        )
        blendStringFactsCache[blendMode] = facts
        return facts
    }

    /// Sampler states for transpiled shaders' per-slot `wpeSampler<slot>` bindings,
    /// keyed by (clampUVs, noInterpolation). Only four combinations exist, so this
    /// stays tiny; created lazily on first use.
    private var customSamplerStateCache: [Int: MTLSamplerState] = [:]

    /// The `MTLSamplerState` for a custom-shader texture slot, driven by the bound
    /// texture's TEXI flags (registered at load in `WPEMetalTextureMetadataRegistry`).
    /// Unregistered textures (render targets / framebuffers) and unbound slots fall
    /// back to clamp-to-edge + linear — the safe default that never wraps.
    func customShaderSamplerState(for texture: MTLTexture?) -> MTLSamplerState {
        let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
        let clamp = resolution?.clampUVs ?? true
        let nearest = resolution?.noInterpolation ?? false
        let key = (clamp ? 1 : 0) | (nearest ? 2 : 0)
        if let cached = customSamplerStateCache[key] { return cached }
        let descriptor = customShaderSamplerDescriptor(clamp: clamp, nearest: nearest)
        // Force-unwrap matches the executor's other GPU-object creation: a valid
        // descriptor never fails to produce a sampler state on a live device.
        let state = device.makeSamplerState(descriptor: descriptor)!
        customSamplerStateCache[key] = state
        return state
    }

    /// The single source of truth for the custom-pass sampler. The oracle's
    /// trace describes THIS descriptor rather than re-deriving address/filter,
    /// so a recorded sampler can never drift from the bound one.
    func customShaderSamplerDescriptor(clamp: Bool, nearest: Bool) -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = nearest ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        if WPEMetalTextureLoader.allowsMipFiltering, !nearest {
            // Default `.notMipmapped` samples level 0 only, matching today's
            // level-0-only upload; opt in to trilinear filtering across the
            // chain the loader now uploads under the same flag. Nearest
            // (noInterpolation) textures stay level-0-only: they hold discrete
            // data, and a fractional LOD would blend adjacent mips' entries.
            descriptor.mipFilter = .linear
        }
        let address: MTLSamplerAddressMode = clamp ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        return descriptor
    }

    #if !LITE_BUILD && DEBUG
    /// Trace-only: the bound sampler's address/filter/mip as strings, read off
    /// the same descriptor `customShaderSamplerState` binds. Windows records a
    /// full D3D11_SAMPLER_DESC; without this the diff is blind to wrap-mode
    /// divergence — the exact failure that froze scrolling ripple UVs.
    func customShaderSamplerDescription(for texture: MTLTexture?) -> [String: String] {
        let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
        let descriptor = customShaderSamplerDescriptor(
            clamp: resolution?.clampUVs ?? true,
            nearest: resolution?.noInterpolation ?? false
        )
        func address(_ mode: MTLSamplerAddressMode) -> String {
            mode == .repeat ? "repeat" : mode == .clampToEdge ? "clampToEdge" : "\(mode.rawValue)"
        }
        return [
            "addressS": address(descriptor.sAddressMode),
            "addressT": address(descriptor.tAddressMode),
            "minFilter": descriptor.minFilter == .nearest ? "nearest" : "linear",
            "magFilter": descriptor.magFilter == .nearest ? "nearest" : "linear",
            "mipFilter": descriptor.mipFilter == .linear ? "linear" : "notMipmapped"
        ]
    }
    #endif

    /// Merge pre-warmed transpile results into the shader cache. Called on the
    /// main actor AFTER the warm task group drains and BEFORE the first
    /// `render()`, so it never races the lazy compile path (which also runs on
    /// the main actor during render). Idempotent: same source-hash key ⇒ same
    /// deterministic result, so an existing entry is left untouched.
    func seedTranslatedShaderCache(_ entries: [(key: String, result: WPEShaderCompileResult)]) {
        for entry in entries where translatedShaderCache[entry.key] == nil {
            translatedShaderCache[entry.key] = entry.result
        }
    }
    private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]
    var previousFrameHistory: PreviousFrameHistory?
    /// Clip-composite role detection depends on the object's animation layers, so cache the resolved
    /// (source→target) part pairs per `objectID` (empty array = clip puppet with no eligible pair).
    var puppetClipPairsCache: [String: [PuppetClipPair]] = [:]
    /// Throttles the one-shot clip-activation diagnostic to once per objectID.
    var loggedClipActivation: Set<String> = []
    lazy var staticLayerCompositeCache = WPEMetalStaticLayerCompositeCache(
        budgetBytes: WPEMetalRenderExecutor.staticLayerCacheBudgetBytes
    )
    var staticLayerCacheSceneSize: CGSize?
    var loggedStaticLayerCacheHits: Set<String> = []
    /// Throttles the generic4 component-map resolve-failure diagnostic to once per objectID.
    var loggedComponentMapResolveFailures: Set<String> = []
    /// Auxiliary texture slots that failed to resolve, so the fall-back-to-primary
    /// warning is emitted once per pass+slot instead of every frame.
    var loggedUnresolvedTextureSlots: Set<String> = []
    /// Reason per pass whose shader will never translate, so the (multi-second) GLSL→MSL
    /// attempt happens once instead of on every frame that re-encodes the skipped pass.
    var untranslatableShaderReasonByPassID: [String: String] = [:]

    /// Scene-output ring: per-frame outputs are recycled instead of freshly
    /// allocated every `render()` (~32 MB alloc/free per frame at 4K). A slot
    /// is reused only when (a) no async present of it is still in flight and
    /// (b) it is not among the most recently vended outputs (`maxFramesInFlight`,
    /// min 2) — the renderer re-presents the latest output for static scenes,
    /// `previousFrameHistory` may still read the prior one, and under async
    /// submission an in-flight render may still be writing it.
    var outputTexturePool: [MTLTexture] = []
    /// The most recently vended output textures (newest last); retained count is
    /// `max(2, maxFramesInFlight)` — see `noteVendedOutputTexture`.
    var recentOutputTextureIDs: [ObjectIdentifier] = []
    let presentTracker = PresentInFlightTracker()
    let gpuErrorSink = WPEGPUErrorSink()
    let shaderErrorSink = WPEShaderErrorSink()
    /// Max frames whose command buffers may be in flight at once when submitting
    /// asynchronously. MUST equal the `recentOutputTextureIDs` retention: a vended
    /// output target stays out of the reuse set for exactly that many subsequent
    /// vends, and the semaphore guarantees its render has completed by the time it
    /// falls out — so a target is never recycled while its GPU write is in flight.
    /// (See `isOutputTextureReusable` / `noteVendedOutputTexture`.)
    static let maxFramesInFlight = 2
    private let frameSubmissionPool = WPEMetalFrameSubmissionPool(
        slotCount: WPEMetalRenderExecutor.maxFramesInFlight
    )
    /// Backpressure for asynchronous frame submission: gates the render caller
    /// once `maxFramesInFlight` frames are queued so the CPU cannot outrun the GPU
    /// (which would starve the output ring and grow latency unboundedly).
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    /// When true, `render()` and the text passes block on GPU completion
    /// (`waitUntilCompleted`) so a CPU read-back of the frame (scene-debug
    /// first-frame snapshot, visual-stats, GPU capture, test pixel diffs) observes
    /// finished pixels. When false — the production live path — frames submit
    /// asynchronously and the CPU only stalls via `inFlightSemaphore`, letting
    /// frame N+1's setup overlap frame N's GPU work. The live renderer sets this
    /// per scene; defaults to the safe synchronous behavior for any other caller.
    var synchronizeFrameCompletion = true

    func beginFrameSubmission() throws -> WPEMetalFrameSubmissionLease {
        guard let submission = frameSubmissionPool.tryAcquire() else {
            throw WPEMetalFrameInFlightBudgetExhausted()
        }
        return submission
    }
    /// Cleared `.previous` bootstrap textures, one per (target, size, format).
    /// They are only ever read (seeded before the target's first write of the
    /// frame), so the creation-time clear stays valid for the cache lifetime.
    var bootstrapPreviousTextureCache: [BootstrapPreviousKey: MTLTexture] = [:]
    /// Scratch textures (one per size/format) holding a stable snapshot of the
    /// scene for a pass that reads `.previous` while ALSO writing to the scene.
    var sceneReadHazardSnapshotCache: [BootstrapPreviousKey: MTLTexture] = [:]

    struct BootstrapPreviousKey: Hashable {
        let targetID: WPEMetalTargetID
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    /// Present completion handlers run on Metal's callback threads while the
    /// pool is consulted from the render thread, so the in-flight refcounts
    /// live behind a lock in a Sendable box the handler can capture.
    final class PresentInFlightTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [ObjectIdentifier: Int] = [:]

        func increment(_ id: ObjectIdentifier) {
            lock.lock()
            counts[id, default: 0] += 1
            lock.unlock()
        }

        func decrement(_ id: ObjectIdentifier) {
            lock.lock()
            if let count = counts[id], count > 1 {
                counts[id] = count - 1
            } else {
                counts.removeValue(forKey: id)
            }
            lock.unlock()
        }

        func isInFlight(_ id: ObjectIdentifier) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return (counts[id] ?? 0) > 0
        }
    }

    /// Metal resources are thread-safe handles, but `MTLTexture` is not annotated
    /// `Sendable` in the SDK. Present completion runs on Metal callback threads,
    /// so wrap the source texture before capturing it in the `@Sendable` handler.
    struct PresentCompletionTexture: @unchecked Sendable {
        let texture: MTLTexture
    }

    /// Per-puppet skinning decision for the current frame. `enabled` is false (and `palette` empty)
    /// whenever the validation gate rejects skinning, so the pass renders the static assembled mesh.
    struct PuppetSkinningState {
        let enabled: Bool
        let palette: [simd_float4x4]
        let attachmentsByName: [String: WPEPuppetAttachment]
        /// Parent puppet's RAW MDLS bind-world per bone — the basis the palette (`current · rawBind⁻¹`)
        /// was built on, so `palette · (rawBind · MDAT)` recovers the anchor's CURRENT world position.
        let boneBindByIndex: [Int: simd_float4x4]
        /// Parent puppet's ASSEMBLED bind-world per bone: the frame-0 pose for character-sheet puppets
        /// (raw MDLS is the exploded sheet there), the raw bind for pre-assembled. This is the anchor's
        /// REST position — matching the graph builder's static placement — so the follow adds only the
        /// animated `current − rest` delta (zero at rest) instead of double-counting the assembly.
        let assembledBoneBindByIndex: [Int: simd_float4x4]
        let reason: String
    }

    /// Per-frame attachment/skinning context, built once before the layer loop so a parent puppet's
    /// animated bone palette is available before its attached children render.
    struct PuppetAttachmentFrameContext {
        let layersByObjectID: [String: WPEPreparedRenderLayer]
        let skinningByObjectID: [String: PuppetSkinningState]
        let sceneSize: CGSize
    }

    struct PreviousFrameHistory {
        let sceneSize: CGSize
        let sceneTexture: MTLTexture?
        let namedTextures: [String: MTLTexture]
    }

    fileprivate struct TranslatedPipelineKey: Hashable {
        let libraryID: ObjectIdentifier
        let vertexName: String
        let fragmentName: String
        let blendMode: String
        let alphaWritePolicy: WPEMetalAlphaWritePolicy
        let colorPixelFormat: UInt
        let depthPixelFormat: UInt
    }

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        commandQueue = queue
        defaultLibrary = library
        self.targetPool = WPEMetalRenderTargetPool(device: device)
        self.depthCache = WPEMetalDepthStateCache(device: device)
        self.pipelineCache = WPEMetalPipelineCache(device: device, library: library)
        // The Swift transpiler is the only Metal-side translator we ship; shaders
        // it can't handle surface as the scene's metalRendererUnsupported load error.
        self.shaderCompiler = WPESwiftShaderCompiler(device: device)
    }

    /// Lets `WPEMetalSceneRenderer` hand the executor's device
    /// to `WPEVideoTextureSource` (which needs it to build a
    /// `CVMetalTextureCache`) without exposing the device publicly.
    var textureSourceDevice: MTLDevice {
        device
    }

    /// Video NV12→BGRA conversion passes must commit on the frame queue:
    /// same-queue hazard tracking orders them ahead of the frame that samples
    /// the converted working texture (a separate queue would be unordered).
    var textureSourceCommandQueue: MTLCommandQueue {
        commandQueue
    }

    /// One-shot guard so the waterwaves dispatch logs its first live execution per renderer
    /// (confirms the builtin effect_waterwaves path actually runs). Internal —
    /// flipped by the waterwaves `bind` closure in `WPEMetalEffectDispatchTable`.
    var loggedWaterWavesDispatch = false
    /// Scene size (ortho-projection pixels) for the frame currently encoding.
    /// Stashed at frame start so `usesObjectQuadGeometry` can judge a
    /// scene-capture utility layer's footprint without threading `sceneSize`
    /// through its dozen call sites. Safe because the render loop encodes one
    /// frame at a time.
    private(set) var currentSceneSize: CGSize = .zero

    /// Render-scale decision for this scene, handed down by the renderer at load
    /// (`WPEMetalUpscalePlan`) BEFORE any target or source texture is sized.
    /// `.inactive` until then, so an executor that is never planned renders at
    /// full resolution — the pre-feature path, bit for bit.
    var upscalePlan: WPEMetalUpscalePlan = .inactive
    /// Drawable size the last presented frame actually used. `nextDrawable()` is
    /// what finally sizes the layer, so this is the first moment the true size
    /// is knowable — the renderer adopts it to correct a bad seed.
    var lastPresentedDrawableSize: CGSize = .zero
    /// The scene output's actual pixel size for the frame currently encoding
    /// (= `scaledCanvasSize(currentSceneSize, outputPixelScale)`). This is the
    /// resolution of the FBO chain's head, which `g_TexelSize` must describe —
    /// WPE feeds 1/head-resolution to every pass of a blur chain so the kernel
    /// keeps a fixed SCREEN-space width (see `texelSizeValue`).
    private(set) var currentScenePixelSize: CGSize = .zero

    // Object IDs that are parents of at least one other layer. A `composelayer`
    // that hosts children is a WPE "layer group" (transform/opacity container),
    // NOT a scene-capture effect box — its children render as flat layers, so its
    // own sub-rect scene passthrough must be suppressed (else it paints a
    // picture-in-picture scene-copy; scene 3632513108's bottom-right control panel).
    private var groupingContainerObjectIDs: Set<String> = []
    /// Scene-centred origin of each parented layer's parallax ROOT, keyed by object id.
    /// WPE shifts a parented subtree by ONE offset — the root's — so a child must
    /// evaluate the static `(nodePos - camPos)` term at its root's origin, never at
    /// its own. Recomputed per render from the prepared pipeline; roots are absent
    /// and keep their own centre. See `parallaxRootCenters`.
    var parallaxRootCenterByObjectID: [String: SIMD2<Float>] = [:]
    /// Load-time object hierarchy for the root walk above: the full parent map
    /// (groups included) and the authored origins of ALL objects, the fallback
    /// anchor when a subtree's root never became a live layer (group hosts,
    /// filtered-out ancestors). Set by the renderer at load.
    var parallaxObjectParentByID: [String: String] = [:]
    var parallaxHostDepthByObjectID: [String: SIMD2<Double>] = [:]
    var parallaxHostOriginByObjectID: [String: SIMD2<Double>] = [:]
    /// Logical targets rendered by >1 depth-using pass: their depth may be loaded
    /// across encoders (e.g. a `depthTest:less` pass reading a prior pass's depth),
    /// so they keep persistent depth rather than transient/memoryless. Recomputed
    /// per render from the prepared pipeline.
    private var persistentDepthTargetIDs: Set<WPEMetalTargetID> = []

    #if DEBUG
    /// Diagnostic: when `WPEDumpScenePasses` (UserDefault) equals the sceneID,
    /// holds one snapshot of the scene output after EACH scene-target pass so
    /// `WPEMetalSceneRenderer` can PNG-dump them and localize which pass draws
    /// a given artifact. Memory-bounded — cleared at the start of every render().
    private(set) var scenePassDumps: [(label: String, texture: MTLTexture)] = []
    /// Diagnostic: when `WPEDumpLayerPasses` (UserDefault) equals a layer
    /// objectID, snapshot that ONE layer's destination texture after EVERY
    /// pass (base image + each effect FBO), so we can localize which pass on a
    /// single puppet/layer introduces an artifact. Scoped to one object to
    /// stay memory-safe (capturing every pass scene-wide would OOM the GPU).
    private var dumpLayerPassesID: String?
    /// Both dump defaults read once at executor init instead of twice per frame.
    /// Safe for the oracle gate: OracleCorpusCaptureTests.swift sets
    /// `WPEDumpScenePasses` per scene BEFORE constructing WPEMetalSceneRenderer
    /// (which builds this executor in its init), so an init-time read observes it.
    private let dumpScenePassesDefaultID: String? =
        UserDefaults.standard.string(forKey: "WPEDumpScenePasses")
    private let dumpLayerPassesDefaultID: String? = {
        let id = UserDefaults.standard.string(forKey: "WPEDumpLayerPasses")
        return (id?.isEmpty == false) ? id : nil
    }()
    #endif

    func render(
        pipeline: WPEPreparedRenderPipeline,
        size: CGSize,
        textures: [String: MTLTexture],
        dynamicTextureNames: Set<String> = [],
        dynamicLayerIDs: Set<String> = [],
        runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        /// This frame's scripted shader constants, keyed by pass id. Merged over
        /// the authored values; empty for every scene without a bound script.
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [:],
        /// This frame's resolved effect-visibility gates, keyed by
        /// `WPEPassVisibilityGate.id`. A missing entry falls back to the gate's
        /// authored seed; empty for every scene without a script-gated effect.
        passVisibility: [String: Bool] = [:],
        sceneID: String? = nil,
        particleSystems: [WPEParticleSystem] = [],
        particleTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleParallax: WPECameraParallaxFrame = .neutral,
        textPayloads: [String: WPETextRenderPayload] = [:],
        frameSubmission: WPEMetalFrameSubmissionLease? = nil,
        frameProduction: WPEMetalFrameProductionCompletion? = nil,
        /// Wallpaper Engine's per-wallpaper colour grade, from the applied preset.
        /// Defaulted so the many call sites that never carry one stay unchanged.
        colorCorrection: WPEEngineColorCorrection = .neutral,
        /// Encode present into this scene command buffer. Nil on sync/readback.
        deferredPresent: DeferredPresentEncoder? = nil
    ) throws -> MTLTexture {
        // Async submission: take a permit up front so the CPU blocks here (rather
        // than queuing another frame) once `maxFramesInFlight` are outstanding.
        // The matching signal is emitted from the command buffer's completion
        // handler on success; the `defer` releases it on any early throw so a
        // permit is never lost.
        let asyncSubmission = !synchronizeFrameCompletion
        // A renderer-owned frame lease already accounts for every command buffer
        // in this logical frame. Retain the historical semaphore only for callers
        // that have not migrated to that lease; applying both budgets can reject
        // a legitimate second buffer in the same fail-close frame.
        let usesLegacyCommandBufferBudget = asyncSubmission && frameSubmission == nil
        if usesLegacyCommandBufferBudget {
            // Poll, don't block: a blocking wait here holds the @MainActor
            // (this runs from MTKView.draw, shared across every display) and would
            // stall other displays' draw callbacks, dropping dual-60fps to 30fps.
            // Thrown before the `defer` below is armed, so no stray signal.
            if inFlightSemaphore.wait(timeout: .now()) == .timedOut {
                throw WPEMetalFrameInFlightBudgetExhausted()
            }
        }
        var didCommitAsync = false
        defer {
            if usesLegacyCommandBufferBudget && !didCommitAsync {
                inFlightSemaphore.signal()
            }
        }
        #if DEBUG
        scenePassDumps.removeAll()
        // Collect per-pass scene-target snapshots when the workshopID-scoped dump
        // flag matches OR the render oracle is on (which hashes every pass into the
        // trace). Oracle collection forces particles standalone (below) — a render-
        // encoder boundary change only, byte-identical composite, consistent across
        // both before/after oracle runs.
        let dumpScenePasses = (sceneID.map { !$0.isEmpty && dumpScenePassesDefaultID == $0 } ?? false)
            || WPEOracleMode.perPassHashesEnabled
        dumpLayerPassesID = dumpLayerPassesDefaultID
        #endif
        let (preparedPipeline, frameUniforms) = pipeline.addingMetalRuntimeUniforms(
            runtimeUniforms,
            camera: cameraUniforms,
            scriptedConstants: scriptedConstants
        )
        frameUniformContext = frameUniforms
        defer { frameUniformContext = .empty }
        currentOutputPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : Self.outputPixelFormat
        targetPool.promotesLDRFormatsToHDR = cameraUniforms.sceneHDR
        // ONE pixel scale for the whole frame: scene output, every pool target
        // and the alias plan must shrink together or `copyTexture` blits
        // mismatched extents. `size` stays WORLD-sized everywhere below —
        // projection, quad NDC, particles, scripts and text all keep the
        // authored canvas; only allocations and g_TexelSize go through the
        // scaled-canvas conversion.
        let outputPixelScale = upscalePlan.renderPixelScale
        targetPool.pixelScale = outputPixelScale
        let outputPixelSize = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            size, pixelScale: outputPixelScale
        )
        currentScenePixelSize = outputPixelSize
        let output = try makeOutputTexture(size: outputPixelSize)
        let staticLayerCacheEnabled = Self.isStaticLayerCacheEnabled
        staticLayerCompositeCache.updateBudget(Self.staticLayerCacheBudgetBytes)
        if staticLayerCacheEnabled {
            if staticLayerCacheSceneSize != size {
                invalidateStaticLayerCache()
                staticLayerCacheSceneSize = size
            }
        } else if staticLayerCacheSceneSize != nil {
            invalidateStaticLayerCache()
        }
        gpuPassProfiler?.noteScene(sceneID)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        let reusableHistory: PreviousFrameHistory?
        if let history = previousFrameHistory, history.sceneSize == size {
            reusableHistory = history
        } else {
            reusableHistory = nil
            previousFrameHistory = nil
        }

        // Aliasing is disabled while the debug bypass path is active — bypass
        // skips a layer's passes, which would break the lockstep pass index the
        // alias plan relies on.
        let aliasIntervals = fboAliasIntervals(pipeline: preparedPipeline, sceneSize: size)
        targetPool.prepare(pipeline: preparedPipeline, aliasIntervals: aliasIntervals)
        targetPool.beginAliasFrame()
        // The per-frame output texture is freshly allocated (`.private`); its
        // backing store is NOT zeroed by Metal. A scene-alias read of
        // `_rt_FullFrameBuffer` before any scene-target pass writes (e.g.
        // shine_combine's COPYBG, which samples the full-frame buffer while
        // still rendering into a layer composite) would otherwise sample this
        // garbage and, with shine's `albedo.a = saturate(albedo.a + rays.a)`
        // accumulation, ramp the whole layer to white within a few seconds.
        // Clear to the scene clear color so any pre-write alias read sees black.
        try clearTexture(output, color: clearColor(for: .scene), commandBuffer: commandBuffer)
        var frameState = WPEMetalFrameState(
            output: output,
            sceneSize: size,
            cameraUniforms: cameraUniforms,
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:],
            // Threaded so `resolve(.fbo)` can zero-fill a declared-but-unwritten
            // local FBO on its first read instead of failing the scene at load.
            renderTargetPool: targetPool
        )
        frameState.cameraParallax = runtimeUniforms.cameraParallax
        currentSceneSize = size
        groupingContainerObjectIDs = Set(preparedPipeline.layers.compactMap { $0.graphLayer.parentObjectID })
        parallaxRootCenterByObjectID = Self.parallaxRootCenters(
            for: preparedPipeline.layers.map(\.graphLayer),
            sceneSize: size,
            objectParentByID: parallaxObjectParentByID,
            hostDepthByObjectID: parallaxHostDepthByObjectID,
            hostOriginByObjectID: parallaxHostOriginByObjectID
        )
        persistentDepthTargetIDs = computePersistentDepthTargetIDs(for: preparedPipeline)
        var didEncode = false
        var skippedShaderError: WPEMetalRenderExecutorError?
        let attachmentContext = makeAttachmentFrameContext(
            for: preparedPipeline,
            runtimeUniforms: runtimeUniforms,
            sceneSize: size
        )

        // Particles composite at their scene paint index, interleaved between
        // layers: a particle with sortIndex P draws after every layer with a
        // lower sortIndex and before any higher one (background → rain → character).
        let sortedParticles = particleSystems.enumerated()
            .filter { $0.element.liveInstanceCount > 0 }
            .sorted { lhs, rhs in
                lhs.element.sortIndex != rhs.element.sortIndex
                    ? lhs.element.sortIndex < rhs.element.sortIndex
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        var particleCursor = 0
        // Batch consecutive non-refract systems (same `output`, no intervening
        // scene pass) into ONE render encoder, instead of a render pass + full-target
        // load/store per system. Refract systems need a pre-draw blit snapshot (no
        // open render encoder allowed) and DEBUG per-pass dumping needs a boundary
        // per system → both end the run and render standalone. A run never spans
        // `flushParticles` calls (a layer pass renders between them), so it is closed
        // before returning.
        func flushParticles(before threshold: Int) throws {
            var particleRunEncoder: MTLRenderCommandEncoder?
            func endParticleRun() {
                guard let encoder = particleRunEncoder else { return }
                encoder.endEncoding()
                particleRunEncoder = nil
                frameState.registerWrite(texture: output, targetID: .scene)
            }
            // Close the run on EVERY exit — a thrown `particlePipelineState`/encoder
            // failure mid-run must not leak an open encoder (Metal validation asserts).
            defer { endParticleRun() }
            while particleCursor < sortedParticles.count,
                  sortedParticles[particleCursor].sortIndex < threshold {
                let system = sortedParticles[particleCursor]
                let traceIndex = particleCursor
                particleCursor += 1

                let isRefractSystem = !system.usesRibbonGeometry
                    && particleNormalTextures[ObjectIdentifier(system)] != nil
                #if DEBUG
                let standalone = isRefractSystem || dumpScenePasses
                #else
                let standalone = isRefractSystem
                #endif

                if standalone {
                    endParticleRun()
                    if try encodeParticleSystem(
                        system,
                        into: commandBuffer,
                        output: output,
                        sceneSize: size,
                        cameraParallax: particleParallax,
                        texturesByMaterial: particleTextures,
                        normalsByMaterial: particleNormalTextures,
                        frameState: &frameState,
                        traceIndex: traceIndex
                    ) {
                        didEncode = true
                        #if DEBUG
                        // Label MUST equal the trace passId `recordParticlePass`
                        // emits (`particle.<traceIndex>`) so `recordPassOutputs`
                        // matches by id and the flushed snapshot's hash lands on
                        // this pass; the old `.<sortIndex>.` form never matched.
                        captureScenePassIfDumping(dumpScenePasses, label: "particle.\(traceIndex)", output: output, commandBuffer: commandBuffer)
                        #endif
                    }
                    continue
                }

                let encoder = try particleRunEncoder
                    ?? makeParticleOutputEncoder(output: output, commandBuffer: commandBuffer)
                particleRunEncoder = encoder
                if try encodeParticleSystem(
                    system,
                    into: commandBuffer,
                    output: output,
                    sceneSize: size,
                    cameraParallax: particleParallax,
                    texturesByMaterial: particleTextures,
                    normalsByMaterial: particleNormalTextures,
                    frameState: &frameState,
                    traceIndex: traceIndex,
                    sharedEncoder: encoder
                ) {
                    didEncode = true
                }
            }
        }

        // Flattened pass index for FBO aliasing — MUST advance in lockstep with
        // the same `for layer { for pass in layer.passes }` order the alias plan
        // used, across every branch below, or makeAliasable could fire early.
        var aliasPassCounter = 0
        for layer in preparedPipeline.layers {
            try flushParticles(before: layer.graphLayer.sortIndex)
            // Static-layer cache: a provably-static layer's composites are
            // rendered once and reused. On a hit we seed frameState with every
            // cached composite so the layer's `.scene` copy (and any downstream
            // consumer) resolves them, then skip its compose/effect passes.
            let staticCachePlan = staticLayerCacheEnabled
                ? WPEMetalStaticLayerClassifier.cachePlan(
                    for: layer,
                    dynamicTextureNames: dynamicTextureNames,
                    dynamicLayerIDs: dynamicLayerIDs
                )
                : nil
            let cachedStaticLayer = staticCachePlan.flatMap { plan in
                staticLayerCompositeCache.cachedLayer(
                    for: layer.graphLayer.objectID,
                    requiredTargets: Set(plan.cachedTargets.keys)
                )
            }
            if let cachedStaticLayer {
                for (name, texture) in cachedStaticLayer.texturesByTarget {
                    frameState.seedPreviousTexture(texture, targetID: .named(name))
                    frameState.markInitialized(texture)
                }
                if loggedStaticLayerCacheHits.insert(layer.graphLayer.objectID).inserted {
                    Logger.info(
                        "[WPE.static-layer-cache] skip composite layer=\(layer.graphLayer.objectID) targets=\(cachedStaticLayer.texturesByTarget.count) bytes=\(cachedStaticLayer.bytes)",
                        category: .wpeRender
                    )
                }
            }
            // Accumulates first-frame snapshots for a cache miss until all of the
            // plan's targets are captured, then inserts them as one layer entry.
            var pendingStaticSnapshots: [String: MTLTexture] = [:]
            var pendingStaticBytes = 0
            // Attached children (face/hair on a body-split rig) follow the parent puppet's animated
            // anchor bone; `graphLayer` carries the followed transform, falling back to the static
            // layer when there is no resolved attachment. Skinning is validated/cached once per frame.
            let graphLayer = layerApplyingAttachmentFollow(layer.graphLayer, context: attachmentContext)
            let skinningState = attachmentContext.skinningByObjectID[layer.graphLayer.objectID]
            if layer.passes.isEmpty {
                // Hidden plain-image layer: nothing composites elsewhere, so
                // simply skip the scene blit. `didEncode` stays satisfied so an
                // all-hidden scene renders empty instead of erroring.
                guard layer.graphLayer.visible else {
                    didEncode = true
                    continue
                }
                try encodeCopy(
                    reference: .image(layer.graphLayer.imagePath),
                    target: .scene,
                    layer: graphLayer,
                    textures: textures,
                    commandBuffer: commandBuffer,
                    frameState: &frameState
                )
                didEncode = true
                #if DEBUG
                captureScenePassIfDumping(dumpScenePasses, label: "\(layer.graphLayer.objectID).image", output: output, commandBuffer: commandBuffer)
                #endif
                continue
            }
            for (layerPassIndex, pass) in layer.passes.enumerated() {
                // Advance the alias index for EVERY pass (defer fires endPass at
                // iteration exit, including the hidden-pass `continue` below), so
                // makeAliasable only happens AFTER this pass is encoded. The
                // static-layer skip below keeps this lockstep: it `continue`s
                // AFTER the index advances + defer is armed.
                let passAliasIndex = aliasPassCounter
                aliasPassCounter += 1
                defer { targetPool.endPass(passIndex: passAliasIndex) }
                // Hidden layer: still encode passes that write a composite/FBO
                // (dependents may sample them), but skip the final scene draw so
                // the layer is invisible. Toggling `visible` true re-includes it
                // without a pipeline rebuild. A pass targeting the shared group
                // buffer (`_rt_layerGroup_*`) is a group child's VISIBLE output —
                // the group-child analogue of the scene draw — so skip it too;
                // otherwise a condition-hidden variant kept in the graph for live
                // script toggling paints into the group buffer and overlaps the
                // selected variant (scene 3226487183's mutually-exclusive poses).
                if !graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        didEncode = true
                        continue
                    case .fbo(let name) where WPERenderTargetNames.LayerGroup.matches(name):
                        didEncode = true
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                // Script-gated effect (authored hidden, visibility bound to a
                // SceneScript). Its passes are baked into the graph so their own
                // constant scripts keep ticking — that is where the value the gate
                // reads is produced — but while the gate is closed the effect must
                // not alter a pixel, so the pass hands its input straight to its
                // target instead of drawing.
                if let gate = pass.pass.visibilityGate,
                   !(passVisibility[gate.id] ?? gate.initialVisible) {
                    try encodeGatedPassthrough(
                        pass: pass,
                        layer: graphLayer,
                        textures: textures,
                        commandBuffer: commandBuffer,
                        frameState: &frameState
                    )
                    didEncode = true
                    continue
                }
                // Cache hit: composites are already in `frameState` (seeded above),
                // so skip the compose/effect passes and run only the `.scene` copy
                // (which applies parallax from the cached texture).
                if cachedStaticLayer != nil {
                    switch pass.pass.target {
                    case .scene:
                        break
                    case .layerComposite, .fbo:
                        didEncode = true
                        continue
                    }
                }
                do {
                    try encode(
                        pass: pass,
                        layer: graphLayer,
                        puppetModel: layer.puppetModel,
                        skinningState: skinningState,
                        runtimeUniforms: runtimeUniforms,
                        textures: textures,
                        textPayload: textPayloads[graphLayer.objectID],
                        commandBuffer: commandBuffer,
                        frameState: &frameState
                    )
                } catch let error as WPEMetalRenderExecutorError where error.untranslatableShaderReason != nil {
                    // The pass still opened (and therefore cleared) its render target before the
                    // shader failed, so a downstream pass sampling it reads transparent black
                    // rather than whatever the pooled/aliased texture last held.
                    untranslatableShaderReasonByPassID[pass.id] = error.untranslatableShaderReason
                    skippedShaderError = skippedShaderError ?? error
                    continue
                }
                didEncode = true
                // First-time miss: snapshot each composite into a persistent
                // texture right after its last producer pass; once every planned
                // target is captured, commit them to the cache as one layer entry.
                if let staticCachePlan, cachedStaticLayer == nil {
                    captureStaticLayerSnapshots(
                        at: layerPassIndex,
                        plan: staticCachePlan,
                        layer: graphLayer,
                        commandBuffer: commandBuffer,
                        frameState: &frameState,
                        snapshots: &pendingStaticSnapshots,
                        bytes: &pendingStaticBytes
                    )
                }
                #if DEBUG
                if dumpScenePasses {
                    // Dump BOTH the scene target and each layer's intermediate composite target, so a
                    // per-layer effect chain (e.g. 840's face → opacity/waterripple/…) can be inspected
                    // pass-by-pass to see exactly which pass drops/moves content.
                    let dumpTarget: MTLTexture?
                    switch pass.pass.target {
                    case .scene:
                        dumpTarget = output
                    case .layerComposite(let name), .fbo(let name):
                        // Use the texture the pass ACTUALLY wrote to (FBO pooling/aliasing means
                        // re-resolving the name by `targetTexture` can vend a different/cleared one).
                        dumpTarget = frameState.latestNamedTextures[name]
                    }
                    if let dumpTarget {
                        captureScenePassIfDumping(dumpScenePasses, label: pass.pass.id, output: dumpTarget, commandBuffer: commandBuffer)
                    }
                }
                #endif
            }
        }

        try flushParticles(before: Int.max)

        guard didEncode else {
            throw skippedShaderError ?? WPEMetalRenderExecutorError.noRenderablePasses
        }

        try encodeSceneBloomIfNeeded(
            cameraUniforms: cameraUniforms,
            output: output,
            commandBuffer: commandBuffer
        )
        // Last, so it grades the finished frame — bloom included — the way
        // Wallpaper Engine's own correction sits after the scene, not inside it.
        let graded = try encodeColorCorrectionIfNeeded(
            colorCorrection, output: output, commandBuffer: commandBuffer
        )

        // Late drawable acquire: a throw here drops the un-committed buffer
        // before any completed handler / lease is attached.
        if asyncSubmission, let deferredPresent {
            _ = try deferredPresent(graded, commandBuffer)
        }

        recyclePaletteBuffersOnCompletion(of: commandBuffer)
        if WPEFrameGPUTimingProbe.isEnabled {
            commandBuffer.addCompletedHandler { cb in
                WPEFrameGPUTimingProbe.recordScene(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime)
            }
        }
        let frameSubmissionCompletion = frameSubmission?.registerSubmission()
        if let frameSubmissionCompletion {
            commandBuffer.addCompletedHandler { _ in
                frameSubmissionCompletion.complete()
            }
        }
        let frameProductionSubmission = frameProduction?.registerSubmission()
        if let frameProductionSubmission {
            commandBuffer.addCompletedHandler { completed in
                frameProductionSubmission.complete(succeeded: completed.status == .completed)
            }
        }
        if asyncSubmission {
            // Bound in-flight depth (signal mirrors the wait above) and surface
            // GPU errors from the handler — they land after we've returned, so we
            // log rather than throw; the wallpaper just renders the next frame.
            // GPU-side ordering on the shared queue still guarantees the text and
            // present buffers (committed later) observe this frame's writes.
            let semaphore = usesLegacyCommandBufferBudget ? inFlightSemaphore : nil
            let sink = gpuErrorSink
            commandBuffer.addCompletedHandler { cb in
                semaphore?.signal()
                // Logged in every build (the old synchronous path threw on error,
                // which the caller logged) so a GPU failure isn't silent in release.
                if cb.status == .error {
                    let detail = cb.error?.localizedDescription ?? "unknown"
                    sink.record("async-frame: \(detail)")
                    Logger.warning(
                        "[WPE async-frame] command buffer error: \(detail)",
                        category: .wpeRender
                    )
                }
            }
            commandBuffer.commit()
            didCommitAsync = true
        } else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status == .error {
                gpuErrorSink.record("frame: \(commandBuffer.error?.localizedDescription ?? "unknown")")
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
        }
        previousFrameHistory = PreviousFrameHistory(
            sceneSize: size,
            sceneTexture: frameState.latestSceneTexture,
            // Never carry named FBOs across frames: they are per-frame scratch
            // (`_rt_HalfCompoBuffer*` shine cast/gaussian) or same-frame ping-pong
            // composites (`_rt_imageLayerComposite_*`), so carrying them let the
            // shine chain re-blend its own output and, via
            // `saturate(albedo.a + rays.a)`, ramp the layer white in ~5s (3526278753).
            // Cross-frame scene feedback still works through `sceneTexture` above.
            // A precise "carry only `.previous`-read targets" filter was tried and
            // REGRESSED: effect-bind `{name:"previous"}` lowers to the SAME
            // `.previous` token as true cross-frame feedback, so it mis-carried the
            // shine composite and the white-out returned.
            namedTextures: [:]
        )
        return graded
    }

    /// Slots this layout occupies, matching the per-shader `WPEUniforms.vals[]` the transpiler emits.
    /// Slots are assigned sequentially, so the max `slot + slotCount` is the total.
    static func translatedSlotCount(for layout: [WPEUniformSlot]) -> Int {
        max(layout.reduce(0) { Swift.max($0, $1.slot + $1.slotCount) }, 1)
    }

    /// macOS caps `setFragmentBytes` at 4 KB (256 × 16-byte slots). Shaders under that ride the inline
    /// fast path; audio visualizers above it (e.g. a 258-slot oscilloscope) bind a transient shared
    /// buffer instead. The buffer is retained by the command buffer until GPU completion.
    func bindTranslatedUniformSlots(_ slots: [SIMD4<Float>], to encoder: MTLRenderCommandEncoder, index: Int = 0) {
        guard !slots.isEmpty else { return }
        let byteCount = MemoryLayout<SIMD4<Float>>.stride * slots.count
        if byteCount <= 4096 {
            var inline = slots
            encoder.setFragmentBytes(&inline, length: byteCount, index: index)
        } else if let buffer = slots.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: byteCount, options: .storageModeShared)
        }) {
            encoder.setFragmentBuffer(buffer, offset: 0, index: index)
        }
    }

    /// Packs a `[name: value]` uniform dictionary into the translated shader's
    /// `WPEUniforms.vals[]` array by the slot indices from its uniform layout.
    /// Mirrors the per-pass packer but takes a standalone values dict for
    /// callers that build uniforms outside the render graph.
    func packTranslatedUniforms(
        values: [String: WPESceneShaderConstantValue],
        layout: [WPEUniformSlot],
        texturesBySlot: WPEMetalTextureSlotTable? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.translatedSlotCount(for: layout))
        for u in layout {
            guard u.slot < slots.count else { continue }
            let value = Self.textureResolutionValue(
                named: u.name,
                texturesBySlot: texturesBySlot
            ) ?? Self.firstValue(
                in: values,
                matching: Self.translatedUniformNameCandidates(for: u)
            ) ?? u.defaultValue
            if let length = u.arrayLength {
                Self.packArrayUniform(value, glslType: u.glslType, length: length, slot: u.slot, into: &slots)
                continue
            }
            switch u.glslType {
            case "vec2", "ivec2", "bvec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3", "ivec3", "bvec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4", "ivec4", "bvec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    var textGlyphPipelineCache: [UInt: MTLRenderPipelineState] = [:]
    var textBackgroundPipelineCache: [UInt: MTLRenderPipelineState] = [:]

    var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]
    /// Reused scene snapshot storage for REFRACT particle passes; reallocated when
    /// the output size/format changes. A frame-local freshness guard decides
    /// whether the contents can be reused without another full-frame blit.
    var refractionBackground: MTLTexture?

    /// Whether a pass should `.load` the existing attachment contents instead of
    /// `.clear`ing. A ping-pong composite's physical texture is reused across
    /// passes, so a later source-over pass writing the SAME named target would
    /// otherwise blend over an earlier logical pass's stale result (the
    /// hair/staff "double displacement" ghost). Only load when the contents are
    /// genuinely needed: a self/previous-target read (feedback), the scene
    /// framebuffer (layer compositing), or an accumulation blend.
    private func shouldLoadExistingAttachment(
        for pass: WPEPreparedRenderPass,
        targetID: WPEMetalTargetID,
        destinationTexture: MTLTexture,
        readsCurrentTarget: Bool,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard frameState.hasInitialized(destinationTexture) else {
            return false
        }
        if readsCurrentTarget {
            return true
        }
        if case .scene = targetID {
            return true
        }
        if case .named(let name) = targetID,
           WPERenderTargetNames.LayerGroup.matches(name) {
            return true
        }
        return blendFacts(pass.pass.blending).requiresExistingDestination
    }

    static func blendModeRequiresExistingDestination(_ blendMode: String) -> Bool {
        let normalized = blendMode
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "add",
             "additive",
             "premultipliedadditive",
             "premultipliedmultiply",
             "premultipliedscreen",
             "darken",
             "lighten",
             "multiply",
             "negative",
             "oneone",
             "oneoneone",
             "screen",
             "subtract",
             "subtractive":
            return true
        default:
            return false
        }
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        textures: [String: MTLTexture],
        textPayload: WPETextRenderPayload?,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: pass.pass.target)
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = passReadsCurrentTarget(pass, targetID: targetID)
        let aliasAvoidanceTexture: MTLTexture?
        if readsCurrentTarget {
            aliasAvoidanceTexture = initialPreviousTextureForTarget
                ?? (Self.requiresDiscreteDestinationForSourceAliasing(pass) ? frameState.output : nil)
        } else if Self.requiresDiscreteDestinationForSourceAliasing(pass) {
            aliasAvoidanceTexture = frameState.output
        } else {
            aliasAvoidanceTexture = nil
        }
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: aliasAvoidanceTexture
        )
        let drawLayer = layerForDrawing(pass: pass.pass, layer: layer)

        if WPETextLayerSynthesis.isGlyphPassShader(pass.pass.shader) {
            var copiedSceneBackground = false
            if textPayload?.mode == .offscreen,
               textPayload?.copiesSceneBackground == true,
               textPayload?.backgroundColor == nil,
               case .named = targetID {
                let backgroundUniforms = objectQuadUniforms(
                    for: drawLayer,
                    sceneSize: frameState.sceneSize,
                    cameraParallax: runtimeUniforms.cameraParallax,
                    sourceTexture: destination.texture,
                    cameraUniforms: frameState.cameraUniforms
                )
                try encodeTextBackground(
                    source: frameState.output,
                    uniforms: backgroundUniforms,
                    output: destination.texture,
                    commandBuffer: commandBuffer
                )
                copiedSceneBackground = true
            }
            let clearsDestination: Bool
            switch (textPayload?.mode, targetID) {
            case (.direct, .scene):
                clearsDestination = false
            case (.direct, .named):
                clearsDestination = !frameState.hasInitialized(destination.texture)
            case (.offscreen, _):
                clearsDestination = !copiedSceneBackground
            case (nil, _):
                clearsDestination = false
            }
            // WORLD canvas for glyph-vertex normalization (the vertices are
            // world-pixel coordinates): under render scaling the destination
            // texture is `pixelScale` smaller than the canvas, and normalizing
            // by its dimensions would blow the text up by 1/pixelScale.
            let textCanvasSize: CGSize
            if case .scene = pass.pass.target {
                textCanvasSize = frameState.sceneSize
            } else {
                textCanvasSize = targetPool.worldCanvasSize(
                    for: pass.pass.target,
                    layer: layer,
                    sceneSize: frameState.sceneSize
                )
            }
            let encoded = try encodeTextMesh(
                payload: textPayload,
                sceneSize: textCanvasSize,
                output: destination.texture,
                clearsOutput: clearsDestination,
                commandBuffer: commandBuffer
            )
            if encoded || copiedSceneBackground {
                frameState.markInitialized(destination.texture)
                frameState.registerWrite(texture: destination.texture, targetID: targetID)
            }
            return
        }

        #if DEBUG
        // Per-pass FBO isolation for one layer: snapshot this pass's destination
        // after the draw (function-scope defer runs at encode() exit) so we can
        // see exactly which pass on the layer introduces an artifact.
        let shouldDumpLayerPass = dumpLayerPassesID != nil && layer.objectID == dumpLayerPassesID
        defer {
            if shouldDumpLayerPass {
                captureScenePassIfDumping(
                    true,
                    label: "L\(layer.objectID)-\(pass.pass.id)",
                    output: destination.texture,
                    commandBuffer: commandBuffer
                )
            }
        }
        #endif

        try snapshotFullFrameBufferIfAliasingScene(
            pass: pass,
            destinationTexture: destination.texture,
            layer: layer,
            commandBuffer: commandBuffer,
            frameState: &frameState
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

        // A pass that reads `.previous` while ALSO targeting the scene would bind
        // `.previous` to `latestSceneTexture` — the SAME live `output` texture it
        // is drawing into (`targetTexture(.scene)` always returns `output`). That
        // read-write feedback is undefined on the GPU: scene 3470764447's rotated
        // `compose source=previous target=scene` card sampled the pixels it was
        // writing, recursing the whole frame into itself and flickering. `.previous`
        // does NOT traverse `snapshotFullFrameBufferIfAliasingScene` (that only
        // covers `_rt_FullFrameBuffer`-style aliases), so snapshot the scene-so-far
        // into a stable scratch here and rebind `.previous` to it. The write still
        // targets `output`; the read is now a frozen frame-before-this-pass image.
        if readsCurrentTarget, case .scene = targetID,
           let prev = previousTextureForTarget,
           ObjectIdentifier(prev) == ObjectIdentifier(destination.texture) {
            let snapshot = try sceneReadHazardSnapshot(
                matching: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(snapshot)
            frameState.seedPreviousTexture(snapshot, targetID: .scene)
        }

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let needsDepth = depthCache.needsAttachment(for: pass)

        let shouldLoadExistingAttachment = shouldLoadExistingAttachment(
            for: pass,
            targetID: targetID,
            destinationTexture: destination.texture,
            readsCurrentTarget: readsCurrentTarget,
            frameState: frameState
        )

        if try encodePuppetClipCompositePassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            destination: destination,
            shouldLoadDestination: shouldLoadExistingAttachment,
            textures: textures,
            commandBuffer: commandBuffer,
            frameState: &frameState
        ) {
            frameState.registerWrite(texture: destination.texture, targetID: destination.id)
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = shouldLoadExistingAttachment ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: targetID)

        if needsDepth {
            let depth = try depthCache.attachmentTexture(
                for: destination,
                frameState: &frameState,
                allowTransient: !persistentDepthTargetIDs.contains(targetID)
            )
            descriptor.depthAttachment.texture = depth
            if depthCache.isTransientDepthAttachment(depth) {
                // Memoryless depth cannot load/store; it's per-pass transient regardless.
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .dontCare
            } else {
                // Depth is keyed independently of the color target (WPEMetalDepthTextureKey)
                // and allocated fresh on first use per frame, so the color's
                // `shouldLoadExistingAttachment` must NOT decide it: a bootstrapped
                // (copy + markInitialized) color paired with a virgin depth texture would
                // otherwise `.load` undefined GPU memory. `.load` only once this exact depth
                // texture has been written earlier this frame.
                let depthInitialized = frameState.hasInitialized(depth)
                descriptor.depthAttachment.loadAction = depthInitialized ? .load : .clear
                descriptor.depthAttachment.storeAction = .store
                frameState.markInitialized(depth)
            }
            descriptor.depthAttachment.clearDepth = WPEMetalDepthStateCache.clearDepth(
                reversedZ: frameState.cameraUniforms.usesPerspectiveProjection
            )
        }

        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "\(pass.pass.id)|\(pass.pass.shader)")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(
            depthTest: pass.pass.depthTest,
            depthWrite: pass.pass.depthWrite,
            reversedZ: frameState.cameraUniforms.usesPerspectiveProjection
        ))
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.appendLog(
                "[renderPassState] pass=\(pass.pass.id) layer=\(layer.objectName) shader=\(pass.pass.shader) "
                    + "target=\(pass.pass.target) blend=\(pass.pass.blending) "
                    + "depthTest=\(pass.pass.depthTest) depthWrite=\(pass.pass.depthWrite) "
                    + "needsDepth=\(needsDepth) cull=\(pass.pass.cullMode)",
                level: .notice
            )
        }

        let drewSceneModel = try encodeSceneModelMaterialPassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
            destination: destination,
            textures: textures,
            frameState: frameState,
            encoder: encoder,
            depthPixelFormat: needsDepth ? .depth32Float : .invalid
        )
        let drewPuppetMaterial: Bool
        if drewSceneModel {
            drewPuppetMaterial = false
        } else {
            drewPuppetMaterial = try encodePuppetMaterialPassIfNeeded(
            pass: pass,
            layer: drawLayer,
            puppetModel: puppetModel,
            skinningState: skinningState,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )
        }
        let drewPuppetSceneComposite: Bool
        if drewSceneModel || drewPuppetMaterial {
            drewPuppetSceneComposite = false
        } else {
            drewPuppetSceneComposite = try encodePuppetSceneCompositePassIfNeeded(
                pass: pass,
                layer: drawLayer,
                puppetModel: puppetModel,
                skinningState: skinningState,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )
        }
        if !drewSceneModel && !drewPuppetMaterial && !drewPuppetSceneComposite {
            let dispatcher = WPEMetalShaderDispatcher(executor: self)
            try dispatcher.dispatch(
                pass: pass,
                layer: drawLayer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: needsDepth ? .depth32Float : .invalid
            )

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Resolves the object's visible animation layers into evaluator layers. The scene can stack
    /// several (e.g. a base idle-sway layer + an ADDITIVE blink/face layer); we play them all so
    /// blinks/mouth motion compose on top of the body sway, instead of only the first layer.
    func puppetAnimationLayers(
        for layer: WPERenderLayer,
        model: WPEPuppetModel
    ) -> [WPEPuppetAnimationLayer] {
        guard !layer.animationLayers.isEmpty else {
            return model.animations.first.map {
                [WPEPuppetAnimationLayer(animation: $0, rate: 1, additive: false, blend: 1)]
            } ?? []
        }
        return layer.animationLayers.compactMap { sceneLayer in
            guard sceneLayer.visible,
                  let animation = model.animations.first(where: { $0.id == sceneLayer.animation }) else {
                return nil
            }
            return WPEPuppetAnimationLayer(
                animation: animation,
                rate: sceneLayer.rate > 0 ? sceneLayer.rate : 1,
                additive: sceneLayer.additive,
                blend: Float(sceneLayer.blend)
            )
        }
    }

    /// Validates skinning for every puppet and caches each parent's animated palette once, so an
    /// attached child can read its parent's anchor-bone transform before the child itself renders.
    private func makeAttachmentFrameContext(
        for pipeline: WPEPreparedRenderPipeline,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        sceneSize: CGSize
    ) -> PuppetAttachmentFrameContext {
        var attachedChildNamesByParent: [String: Set<String>] = [:]
        for layer in pipeline.layers {
            guard let parentID = layer.graphLayer.parentObjectID,
                  let attachment = layer.graphLayer.attachment else { continue }
            attachedChildNamesByParent[parentID, default: []].insert(attachment)
        }
        // The objectID→layer index is only ever read to resolve a child's parent
        // puppet in `layerApplyingAttachmentFollow`; a scene with no attached
        // children never touches it, so skip building it there.
        let layersByID: [String: WPEPreparedRenderLayer] = attachedChildNamesByParent.isEmpty
            ? [:]
            : Dictionary(
                pipeline.layers.map { ($0.graphLayer.objectID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        var skinningByObjectID: [String: PuppetSkinningState] = [:]
        for layer in pipeline.layers {
            guard let model = layer.puppetModel else { continue }
            skinningByObjectID[layer.graphLayer.objectID] = validatedSkinningState(
                for: layer.graphLayer,
                model: model,
                attachedChildNames: attachedChildNamesByParent[layer.graphLayer.objectID] ?? [],
                time: runtimeUniforms.time
            )
        }
        recordPuppetSkinningBreadcrumbs(pipeline: pipeline, skinningByObjectID: skinningByObjectID)
        return PuppetAttachmentFrameContext(
            layersByObjectID: layersByID,
            skinningByObjectID: skinningByObjectID,
            sceneSize: sceneSize
        )
    }

    /// Per-objectID dedup so the skinning-gate reason logs once per change, not per frame.
    /// Reset on graph rebuild so every scene load leaves one breadcrumb per puppet.
    var lastLoggedPuppetSkinningReason: [String: String] = [:]

    /// Gate validation runs per frame, so its two expensive pieces memoize per objectID (reset on
    /// graph rebuild via `releaseTransientResources`, since a reload can reuse an objectID for a
    /// different puppet):
    /// - the clip-wide displacement scan (6 palette evaluations) is time-independent given the
    ///   animation-layer stack, keyed by that stack's signature;
    /// - the per-frame palette evaluation keys by frame A/B plus Float interpolation weight, so an
    ///   unchanged interpolation tuple reproduces the palette bit-exactly without flattening motion.
    var characterSheetWarnedReasonByObjectID: [String: String] = [:]
    struct PuppetBoundScanCacheEntry {
        let stackSignature: [UInt64]
        let detail: String?
    }
    var puppetBoundScanDetailByObjectID: [String: PuppetBoundScanCacheEntry] = [:]
    struct PuppetPaletteCacheEntry {
        let frameSignature: [UInt64]
        let evaluation: WPEPuppetPaletteEvaluation
    }
    var puppetPaletteCacheByObjectID: [String: PuppetPaletteCacheEntry] = [:]

    /// Cache-hit counters proving the memoization actually short-circuits (a recompute-only path
    /// would still pass the output-equality tests). Production cost is one Int increment.
    var puppetPaletteCacheHitsForTesting = 0
    var puppetBoundScanCacheHitsForTesting = 0

    /// Recycles bone-palette buffers across frames instead of `makeBuffer` per draw. Buffers are
    /// power-of-two bucketed so puppets with different bone counts share them; the shader only reads
    /// `paletteCount` entries (`indices < paletteCount` guards every tap), so a bucket's stale tail is
    /// never sampled. Lock-protected: `recycle` runs on Metal completion threads.
    final class PuppetBonePaletteBufferPool: @unchecked Sendable {
        private let lock = NSLock()
        private var freeBuffersByLength: [Int: [MTLBuffer]] = [:]
        /// Frames in flight are semaphore-bounded, so a scene needs at most a few buffers per
        /// puppet; anything beyond this per bucket is released rather than hoarded.
        private let maxFreePerLength = 8

        func acquire(byteCount: Int, device: MTLDevice) -> MTLBuffer? {
            let length = Self.bucketLength(for: byteCount)
            lock.lock()
            let reused = freeBuffersByLength[length]?.popLast()
            lock.unlock()
            return reused ?? device.makeBuffer(length: length, options: [])
        }

        func recycle(_ buffers: [MTLBuffer]) {
            guard !buffers.isEmpty else { return }
            lock.lock()
            for buffer in buffers where (freeBuffersByLength[buffer.length]?.count ?? 0) < maxFreePerLength {
                freeBuffersByLength[buffer.length, default: []].append(buffer)
            }
            lock.unlock()
        }

        func drain() {
            lock.lock()
            freeBuffersByLength.removeAll()
            lock.unlock()
        }

        private static func bucketLength(for byteCount: Int) -> Int {
            var length = 256
            while length < byteCount { length <<= 1 }
            return length
        }
    }

    let bonePaletteBufferPool = PuppetBonePaletteBufferPool()
    /// Palette buffers bound while encoding the current frame; handed to the frame command buffer's
    /// completion handler at commit so they return to the pool only after the GPU has consumed them.
    /// A frame aborted before commit leaves its buffers here — they ride along with the next commit
    /// (never executed by the GPU, so recycling them late is safe, early would be too).
    var bonePaletteBuffersInFlight: [MTLBuffer] = []

    /// Puppet mesh vertex/index topology is immutable for the scene's lifetime (skinning is applied
    /// per-frame in the vertex shader via the bone palette, not by re-baking geometry), so the GPU
    /// buffers are built once per mesh and reused every frame. Dropped on reload via
    /// `releaseTransientResources`.
    struct PuppetMeshBufferKey: Hashable {
        /// The resolved scene-relative model path is stable for the prepared
        /// pipeline's lifetime and unique within one scene. The cache is cleared
        /// on every reload, so path + mesh index identifies immutable topology
        /// without hashing millions of vertex/index elements on every draw.
        let modelPath: String
        let meshIndex: Int
    }
    struct PuppetMeshBuffers {
        let vertex: MTLBuffer
        let index: MTLBuffer
        let indexType: MTLIndexType
        let indexStride: Int
    }
    var puppetMeshBufferCache: [PuppetMeshBufferKey: PuppetMeshBuffers] = [:]

    /// See `PresentCompletionTexture`: `MTLBuffer` handles are thread-safe but not `Sendable`-annotated.
    struct PaletteBufferRecycleBatch: @unchecked Sendable {
        let buffers: [MTLBuffer]
    }

    /// Breaks the `_rt_*` scene-alias hazard.
    private func snapshotFullFrameBufferIfAliasingScene(
        pass: WPEPreparedRenderPass,
        destinationTexture: MTLTexture,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        // Any pass sampling a scene alias participates — not only scene-target
        // draws. WPE re-captures the frame (CopyResource) for EVERY layer that
        // samples it, so a snapshot taken for one layer goes stale as soon as
        // later layers draw to the scene. 3521337568: the shine chain captured
        // at pass 48, then the fullscreen filmgrain layer (a layerComposite-target
        // copy at pass 63) reused that capture and its full-frame redraw erased
        // the beams/halo/shine drawn in between.
        func needsSnapshot(_ name: String) -> Bool {
            // A real same-frame render target (has a texture but no snapshot
            // marker — e.g. a chain rendering INTO `_rt_HalfFrameBuffer`) owns
            // its content; never overwrite it with a scene capture.
            if frameState.latestNamedTextures[name] != nil,
               frameState.sceneAliasSnapshotGenerations[name] == nil {
                return false
            }
            // Snapshot on the first reference this frame, or whenever a later
            // scene write made the previous capture stale.
            return frameState.sceneAliasSnapshotGenerations[name] != frameState.sceneWriteGeneration
        }

        var seen = Set<String>()
        for reference in textureReferences(for: pass) {
            guard case .fbo(let alias) = reference,
                  WPETextureReference.isSceneAliasName(alias),
                  seen.insert(alias).inserted,
                  needsSnapshot(alias) else {
                continue
            }
            let snapshot = try targetPool.texture(
                for: .fbo(name: alias),
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: destinationTexture
            )
            if let source = frameState.currentFrameSceneTexture {
                try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
            } else {
                try clearTexture(snapshot, color: clearColor(for: .scene), commandBuffer: commandBuffer)
            }
            frameState.markInitialized(snapshot)
            frameState.latestNamedTextures[alias] = snapshot
            frameState.sceneAliasSnapshotGenerations[alias] = frameState.sceneWriteGeneration
        }
    }

    private func clearTexture(
        _ texture: MTLTexture,
        color: MTLClearColor,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = color
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "clear")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
    }

    func copyTexture(
        _ source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()
    }

    /// Keeps the layer's ping-pong composite chain intact for a pass whose
    /// visibility gate is closed: the target must end the pass holding exactly
    /// what the source held, or the next pass in the chain samples an FBO nothing
    /// wrote this frame. Only composite targets need this — an effect-local `.fbo`
    /// is read solely by later passes of the SAME (also gated-off) effect, and the
    /// graph builder guarantees a gated pass never targets `.scene`.
    private func encodeGatedPassthrough(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        guard case .layerComposite = pass.pass.target else { return }
        let sourceTexture: MTLTexture?
        switch pass.pass.source {
        case .fbo(let name):
            sourceTexture = frameState.latestTexture(for: .named(name))
        case .image(let name), .asset(let name):
            sourceTexture = textures[name]
        case .previous:
            // Reads the target's own prior content: leaving the target untouched
            // already IS the passthrough.
            return
        }
        guard let sourceTexture else { return }
        let destination = try targetTexture(
            for: pass.pass.target,
            layer: layer,
            frameState: &frameState,
            avoiding: sourceTexture
        )
        guard ObjectIdentifier(destination.texture) != ObjectIdentifier(sourceTexture) else {
            frameState.registerWrite(texture: destination.texture, targetID: destination.id)
            return
        }
        try copyTexture(sourceTexture, to: destination.texture, commandBuffer: commandBuffer)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    private func encodeCopy(
        reference: WPETextureReference,
        target: WPERenderTarget,
        layer: WPERenderLayer,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        let targetID = WPEMetalTargetID(target: target)
        let initialPreviousTextureForTarget = frameState.latestTexture(for: targetID)
        let readsCurrentTarget = reference == .previous
        let destination = try targetTexture(
            for: target,
            layer: layer,
            frameState: &frameState,
            avoiding: readsCurrentTarget ? initialPreviousTextureForTarget : nil
        )

        let previousTextureForTarget: MTLTexture?
        if readsCurrentTarget {
            previousTextureForTarget = try previousTextureForRead(
                targetID: targetID,
                matching: destination.texture,
                commandBuffer: commandBuffer,
                frameState: &frameState
            )
        } else {
            previousTextureForTarget = initialPreviousTextureForTarget
        }

        if readsCurrentTarget,
           let previousTextureForTarget,
           ObjectIdentifier(previousTextureForTarget) != ObjectIdentifier(destination.texture),
           !frameState.hasInitialized(destination.texture) {
            try copyTexture(
                previousTextureForTarget,
                to: destination.texture,
                commandBuffer: commandBuffer
            )
            frameState.markInitialized(destination.texture)
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = frameState.hasInitialized(destination.texture) ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor(for: destination.id)

        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "copy|\(layer.objectName)")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)

        encoder.setRenderPipelineState(try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: destination.texture.pixelFormat
        ))
        encoder.setFragmentTexture(
            try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            index: 0
        )
        // Parallax is a geometry translation applied in object-quad scene
        // passes; raw-pointer UV shifts are intentionally not applied here.
        // (Plain full-frame layers routed through this fullscreen copy don't
        // parallax — see the camera-parallax limitations note.) The copy
        // fragment samples 1:1 and takes no fragment uniform buffer.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// Thin delegate so call sites — including `WPEMetalShaderDispatcher` across files — keep the same call shape after the pipeline cache became a separate type.
    func renderPipeline(
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String = "disabled",
        alphaWritePolicy: WPEMetalAlphaWritePolicy = .all,
        colorPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat,
        depthPixelFormat: MTLPixelFormat = .invalid
    ) throws -> MTLRenderPipelineState {
        try pipelineCache.pipelineState(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
    }

    /// True when this pass is WPE `effects/skew` in MODE=1 (Vertex): the quad
    /// geometry must be displaced in the vertex stage (the fragment leaves the UV
    /// untouched in MODE=1, so a fragment-only transpile drops the effect
    /// entirely). MODE=0 (UV) is handled by the ordinary transpiled fragment.
    func isVertexSkewPass(_ pass: WPEPreparedRenderPass) -> Bool {
        guard isSkewShaderPath(pass.pass.shader) else {
            return false
        }
        let mode = pass.comboValues["MODE"] ?? pass.pass.combos["MODE"] ?? 0
        guard mode == 1 else { return false }
        let params = vertexSkewParams(for: pass)
        // All-zero params = skew disabled → keep the plain object quad.
        return params.topBottomLeftRight != SIMD4<Float>(repeating: 0)
    }

    /// Content-keyed memo of the skew-shader path check.
    private func isSkewShaderPath(_ rawShader: String) -> Bool {
        if let cached = skewShaderPathCache[rawShader] { return cached }
        let shader = rawShader
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let isSkew = shader == "effects/skew" || shader.hasSuffix("/effects/skew")
        skewShaderPathCache[rawShader] = isSkew
        return isSkew
    }

    /// The MODE=1 skew corner-displacement params (top/bottom/left/right) as
    /// fractions of the quad extent, read from the pass material values. WPE's
    /// `skew.vert` multiplies the displacement by `g_TextureReductionScale`
    /// (`textureScale = g_Texture0Resolution.zw * g_TextureReductionScale`), so it
    /// is folded in here — it defaults to 1.0 (full resolution), which is the case
    /// for the FBO-composite textures skew effects sample.
    func vertexSkewParams(for pass: WPEPreparedRenderPass) -> WPESkewParams {
        let keyIndex = uniformKeyIndex(for: pass)
        func value(_ names: [String], default fallback: Float = 0) -> Float {
            for name in names {
                if let v = pass.uniformValues[name] ?? pass.pass.constants[name] {
                    return Self.scalarValue(v, default: fallback)
                }
            }
            // Same precedence as the scan this replaces: any uniformValues
            // case-variant match wins over any constants one.
            for name in names {
                if let canonical = keyIndex.uniformKeys[name.lowercased()],
                   let v = pass.uniformValues[canonical] {
                    return Self.scalarValue(v, default: fallback)
                }
            }
            for name in names {
                if let canonical = keyIndex.constantsKeys[name.lowercased()],
                   let v = pass.pass.constants[canonical] {
                    return Self.scalarValue(v, default: fallback)
                }
            }
            return fallback
        }
        let reductionScale = value(["textureReductionScale", "g_TextureReductionScale"], default: 1)
        return WPESkewParams(topBottomLeftRight: reductionScale * SIMD4<Float>(
            value(["top", "g_Top"]),
            value(["bottom", "g_Bottom"]),
            value(["left", "g_Left"]),
            value(["right", "g_Right"])
        ))
    }

    func usesObjectQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) -> Bool {
        if isGroupRenderTarget(pass.pass.target, layer: layer) {
            return true
        }
        guard case .scene = pass.pass.target else { return false }
        if layer.geometry == .identity {
            // Identity full-frame layers normally take the fullscreen copy path.
            // Route them through the object quad (an identical full-scene quad)
            // only when there's an actual parallax shift to apply, leaving the
            // common no-parallax path byte-for-byte unchanged.
            // `amount != 0` as well as a live cursor: the smoother keeps tracking
            // for `g_ParallaxPosition` even when the scene disables parallax, and
            // a non-zero `smoothed` alone would then drag full-frame layers off
            // the fullscreen copy path for a shift that resolves to zero.
            return layer.parallaxDepth != SIMD2<Double>(0, 0)
                && cameraParallax.amount != 0
                && cameraParallax.smoothed != SIMD2<Float>(0, 0)
        }
        // WPE fullscreen/passthrough utility layers (project/fullscreen and
        // oversized compose) capture + copy the full frame 1:1. A plain
        // `composelayer.json` authored into a safe sub-rect captures the
        // matching scene area into its layer composite, then its final scene
        // output is confined to that box via the object quad.
        if layer.isUtilityModelLayer {
            if layer.groupCompositeSource != nil { return true }
            return sceneCaptureUtilityOutputGeometry(for: layer) == .subregion
        }
        return true
    }

    func sceneCaptureUtilityOutputGeometry(
        for layer: WPERenderLayer
    ) -> WPEMetalSceneCaptureUtilityModels.OutputGeometry {
        guard layer.isUtilityModelLayer else {
            return .fullscreen
        }
        // A compose layer that parents children is a layer-group container, not
        // a scene-effect box: its children render flat, so confining its own
        // passthrough to the authored box would paint a scene-copy PiP. Keep it
        // fullscreen (identity passthrough = invisible).
        if groupingContainerObjectIDs.contains(layer.objectID) { return .fullscreen }
        return targetPool.sceneCaptureGeometryMemo.outputGeometry(
            layer: layer,
            geometry: layer.geometry,
            sceneSize: currentSceneSize
        )
    }

    func isGroupRenderTarget(_ target: WPERenderTarget, layer: WPERenderLayer) -> Bool {
        guard case .fbo(let name) = target else { return false }
        return name == layer.groupRenderTarget
    }

    func objectQuadSceneSize(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: WPEMetalFrameState
    ) -> CGSize {
        guard isGroupRenderTarget(pass.pass.target, layer: layer) else {
            return frameState.sceneSize
        }
        // WORLD canvas, never `destination.texture` dimensions: with render
        // scaling active the group RT is allocated `pixelScale` smaller than
        // its authored canvas, and quad NDC math built on the texture size
        // would grow every group member by 1/pixelScale.
        return targetPool.worldCanvasSize(
            for: pass.pass.target,
            layer: layer,
            sceneSize: frameState.sceneSize
        )
    }

    func objectQuadCameraUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        frameState: WPEMetalFrameState
    ) -> WPEMetalCameraUniforms {
        isGroupRenderTarget(pass.pass.target, layer: layer) ? .identity : frameState.cameraUniforms
    }

    /// Scene-centred origin of a layer's parallax root, for every layer that has one.
    ///
    /// `parallaxDepth` is already inherited down a parented subtree so the subtree
    /// shifts as one unit (`WPERenderGraphBuilder.propagatingParallaxDepthThroughParents`).
    /// The static half of the shift, `(nodePos - camPos) * depth * amount`, must
    /// therefore be evaluated ONCE, at the root — feeding each child its own origin
    /// turns the rigid translation into an anisotropic scale of the whole subtree
    /// about the scene centre by `(1 + depth * amount)`. Ground truth, 3719111841,
    /// both Windows RenderDoc captures: the `g_ModelViewProjectionMatrix` translation
    /// of the root (475 长发3) and of its child (91 主体) differ from their authored
    /// origins by the SAME vector to 3.5e-5 scene px.
    static func parallaxRootCenters(
        for layers: [WPERenderLayer],
        sceneSize: CGSize,
        objectParentByID: [String: String] = [:],
        hostDepthByObjectID: [String: SIMD2<Double>] = [:],
        hostOriginByObjectID: [String: SIMD2<Double>] = [:]
    ) -> [String: SIMD2<Float>] {
        guard layers.contains(where: { $0.parentObjectID != nil }) else { return [:] }
        let geometryByID = Dictionary(
            layers.map { ($0.objectID, $0.geometry) }, uniquingKeysWith: { first, _ in first }
        )
        // Same anchor-node selection as the depth propagation, so the depth and
        // the static-term origin always come from the SAME node — a non-drawn
        // group host counts, anchored at its authored origin.
        var depthByID = hostDepthByObjectID
        for layer in layers where depthByID[layer.objectID] == nil {
            depthByID[layer.objectID] = layer.parallaxDepth
        }
        var parentByID = objectParentByID
        if parentByID.isEmpty {
            parentByID = Dictionary(
                layers.compactMap { layer in layer.parentObjectID.map { (layer.objectID, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
        var centers: [String: SIMD2<Float>] = [:]
        for layer in layers where layer.parentObjectID != nil {
            let anchor = WPERenderGraphBuilder.parallaxAnchorNodeID(
                of: layer.objectID, parentByID: parentByID, depthByID: depthByID
            )
            guard anchor != layer.objectID else { continue }
            if let geometry = geometryByID[anchor] {
                centers[layer.objectID] = centeredOrigin(of: geometry, sceneSize: sceneSize)
            } else if let origin = hostOriginByObjectID[anchor] {
                centers[layer.objectID] = SIMD2<Float>(
                    Float(origin.x) - Float(max(sceneSize.width, 1)) * 0.5,
                    Float(origin.y) - Float(max(sceneSize.height, 1)) * 0.5
                )
            }
        }
        return centers
    }

    /// The object-quad anchor: authored origin measured from the scene centre,
    /// accepting the normalized 0...1 origin form the parser can emit.
    static func centeredOrigin(
        of geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> SIMD2<Float> {
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        return SIMD2<Float>(originXPixels - sceneWidth * 0.5, originYPixels - sceneHeight * 0.5)
    }

    /// `objectCenter` for `pixelOffset`: the parallax root's centre for a parented
    /// layer, the layer's own anchor for a root.
    func parallaxObjectCenter(
        for layer: WPERenderLayer,
        fallback: SIMD2<Float>
    ) -> SIMD2<Double> {
        let center = parallaxRootCenterByObjectID[layer.objectID] ?? fallback
        return SIMD2<Double>(Double(center.x), Double(center.y))
    }

    /// World-pixel size of a source texture for quad layout: the AUTHORED image
    /// size from the metadata registry, which survives the loader uploading a
    /// reduced mip under render scaling. Unregistered textures fall back to
    /// their own dimensions — identical to reading `texture.width` directly.
    static func worldSourceSize(of texture: MTLTexture) -> (width: Float, height: Float) {
        let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
        return (Float(resolution.worldWidth), Float(resolution.worldHeight))
    }

    func objectQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame = .neutral,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms = .identity
    ) -> WPEObjectQuadUniforms {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        // Identity (full-frame) layers map to a scene-sized quad centered at the
        // origin — identical coverage + UV to `wpe_fullscreen_vertex` — plus the
        // camera-parallax shift. (Only reached when parallax is active; see
        // `usesObjectQuadGeometry`.)
        if geometry == .identity {
            // Full-frame layer: its origin IS the scene centre, so the static
            // parallax term is zero and only the cursor moves it — unless it is
            // parented, in which case it rides its root's offset.
            let parallax = cameraParallax.pixelOffset(
                objectCenter: parallaxObjectCenter(for: layer, fallback: .zero),
                depth: layer.parallaxDepth,
                sceneSize: sceneSize
            )
            let uniforms = WPEObjectQuadUniforms(
                centerAndSize: SIMD4<Float>(parallax.x, parallax.y, sceneWidth, sceneHeight),
                sceneSizeAndRotation: SIMD4<Float>(sceneWidth, sceneHeight, 0, 0),
                uvSignAndPadding: SIMD4<Float>(1, 1, 0, 0)
            )
            recordObjectQuadDebug(
                layer: layer,
                sourceTexture: sourceTexture,
                cameraUniforms: cameraUniforms,
                uniforms: uniforms,
                path: "identity"
            )
            return uniforms
        }
        if cameraUniforms.usesPerspectiveProjection,
           let projected = perspectiveObjectQuadUniforms(
            for: layer,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight,
            cameraParallax: cameraParallax,
            sourceTexture: sourceTexture,
            cameraUniforms: cameraUniforms
           ) {
            recordObjectQuadDebug(
                layer: layer,
                sourceTexture: sourceTexture,
                cameraUniforms: cameraUniforms,
                uniforms: projected,
                path: "perspective"
            )
            return projected
        }
        // Scene-capture utility subregion layers use the SAME object-quad geometry
        // as the normal placed-layer path below. At render time `geometry.origin`
        // is already in the renderer's top-left pixel convention (resolved by the
        // parser/builder), so the `originX - sceneWidth*0.5` anchor places the box
        // correctly. An earlier center-origin special-case here pushed the box
        // off-screen (runtime origin (1089,1862) → NDC (0.57,1.72)) and blanked
        // the bars; the raw scene.json center-origin value never reaches here.
        let sourceWorldSize = Self.worldSourceSize(of: sourceTexture)
        let baseWidth = geometry.size.map { Float($0.width) } ?? sourceWorldSize.width
        let baseHeight = geometry.size.map { Float($0.height) } ?? sourceWorldSize.height
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let width = max(baseWidth * max(abs(scaleX), 0.0001), 0.0001)
        let height = max(baseHeight * max(abs(scaleY), 0.0001), 0.0001)
        let anchor = Self.centeredOrigin(of: geometry, sceneSize: sceneSize)
        let center = anchor + Self.alignmentCenterOffset(
            alignment: geometry.alignment,
            width: width,
            height: height
        ) + cameraParallax.pixelOffset(
            objectCenter: parallaxObjectCenter(for: layer, fallback: anchor),
            depth: layer.parallaxDepth,
            sceneSize: sceneSize
        )
        let uniforms = WPEObjectQuadUniforms(
            centerAndSize: SIMD4<Float>(center.x, center.y, width, height),
            sceneSizeAndRotation: SIMD4<Float>(
                sceneWidth,
                sceneHeight,
                Float(geometry.angles.z),
                0
            ),
            uvSignAndPadding: SIMD4<Float>(
                scaleX < 0 ? -1 : 1,
                scaleY < 0 ? -1 : 1,
                0,
                0
            )
        )
        recordObjectQuadDebug(
            layer: layer,
            sourceTexture: sourceTexture,
            cameraUniforms: cameraUniforms,
            uniforms: uniforms,
            path: cameraUniforms.usesPerspectiveProjection ? "perspective-fallback" : "orthographic"
        )
        return uniforms
    }

    private func perspectiveObjectQuadUniforms(
        for layer: WPERenderLayer,
        sceneWidth: Float,
        sceneHeight: Float,
        cameraParallax: WPECameraParallaxFrame,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms
    ) -> WPEObjectQuadUniforms? {
        let geometry = layer.geometry
        let sceneSize = CGSize(width: CGFloat(sceneWidth), height: CGFloat(sceneHeight))
        guard let projection = cameraUniforms.projectedCenterInScenePixels(
            worldPoint: geometry.origin,
            sceneSize: sceneSize
        ) else { return nil }
        let sourceWorldSize = Self.worldSourceSize(of: sourceTexture)
        let baseWidth = geometry.size.map { Float($0.width) } ?? sourceWorldSize.width
        let baseHeight = geometry.size.map { Float($0.height) } ?? sourceWorldSize.height
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let width = max(baseWidth * max(abs(scaleX), 0.0001) * projection.depthScale, 0.0001)
        let height = max(baseHeight * max(abs(scaleY), 0.0001) * projection.depthScale, 0.0001)
        let quadCenter = projection.center
            + Self.alignmentCenterOffset(alignment: geometry.alignment, width: width, height: height)
            + cameraParallax.pixelOffset(
                objectCenter: parallaxObjectCenter(for: layer, fallback: projection.center),
                depth: layer.parallaxDepth,
                sceneSize: sceneSize
            )
        return WPEObjectQuadUniforms(
            centerAndSize: SIMD4<Float>(quadCenter.x, quadCenter.y, width, height),
            sceneSizeAndRotation: SIMD4<Float>(
                sceneWidth,
                sceneHeight,
                Float(geometry.angles.z),
                0
            ),
            uvSignAndPadding: SIMD4<Float>(
                scaleX < 0 ? -1 : 1,
                scaleY < 0 ? -1 : 1,
                0,
                0
            )
        )
    }

    /// A DIRECTDRAW `shape: "quad"` layer draws through the 4-corner geometry
    /// (light beams etc.), not the axis-aligned object quad. Gated to the
    /// orthographic scene draw — the corners are pre-projected here so a live
    /// perspective camera falls back to the object quad.
    func usesShapeQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard let points = layer.geometry.shapePoints, points.count == 4 else { return false }
        guard case .scene = pass.pass.target else { return false }
        return !frameState.cameraUniforms.usesPerspectiveProjection
    }

    /// Builds the four perspective-quad corners for a shape-quad layer. Each WPE
    /// point maps to a model-space corner `((p.x-0.5)·H, (0.5-p.y)·H)` in a square
    /// base of the scene height, then the layer scale/rotation/origin/parallax are
    /// applied — identical to how the object quad places its rectangle, so a
    /// unit-square set of points reduces to the object-quad rectangle. Corners are
    /// emitted in triangle-strip order (p0, p1, p3, p2) and carry the point value
    /// as the UV for the fragment perspective reconstruction.
    func shapeQuadUniforms(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame = .neutral
    ) -> WPEShapeQuadUniforms {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        // `usesShapeQuadGeometry` gates every call to exactly 4 points.
        let points = geometry.shapePoints!
        let baseSquare = sceneHeight
        let scaleX = Float(geometry.scale.x)
        let scaleY = Float(geometry.scale.y)
        let rotation = Float(geometry.angles.z)
        let cosR = cos(rotation)
        let sinR = sin(rotation)

        let centered = Self.centeredOrigin(of: geometry, sceneSize: sceneSize)
        let center = centered + cameraParallax.pixelOffset(
            objectCenter: parallaxObjectCenter(for: layer, fallback: centered),
            depth: layer.parallaxDepth,
            sceneSize: sceneSize
        )

        func corner(_ point: SIMD2<Double>) -> SIMD4<Float> {
            let model = SIMD2<Float>(
                (Float(point.x) - 0.5) * baseSquare,
                (0.5 - Float(point.y)) * baseSquare
            )
            let scaled = SIMD2<Float>(model.x * scaleX, model.y * scaleY)
            let rotated = SIMD2<Float>(
                cosR * scaled.x - sinR * scaled.y,
                sinR * scaled.x + cosR * scaled.y
            )
            let scenePixels = center + rotated
            return SIMD4<Float>(scenePixels.x, scenePixels.y, Float(point.x), Float(point.y))
        }

        // Triangle-strip order (p0, p1, p3, p2) matches `wpe_object_quad_vertex`'s
        // TL,TR,BL,BR corner sequence so the two triangles tile the convex quad.
        let p0 = points[0]
        let p1 = points[1]
        let p2 = points[2]
        let p3 = points[3]
        return WPEShapeQuadUniforms(
            corner0: corner(p0),
            corner1: corner(p1),
            corner2: corner(p3),
            corner3: corner(p2),
            sceneHalfAndPad: SIMD4<Float>(sceneWidth * 0.5, sceneHeight * 0.5, 0, 0)
        )
    }

    private func recordObjectQuadDebug(
        layer: WPERenderLayer,
        sourceTexture: MTLTexture,
        cameraUniforms: WPEMetalCameraUniforms,
        uniforms: WPEObjectQuadUniforms,
        path: String
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        let origin = layer.geometry.origin
        let scale = layer.geometry.scale
        WPESceneDebugArtifacts.shared.appendLog(
            "[objectQuad] path=\(path) perspective=\(cameraUniforms.usesPerspectiveProjection) "
                + "layer=\(layer.objectName) id=\(layer.objectID) "
                + "origin=(\(origin.x),\(origin.y),\(origin.z)) scale=(\(scale.x),\(scale.y),\(scale.z)) "
                + "source=\(sourceTexture.width)x\(sourceTexture.height) "
                + "center=(\(uniforms.centerAndSize.x),\(uniforms.centerAndSize.y)) "
                + "size=(\(uniforms.centerAndSize.z),\(uniforms.centerAndSize.w))",
            level: .notice
        )
    }

    static func alignmentCenterOffset(
        alignment: WPESceneAlignment,
        width: Float,
        height: Float
    ) -> SIMD2<Float> {
        switch alignment {
        case .center:
            return SIMD2<Float>(0, 0)
        case .topLeft:
            return SIMD2<Float>(width * 0.5, -height * 0.5)
        case .topRight:
            return SIMD2<Float>(-width * 0.5, -height * 0.5)
        case .bottomLeft:
            return SIMD2<Float>(width * 0.5, height * 0.5)
        case .bottomRight:
            return SIMD2<Float>(-width * 0.5, height * 0.5)
        case .top:
            return SIMD2<Float>(0, -height * 0.5)
        case .bottom:
            return SIMD2<Float>(0, height * 0.5)
        case .left:
            return SIMD2<Float>(width * 0.5, 0)
        case .right:
            return SIMD2<Float>(-width * 0.5, 0)
        }
    }

    #if DEBUG
    /// Blit a copy of the current scene output into a fresh texture and stash it
    /// for `WPEDumpScenePasses` PNG dumping. The blit is encoded inline so it
    /// captures the output exactly as of this pass in the command stream.
    private func captureScenePassIfDumping(
        _ enabled: Bool,
        label: String,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard enabled,
              let snapshot = makeDebugSnapshotTexture(
                  width: output.width,
                  height: output.height,
                  pixelFormat: output.pixelFormat
              ),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(
            from: output,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
            to: snapshot,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        scenePassDumps.append((label: label, texture: snapshot))
    }

    private func makeDebugSnapshotTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "WPE Metal debug pass snapshot"
        return texture
    }
    #endif

    #if DEBUG
    /// Decode any sampleable texture (incl. BC/DXT, RG88, R8) into rgba8 by
    /// sampling it through a fullscreen copy, so the PNG dumper can visualize
    /// compressed character/scene textures that the raw byte dumper skips.
    func debugDecodeToRGBA(_ source: MTLTexture) -> MTLTexture? {
        // Dedicated `.shared` target: the caller reads it back with `getBytes`,
        // and the output ring is `.private` (and must not vend debug scratch).
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(source.width, 1),
            height: max(source.height, 1),
            mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        output.label = "WPE Metal debug decode"
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipeline = try? renderPipeline(
                  vertexName: "wpe_fullscreen_vertex",
                  fragmentName: "wpe_util_copy_fragment",
                  blendMode: "disabled",
                  colorPixelFormat: output.pixelFormat
              ) else {
            return nil
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }
    #endif

    /// Developer-only image brightness/color diagnostic; gated by its own key so it
    /// is independent of the unrelated audio-reactive DSP log toggle.
    private static let imageUniformDebugEnabled = UserDefaults.standard.bool(forKey: "WPEImageUniformDebugLog")
    private static let loggedImageUniformNames = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func genericImageUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasMask: Bool,
        sourceTexture: MTLTexture? = nil,
        maskTexture: MTLTexture? = nil
    ) -> WPEGenericImageUniforms {
        // WPE bakes the object's authored `color` into g_Color4 for every
        // image material (RenderDoc: 90/116 distinct captured values are
        // non-white), so the layer tint multiplies the material's own g_Color
        // — same channel the brightness field already rides.
        let materialColor = WPEMetalShaderInputs.colorVector(for: pass)
        let layerTint = WPEMetalShaderInputs.linearLayerTint(layer.geometry.color)
        let color = SIMD4<Float>(
            materialColor.x * layerTint.x,
            materialColor.y * layerTint.y,
            materialColor.z * layerTint.z,
            materialColor.w
        )
        let gAlpha = WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1)
        let gBrightness = WPEMetalShaderInputs.floatScalar(
            named: ["g_Brightness", "u_Brightness", "brightness"],
            in: pass,
            frame: frameUniformContext,
            default: 1
        )
        let alpha = gAlpha * Float(layer.geometry.alpha)
        let brightness = gBrightness * Float(layer.geometry.brightness)
        let sourceUVScale = Self.logicalUVScale(for: sourceTexture)
        let maskUVScale = Self.logicalUVScale(for: maskTexture)
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.appendLog(
                "[imageUniform] layer=\(layer.objectName) id=\(layer.objectID) shader=\(pass.pass.shader) "
                    + "color=(\(color.x),\(color.y),\(color.z),\(color.w)) "
                    + "gAlpha=\(gAlpha) layerAlpha=\(layer.geometry.alpha) alpha=\(alpha) "
                    + "gBrightness=\(gBrightness) layerBrightness=\(layer.geometry.brightness) brightness=\(brightness) "
                    + "hasMask=\(hasMask) "
                    + "uvScale0=(\(sourceUVScale.x),\(sourceUVScale.y)) "
                    + "uvScale1=(\(maskUVScale.x),\(maskUVScale.y))",
                level: .notice
            )
        }
        // Diagnostic for the "black silhouette" bug: genericimage shaders do
        // `rgb = sampled.rgb * color.rgb * brightness`, so brightness==0 OR
        // color==0 blacks out the layer while alpha (a separate term) survives.
        // One line per object so the log isn't spammed.
        if Self.imageUniformDebugEnabled,
           Self.loggedImageUniformNames.withLock({ $0.insert(layer.objectName).inserted }) {
            Logger.notice(
                "[ImgUniform] \(layer.objectName) shader=\(pass.pass.shader) g_Brightness=\(gBrightness) layerBright=\(layer.geometry.brightness) → brightness=\(brightness) color=(\(color.x),\(color.y),\(color.z)) alpha=\(alpha)",
                category: .wpeRender
            )
        }
        return WPEGenericImageUniforms(
            color: color,
            alphaMaskUV: SIMD4<Float>(alpha, brightness, hasMask ? 1 : 0, 0),
            textureUVScale: SIMD4<Float>(
                sourceUVScale.x,
                sourceUVScale.y,
                maskUVScale.x,
                maskUVScale.y
            )
        )
    }

    /// generic4 scene-model material constants → fragment uniforms. Material
    /// bindings use the shader-annotation names ("color" → g_TintColor,
    /// "emissivecolor" → g_EmissiveColor…), NOT the g_* uniform names, and WPE
    /// uploads them RAW (no sRGB conversion — RenderDoc-verified). The emissive
    /// term requires BOTH the slot-2 component map and authored emissive
    /// constants: WPE's EMISSIVE_MAP combo is baked by the editor from the mask
    /// asset, which we can't read, so authored intent is the safe gate.
    func sceneModelGenericUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasComponentMap: Bool
    ) -> WPESceneModelGenericUniforms {
        func constantVector3(_ names: [String], default def: SIMD3<Float>) -> SIMD3<Float> {
            for name in names {
                if let v = pass.pass.constants[name]?.vectorValue, v.count >= 3 {
                    return SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2]))
                }
            }
            return def
        }
        func constantScalar(_ names: [String], default def: Float) -> Float {
            for name in names {
                if let v = pass.pass.constants[name]?.numberValue {
                    return Float(v)
                }
            }
            return def
        }
        func mergedVector3(_ name: String, default def: SIMD3<Float>) -> SIMD3<Float> {
            let merged = frameUniformContext.frameValue(named: name) ?? pass.uniformValues[name]
            guard let v = merged?.vectorValue, v.count >= 3 else { return def }
            return SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2]))
        }

        let tint = constantVector3(["color", "g_TintColor"], default: SIMD3<Float>(1, 1, 1))
        let tintAlpha = constantScalar(["alpha", "Alpha", "g_TintAlpha"], default: 1)
            * Float(layer.geometry.alpha)
        let emissiveColor = constantVector3(["emissivecolor", "g_EmissiveColor"], default: SIMD3<Float>(1, 1, 1))
        let emissiveBrightness = constantScalar(["emissivebrightness", "g_EmissiveBrightness"], default: 1)
        let brightness = constantScalar(["brightness", "g_Brightness"], default: 1)
            * Float(layer.geometry.brightness)
        let ambient = mergedVector3("g_LightAmbientColor", default: SIMD3<Float>(1, 1, 1))
        let skylight = mergedVector3("g_LightSkylightColor", default: SIMD3<Float>(1, 1, 1))
        let lightingEnabled = (pass.pass.combos["LIGHTING"] ?? 1) != 0
        let hdrValue = frameUniformContext.frameValue(named: "g_SceneHDREnabled")
            ?? pass.uniformValues["g_SceneHDREnabled"]
        let hdr = (hdrValue?.numberValue ?? 0) > 0.5
        let emissiveAuthored = pass.pass.constants["emissivecolor"] != nil
            || pass.pass.constants["emissivebrightness"] != nil
        let emissiveMapActive = hasComponentMap && emissiveAuthored

        return WPESceneModelGenericUniforms(
            tintColorAlpha: SIMD4<Float>(tint.x, tint.y, tint.z, tintAlpha),
            emissive: SIMD4<Float>(emissiveColor.x, emissiveColor.y, emissiveColor.z, emissiveBrightness),
            // No per-vertex normals in the mesh path — evaluate the vertex
            // hemisphere mix(skylight, ambient, N·up*0.5+0.5) at its midpoint.
            ambientLighting: SIMD4<Float>(
                (skylight.x + ambient.x) * 0.5,
                (skylight.y + ambient.y) * 0.5,
                (skylight.z + ambient.z) * 0.5,
                lightingEnabled ? 1 : 0
            ),
            brightnessFlags: SIMD4<Float>(brightness, emissiveMapActive ? 1 : 0, hdr ? 1 : 0, 0)
        )
    }

    // MARK: - Scene HDR bloom

    /// Kill switch: `defaults write com.loomscreen.pro WPEMetalSceneBloomEnabled -bool NO`.
    static let isSceneBloomEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalSceneBloomEnabled") as? Bool) ?? true


    var bloomLevelTextures: [MTLTexture] = []
    /// Backs `bloomLevelTextures` from one placement heap (same `.tracked` mechanism as the FBO
    /// aliasing pool) so the whole pyramid's memory is reclaimed in a single drop on reload. The
    /// pyramid is regenerated from the scene output every frame, so it needs no cross-frame content
    /// persistence — only the allocation is reused until the resolution/level count changes.
    var bloomLevelHeap: MTLHeap?
    var bloomLevelBaseWidth = 0
    var bloomLevelBaseHeight = 0
    var bloomLevelPixelFormat: MTLPixelFormat = .invalid
    var bloomLevelRequestedCount = 0

    private static func logicalUVScale(for texture: MTLTexture?) -> SIMD2<Float> {
        guard let texture else { return SIMD2<Float>(1, 1) }
        let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
        let scaleX = Float(resolution.imageWidth) / Float(max(resolution.textureWidth, 1))
        let scaleY = Float(resolution.imageHeight) / Float(max(resolution.textureHeight, 1))
        return SIMD2<Float>(
            min(max(scaleX, 0), 1),
            min(max(scaleY, 0), 1)
        )
    }

    static func requiresDiscreteDestinationForSourceAliasing(_ pass: WPEPreparedRenderPass) -> Bool {
        WPEBuiltinShaderName.isGodraysCombine(pass.pass.shader)
    }

    func passReadsCurrentTarget(_ pass: WPEPreparedRenderPass, targetID: WPEMetalTargetID) -> Bool {
        func reads(_ reference: WPETextureReference) -> Bool {
            switch (reference, targetID) {
            case (.previous, _):
                return true
            case (.fbo(let name), .named(let targetName)):
                return name == targetName
            default:
                return false
            }
        }
        return reads(pass.pass.source)
            || pass.pass.textures.values.contains(where: reads)
            || pass.pass.binds.values.contains(where: reads)
            || pass.textureBindings.values.contains(where: reads)
    }

    func textureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        var references: [WPETextureReference] = [pass.pass.source]
        references.append(contentsOf: pass.pass.textures.values)
        references.append(contentsOf: pass.pass.binds.values)
        references.append(contentsOf: pass.textureBindings.values)
        return references
    }

    /// Build (or fetch from cache) an `MTLRenderPipelineState` for a translated shader's fragment function.
    func translatedPipelineState(
        for result: WPEShaderCompileResult,
        vertexName: String? = nil,
        blendMode: String,
        alphaWritePolicy: WPEMetalAlphaWritePolicy,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let resolvedVertexName = vertexName ?? result.vertexFunctionName
        // Memoized lowercase: this key is rebuilt per pass per frame, and the
        // hit path must not pay a fresh `.lowercased()` allocation each time.
        let loweredBlendMode = blendFacts(blendMode).lowercased
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            vertexName: resolvedVertexName,
            fragmentName: result.fragmentFunctionName,
            blendMode: loweredBlendMode,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: colorPixelFormat.rawValue,
            depthPixelFormat: depthPixelFormat.rawValue
        )
        if let cached = translatedPipelineCache[key] {
            return cached
        }
        guard let vertex = result.library.makeFunction(name: resolvedVertexName)
            ?? defaultLibrary.makeFunction(name: resolvedVertexName),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(result.fragmentFunctionName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        WPEMetalPipelineCache.applyBlendMode(loweredBlendMode, to: colorAttachment)
        WPEMetalPipelineCache.applyAlphaWritePolicy(alphaWritePolicy, to: colorAttachment)
        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WPEMetalRenderExecutorError.pipelineStateBuildFailed(
                name: result.fragmentFunctionName,
                detail: error.localizedDescription
            )
        }
        translatedPipelineCache[key] = state
        return state
    }

    /// One translated-shader pipeline combo to pre-compile off the render thread.
    /// `@unchecked Sendable`: the Metal handles it carries (device, library, functions)
    /// are all documented thread-safe — this lets the whole request cross into the
    /// prewarm task group as one Sendable value, so no bare `MTLDevice` is captured.
    struct WPETranslatedPipelinePrewarm: @unchecked Sendable {
        let device: MTLDevice
        let result: WPEShaderCompileResult
        let vertexName: String?
        let blendMode: String
        let alphaWritePolicy: WPEMetalAlphaWritePolicy
        let colorPixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat
    }

    /// Opaque, `Sendable` result of an off-thread pipeline pre-compile — wraps the private
    /// cache key so the renderer can carry it across the task boundary and hand it back to
    /// `seedTranslatedPipelines` without seeing the key type.
    struct WPEPrewarmedPipeline: @unchecked Sendable {
        fileprivate let key: TranslatedPipelineKey
        fileprivate let state: MTLRenderPipelineState
    }

    /// Pure, thread-safe pipeline compile — mirrors `translatedPipelineState`'s descriptor
    /// construction but does NO cache mutation, so it runs concurrently off-actor in the
    /// prewarm task group. A pipeline is FULLY determined by its cache key, so a prewarmed
    /// state is byte-identical to the lazy one — an imperfect (format/vertex) prediction
    /// only costs a cache miss (the render thread rebuilds that one), never correctness.
    /// Returns nil to skip (missing function / compile failure); the real first-frame render
    /// re-hits and records it as today.
    nonisolated static func buildTranslatedPipeline(
        _ prewarm: WPETranslatedPipelinePrewarm
    ) -> WPEPrewarmedPipeline? {
        let result = prewarm.result
        let resolvedVertexName = prewarm.vertexName ?? result.vertexFunctionName
        let key = TranslatedPipelineKey(
            libraryID: ObjectIdentifier(result.library),
            vertexName: resolvedVertexName,
            fragmentName: result.fragmentFunctionName,
            blendMode: prewarm.blendMode.lowercased(),
            alphaWritePolicy: prewarm.alphaWritePolicy,
            colorPixelFormat: prewarm.colorPixelFormat.rawValue,
            depthPixelFormat: prewarm.depthPixelFormat.rawValue
        )
        guard let vertex = result.library.makeFunction(name: resolvedVertexName)
            ?? prewarm.device.makeDefaultLibrary()?.makeFunction(name: resolvedVertexName),
              let fragment = result.library.makeFunction(name: result.fragmentFunctionName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else { return nil }
        colorAttachment.pixelFormat = prewarm.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = prewarm.depthPixelFormat
        WPEMetalPipelineCache.applyBlendMode(prewarm.blendMode.lowercased(), to: colorAttachment)
        WPEMetalPipelineCache.applyAlphaWritePolicy(prewarm.alphaWritePolicy, to: colorAttachment)
        guard let state = try? prewarm.device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        return WPEPrewarmedPipeline(key: key, state: state)
    }

    /// Seed pre-compiled pipeline states built by the parallel prewarm. Synchronous and
    /// isolation-free (called on the render context before the first frame), so it never
    /// sends the non-`Sendable` executor across an await. Idempotent: never overwrites a
    /// key the render thread already built.
    func seedTranslatedPipelines(_ prewarmed: [WPEPrewarmedPipeline]) {
        for entry in prewarmed where translatedPipelineCache[entry.key] == nil {
            translatedPipelineCache[entry.key] = entry.state
        }
    }

    /// Packs runtime uniforms into the transpiler's one-to-four-float4 slot layout.
    func packTranslatedUniforms(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: WPEMetalTextureSlotTable? = nil
    ) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.translatedSlotCount(for: layout))
        let plans = uniformPlans(for: pass, layout: layout)
        let frame = frameUniformContext
        for (index, u) in layout.enumerated() {
            let value = resolvedUniformValue(
                plan: plans[index],
                pass: pass,
                frame: frame,
                texturesBySlot: texturesBySlot
            )
            if let length = u.arrayLength {
                Self.packArrayUniform(value, glslType: u.glslType, length: length, slot: u.slot, into: &slots)
                continue
            }
            switch u.glslType {
            case "float", "int", "bool":
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            case "vec2", "ivec2", "bvec2":
                let v = Self.vectorValue(value, count: 2)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
            case "vec3", "ivec3", "bvec3":
                let v = Self.vectorValue(value, count: 3)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
            case "vec4", "ivec4", "bvec4":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
            case "mat2":
                let v = Self.vectorValue(value, count: 4)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
                slots[u.slot + 1] = SIMD4<Float>(v[2], v[3], 0, 0)
            case "mat3":
                let v = Self.vectorValue(value, count: 9)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
                slots[u.slot + 1] = SIMD4<Float>(v[3], v[4], v[5], 0)
                slots[u.slot + 2] = SIMD4<Float>(v[6], v[7], v[8], 0)
            case "mat4":
                let v = Self.vectorValue(value, count: 16)
                slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
                slots[u.slot + 1] = SIMD4<Float>(v[4], v[5], v[6], v[7])
                slots[u.slot + 2] = SIMD4<Float>(v[8], v[9], v[10], v[11])
                slots[u.slot + 3] = SIMD4<Float>(v[12], v[13], v[14], v[15])
            default:
                slots[u.slot].x = Self.scalarValue(value, default: 0)
            }
        }
        return slots
    }

    struct UniformNameCandidates {
        let names: [String]
        let lowercasedNames: [String]
    }

    private var uniformNameCandidatesCache: [String: UniformNameCandidates] = [:]

    func memoizedUniformNameCandidates(for uniform: WPEUniformSlot) -> UniformNameCandidates {
        let key = uniform.name + "\u{0}" + (uniform.materialName ?? "")
        if let cached = uniformNameCandidatesCache[key] { return cached }
        let names = Self.translatedUniformNameCandidates(for: uniform)
        let candidates = UniformNameCandidates(
            names: names,
            lowercasedNames: names.map { $0.lowercased() }
        )
        uniformNameCandidatesCache[key] = candidates
        return candidates
    }

    private static func translatedUniformNameCandidates(for uniform: WPEUniformSlot) -> [String] {
        var candidates: [String] = [uniform.name]
        if let materialName = uniform.materialName, !materialName.isEmpty {
            candidates.append(materialName)
        }
        if uniform.name.hasPrefix("u_") {
            let base = String(uniform.name.dropFirst(2))
            if !base.isEmpty {
                candidates.append(base)
                candidates.append(base.prefix(1).uppercased() + String(base.dropFirst()))
            }
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
    }

    private static func firstValue(
        in values: [String: WPESceneShaderConstantValue],
        matching candidates: [String]
    ) -> WPESceneShaderConstantValue? {
        for candidate in candidates {
            if let value = values[candidate] {
                return value
            }
        }
        for candidate in candidates {
            let normalized = candidate.lowercased()
            if let match = values.first(where: { $0.key.lowercased() == normalized }) {
                return match.value
            }
        }
        return nil
    }

    /// `g_TexelSize` is a SCENE-level constant, not a per-pass one.
    ///
    /// RenderDoc, scene 3554161528 bloom chain (`workshop/2822917890`): WPE renders
    /// 3840x2160 → 1920x1080 → 960x540 → 480x270 → 240x135 and feeds the SAME
    /// `g_TexelSize` = 1/(3840, 2160) to all eight `blur_gaussian` passes — the
    /// chain's full-resolution head, never the pass's own buffer. That keeps the
    /// blur kernel a fixed width in SCREEN space as the chain downsamples.
    ///
    /// Nothing fed this before, so it packed as 0 and the transpiler substituted
    /// `1/g_Texture0Resolution.xy` (per-pass) in `v_SizeMultiplier` — a fixed
    /// TEXEL count instead, diverging from WPE by 2x/4x/8x/16x down the chain.
    static let texelSizeUniformName = "g_TexelSize"

    static func texelSizeValue(named name: String, sceneSize: CGSize) -> WPESceneShaderConstantValue? {
        guard name == texelSizeUniformName else { return nil }
        let width = Double(sceneSize.width)
        let height = Double(sceneSize.height)
        guard width > 0, height > 0 else { return nil }
        return .vector([1 / width, 1 / height])
    }

    private static func textureResolutionValue(
        named name: String,
        texturesBySlot: WPEMetalTextureSlotTable?
    ) -> WPESceneShaderConstantValue? {
        guard let slot = textureResolutionSlotIndex(for: name),
              let texture = texturesBySlot?[slot] else {
            return nil
        }
        return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
    }

    static func textureResolutionSlotIndex(for name: String) -> Int? {
        let prefix = "g_Texture"
        let suffix = "Resolution"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let slotText = name.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(slotText)
    }

    private static func scalarValue(_ value: WPESceneShaderConstantValue?, default fallback: Float) -> Float {
        switch value {
        case .number(let n): return Float(n)
        case .vector(let v): return Float(v.first ?? Double(fallback))
        case .bool(let b):   return b ? 1 : 0
        case .animated(let v): return Float(v.scalar(at: 0) ?? Double(fallback))
        case .string(let s): return Float(s) ?? fallback
        case nil:            return fallback
        }
    }

    /// Packs a GLSL array uniform (`elemType name[length]`) into `length`
    /// consecutive `float4` slots — one array element per slot, the element's
    /// components in `.x`/`.xy`/`.xyz`/`.xyzw`. This mirrors the transpiler's
    /// per-element read `u.vals[slot + i].<swizzle>` (see
    /// `WPEShaderTranspiler.renderMSL`). Both pack overloads route here so the
    /// scalar/vec packing can never drift apart again — the previous divergence
    /// (`values:` overload packed every array as `vec4[N]`; the per-pass
    /// overload under-read `vec2/3/4[N]` with `count: length`) silently
    /// corrupted scalar `float[N]` uniforms such as `g_AudioSpectrum*[N]`.
    private static func packArrayUniform(
        _ value: WPESceneShaderConstantValue?,
        glslType: String,
        length: Int,
        slot: Int,
        into slots: inout [SIMD4<Float>]
    ) {
        let components: Int
        switch glslType {
        case "vec2": components = 2
        case "vec3": components = 3
        case "vec4": components = 4
        default: components = 1 // float / int / bool — scalar element, read via `.x`
        }
        let flat = vectorValue(value, count: length * components)
        for i in 0..<length {
            let slotIndex = slot + i
            guard slotIndex < slots.count else { break }
            let base = i * components
            slots[slotIndex] = SIMD4<Float>(
                base < flat.count ? flat[base] : 0,
                components > 1 && base + 1 < flat.count ? flat[base + 1] : 0,
                components > 2 && base + 2 < flat.count ? flat[base + 2] : 0,
                components > 3 && base + 3 < flat.count ? flat[base + 3] : 0
            )
        }
    }

    private static func vectorValue(_ value: WPESceneShaderConstantValue?, count: Int) -> [Float] {
        switch value {
        case .vector(let v):
            var out = v.map(Float.init)
            while out.count < count { out.append(0) }
            return out
        case .animated(let v):
            var out = (v.vector(at: 0) ?? []).map(Float.init)
            while out.count < count { out.append(0) }
            return out
        case .number(let n):
            var out = [Float](repeating: 0, count: count)
            out[0] = Float(n)
            return out
        default:
            return [Float](repeating: 0, count: count)
        }
    }

    /// Texture slots whose bound source is a WPE render target (an FBO/layer
    /// composite or the previous-frame buffer). Those targets already store
    /// premultiplied RGB, so a transpiled straight-alpha shader must
    /// un-premultiply them before running its original math.
    private static func premultipliedInputSlots(for pass: WPEPreparedRenderPass) -> Set<Int> {
        var slots = Set<Int>()
        for slot in 0..<WPEShaderTranspiler.customTextureSlotCount {
            let reference = pass.textureBindings[slot]
                ?? pass.pass.binds[slot]
                ?? pass.pass.textures[slot]
                ?? (slot == 0 ? pass.pass.source : nil)
            if let reference, isPremultipliedRenderTarget(reference) {
                slots.insert(slot)
            }
        }
        return slots
    }

    private static func isPremultipliedRenderTarget(_ reference: WPETextureReference) -> Bool {
        switch reference {
        case .fbo, .previous:
            return true
        case .image, .asset:
            return false
        }
    }

    /// True when the pass targets the premultiplied render-target path, so a
    /// transpiled straight-alpha shader must premultiply its final output.
    private static func usesPremultipliedOutput(blendMode: String) -> Bool {
        blendMode
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .hasPrefix("premultiplied")
    }

    /// Build the deterministic, runtime-independent compile request for a custom-shader
    /// pass — the cheap preprocess half of `compileCustomShader`, factored out so the
    /// off-thread pre-warm computes the IDENTICAL `translationCacheKey` (a load-time warm
    /// then guarantees a first-frame cache hit). Returns nil for built-in / shader-less
    /// passes. `recordFailure` gates the scene-debug artifact so the warm stays silent and
    /// the real first-frame render remains the sole recorder. Static + value-only inputs so
    /// the warm can call it off the main actor without capturing the executor.
    static func makeCompileRequest(
        for pass: WPEPreparedRenderPass,
        recordFailure: Bool
    ) throws -> WPEShaderCompileRequest? {
        guard let program = pass.shader, !program.isBuiltin else { return nil }
        // The null include-resolver is load-bearing: program.*Source is already
        // #include-expanded at graph-build time (WPERenderPipelineBuilder.preprocess),
        // so a real resolver here could diverge the cache key. Keep it nil.
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let premultipliedInputSlots = premultipliedInputSlots(for: pass)
        let premultipliedOutput = usesPremultipliedOutput(blendMode: pass.pass.blending)
        do {
            return try processor.process(
                shaderName: program.name,
                vertexSource: program.vertexSource,
                fragmentSource: program.fragmentSource,
                comboValues: pass.comboValues,
                materialTextureBindings: Dictionary(
                    uniqueKeysWithValues: pass.textureBindings.compactMap { (slot, ref) -> (Int, String)? in
                        switch ref {
                        case .image(let p), .asset(let p): return (slot, p)
                        case .fbo(let n): return (slot, n)
                        case .previous: return nil
                        }
                    }
                )
            ).replacingPremultipliedAlphaSettings(
                inputSlots: premultipliedInputSlots,
                output: premultipliedOutput
            )
        } catch let error as WPEShaderCompilerError {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: program.name,
                    originalVertex: program.vertexSource,
                    processedVertex: nil,
                    originalFragment: program.fragmentSource,
                    processedFragment: nil,
                    translatedMSL: nil,
                    errorText: "preprocess failed: \(String(describing: error))"
                )
            }
            throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                name: program.name,
                reason: String(describing: error)
            )
        }
    }

    func compileCustomShader(
        for pass: WPEPreparedRenderPass
    ) throws -> WPEShaderCompileResult {
        guard let program = pass.shader else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
        // Hot path: a previously-translated pass returns without re-running the
        // GLSL preprocessor (which `makeCompileRequest` would otherwise do every
        // frame just to recompute the content cache key).
        if let cached = compiledShaderResultByPassID[pass.id] {
            return cached
        }
        if let reason = untranslatableShaderReasonByPassID[pass.id] {
            throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(name: program.name, reason: reason)
        }
        do {
            guard let request = try Self.makeCompileRequest(for: pass, recordFailure: true) else {
                throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
            }
            if let cached = translatedShaderCache[request.translationCacheKey] {
                compiledShaderResultByPassID[pass.id] = cached
                return cached
            }
            do {
                let result = try shaderCompiler.compile(request)
                translatedShaderCache[request.translationCacheKey] = result
                compiledShaderResultByPassID[pass.id] = result
                return result
            } catch let error as WPEShaderCompilerError {
                switch error {
                case .glslPreprocessFailed(let reason),
                     .translationFailed(let reason),
                     .mslLibraryFailed(let reason):
                    // The compiler already dumped processed sources; tack on the
                    // pre-preprocess originals so a maintainer can diff to see
                    // exactly which fixup turned the source unparseable.
                    WPESceneDebugArtifacts.shared.recordShaderFailure(
                        shaderName: program.name,
                        originalVertex: program.vertexSource,
                        processedVertex: request.processedVertexSource,
                        originalFragment: program.fragmentSource,
                        processedFragment: request.processedFragmentSource,
                        translatedMSL: nil,
                        errorText: "compile failed: \(reason)"
                    )
                    throw WPEMetalRenderExecutorError.shaderTranslatorUnavailable(
                        name: program.name,
                        reason: reason
                    )
                }
            }
        } catch {
            // Surface every custom-shader failure (preprocess OR compile) in the
            // scene diagnostic log: the WPESceneDebugArtifacts dump above is
            // hard-off in Release, so otherwise the skipped pass is invisible.
            let reason: String
            switch error {
            case WPEMetalRenderExecutorError.shaderTranslatorUnavailable(_, let r): reason = r
            case WPEMetalRenderExecutorError.unsupportedShader: reason = "unsupported shader"
            default: reason = String(describing: error)
            }
            shaderErrorSink.record(shader: program.name, reason: reason)
            throw error
        }
    }
}
#endif
