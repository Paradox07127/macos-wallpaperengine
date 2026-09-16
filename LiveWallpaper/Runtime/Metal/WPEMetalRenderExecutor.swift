#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

extension MTLCommandEncoder {
    /// Autoclosure keeps the string unbuilt while the flag is off.
    func applyTraceLabel(_ makeLabel: @autoclosure () -> String) {
        if WPEMetalRenderExecutor.tracePassLabels { label = makeLabel() }
    }
}

final class WPEMetalRenderExecutor {
    /// Process-only experiment controls. Tests inject a value without changing
    /// the process environment or persistent application preferences.
    struct DiagnosticControls: Equatable, Sendable {
        static let process = DiagnosticControls(environment: ProcessInfo.processInfo.environment)
        let disableParticleBatching: Bool
        let disableSolidBatching: Bool
        let disableFBOAliasing: Bool
        let disableSceneAliasDirectBind: Bool

        init(environment: [String: String] = [:]) {
            disableParticleBatching = environment["WPE_DIAGNOSTIC_DISABLE_PARTICLE_BATCHING"] == "1"
            disableSolidBatching = environment["WPE_DIAGNOSTIC_DISABLE_SOLID_BATCHING"] == "1"
            disableFBOAliasing = environment["WPE_DIAGNOSTIC_DISABLE_FBO_ALIASING"] == "1"
            disableSceneAliasDirectBind = environment["WPE_DIAGNOSTIC_DISABLE_SCENE_ALIAS_DIRECT_BIND"] == "1"
        }
    }

    struct DiagnosticFrameStats {
        let controls: DiagnosticControls
        var particleBatchingEnabled = false
        var solidBatchingEnabled = false
        var sceneQuadBatchingEnabled = false
        var fboAliasingEnabled = false
        var perPassReadbackActive = false
        var particleEncoderCount = 0
        var particleSystemsEncoded = 0
        var plannedAliasIntervalCount = 0
        /// Intervals actually submitted to the pool, not a GPU allocation count.
        var aliasIntervalCount = 0
        var sceneAliasSnapshotBlits = 0
        var sceneAliasDirectBinds = 0
    }

    let diagnosticControls: DiagnosticControls
    private(set) var lastDiagnosticFrameStats = DiagnosticFrameStats(controls: DiagnosticControls())

    /// Instance-only A/B seam; there is no persisted user setting.
    var initialSceneClearElisionEnabled = true
    private(set) var lastInitialSceneClearStats = WPEMetalInitialSceneClearStats()
    var solidSceneBatchingEnabled = true
    var sceneQuadBatchingEnabled = ProcessInfo.processInfo.environment["WPE_SCENE_QUAD_BATCHING"] == "1"
    private(set) var lastSceneQuadBatchStats = WPEMetalSceneQuadBatchStats()
    private(set) var lastSolidSceneBatchStats = (encoders: 0, draws: 0)

    /// Off by default and read once. `defaults write com.loomscreen.pro WPETracePassLabels -bool YES`
    static let tracePassLabels: Bool = {
        let key = "WPETracePassLabels"
        for suite in [UserDefaults.appSuite, UserDefaults.standard] where suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        return false
    }()
    static let outputPixelFormat: MTLPixelFormat = .rgba8Unorm_srgb
    /// `.rgba16Float` for HDR so >1 emissive survives to the bloom prefilter (an 8-bit target clamps at scene write); SDR keeps 8-bit sRGB.
    var currentOutputPixelFormat: MTLPixelFormat = WPEMetalRenderExecutor.outputPixelFormat

    /// `nil` (the default, and always in Release) means decide automatically per puppet. Clip-composite puppets ignore this and never defer.
    static var deferPuppetMeshWarpOverride: Bool? {
        #if DEBUG
        return puppetDefaultsFlagOptional("WPEPuppetDeferMeshWarp")
        #else
        return nil
        #endif
    }

    /// Default ON; opt out with `defaults write com.loomscreen.pro WPEPuppetClipComposite -bool NO`. Only takes effect when the builder injected a clip-mask binding (texture slot 8).
    static let puppetClipCompositeEnabled: Bool = puppetDefaultsFlagOptional("WPEPuppetClipComposite") ?? true

    /// Preserves unset (`nil`). Suite first, then `.standard`.
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

    /// Default OFF so the existing render path stays byte-identical unless explicitly enabled. Read once on first use — restart to apply.
    static let isStaticLayerCacheEnabled: Bool = readStaticLayerCacheEnabled()
    static func readStaticLayerCacheEnabled() -> Bool {
        UserDefaults.standard.object(forKey: staticLayerCacheDefaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: staticLayerCacheDefaultsKey)
    }

    /// VRAM budget for cached composites (MiB; default 256). Over budget → LRU eviction, never wrong.
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

    /// Keyed by `WPEPreparedRenderPass.id`, not by a hash of the preprocessed source — computing that hash means running the GLSL preprocessor every frame.
    var compiledShaderResultByPassID: [String: WPEShaderCompileResult] = [:]

    var frameUniformContext: WPEFrameUniformContext = .empty
    /// Previous logical shader timestamp and its derived delta. A fail-close
    /// frame can call `render` twice with the same timestamp; the second encode
    /// must reuse the first encode's `g_Frametime`, not collapse it to zero.
    private var lastShaderRuntimeTime: Double?
    private(set) var currentShaderFrameTime: Double = 0
    private let objectUniformCache = WPEObjectUniformCache()

    typealias ShaderConstantKeys = Dictionary<String, WPESceneShaderConstantValue>.Keys

    /// Case-insensitive uniform-key index, keyed by pass id. Cleared on reload.
    struct UniformKeyIndex {
        /// The cache identity is the KEY SET, not its size: dropping one key and writing another leaves the count unchanged, freezing a stale index.
        let uniformKeySet: ShaderConstantKeys
        let constantKeySet: ShaderConstantKeys
        /// lowercased → canonical. Case-variant collisions pick one and freeze it.
        let uniformKeys: [String: String]
        let constantsKeys: [String: String]
    }

    private var uniformKeyIndexByPassID: [String: UniformKeyIndex] = [:]

    /// Test seam: cache hit vs silent per-frame rebuild.
    var uniformKeyIndexBuildCount = 0

    func uniformKeyIndex(for pass: WPEPreparedRenderPass) -> UniformKeyIndex {
        if let cached = uniformKeyIndexByPassID[pass.id],
           cached.uniformKeySet == pass.uniformValues.keys,
           cached.constantKeySet == pass.pass.constants.keys {
            return cached
        }
        let index = UniformKeyIndex(
            uniformKeySet: pass.uniformValues.keys,
            constantKeySet: pass.pass.constants.keys,
            uniformKeys: Self.lowercasedKeyMap(pass.uniformValues),
            constantsKeys: Self.lowercasedKeyMap(pass.pass.constants)
        )
        uniformKeyIndexBuildCount += 1
        uniformKeyIndexByPassID[pass.id] = index
        return index
    }

    func invalidateUniformKeyIndexes() {
        uniformKeyIndexByPassID.removeAll()
        uniformKeyIndexBuildCount = 0
    }

    var uniformPlansByPassID: [String: PassUniformPlans] = [:]

    /// Test seam: cache hit vs silent per-frame recompile.
    var uniformPlanCompileCount = 0

    /// Internal A/B seam for byte comparisons and same-binary Release packing benchmarks.
    var derivedUniformPackingEnabled = true

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

    var cachedFBOAliasTopology: FBOAliasTopology?
    /// Test seam: cache hit vs silent rebuild.
    var fboAliasTopologyRebuildCount = 0

    /// One prepared pass can drive several pipeline states; (variant, pass id) names one.
    enum PassPSOVariant: UInt8 {
        case solidColor, solidLayer, blendComposite, blendCompositeFramebufferFetch, copy
        case localSceneCapture, composeLayer, compose
        case genericImage2, genericImage4, godraysCombine, effect
    }

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

    let customTextureSlotScratch = WPEMetalTextureSlotTable()

    /// non-nil only for scenes whose pipeline declares one.
    var mediaTextureStore: WPEMediaTextureStore?

    /// Deliberately not a per-MTLTexture registry: eager sprite frames reuse one atlas texture.
    private var currentTextureSamplingDescriptors: [String: WPETexSpriteSamplingDescriptor] = [:]

    func textureSamplingDescriptor(
        for reference: WPETextureReference
    ) -> WPETexSpriteSamplingDescriptor? {
        switch reference {
        case .image(let path), .asset(let path):
            return currentTextureSamplingDescriptors[path]
        case .fbo, .previous:
            return nil
        }
    }

    private func blendFacts(_ blendMode: String) -> BlendStringFacts {
        if let cached = blendStringFactsCache[blendMode] { return cached }
        let facts = BlendStringFacts(
            lowercased: blendMode.lowercased(),
            requiresExistingDestination: Self.blendModeRequiresExistingDestination(blendMode)
        )
        blendStringFactsCache[blendMode] = facts
        return facts
    }

    /// Keyed by (clampUVs, noInterpolation). Only four combinations exist.
    private var customSamplerStateCache: [Int: MTLSamplerState] = [:]

    /// Unregistered textures and unbound slots fall back to clamp-to-edge + linear — the safe default that never wraps.
    func customShaderSamplerState(for texture: MTLTexture?, useMipmaps: Bool = false) -> MTLSamplerState {
        let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
        return customShaderSamplerState(resolution: resolution, useMipmaps: useMipmaps)
    }

    func customShaderSamplerState(resolution: WPEMetalTextureResolution?, useMipmaps: Bool = false) -> MTLSamplerState {
        let clamp = resolution?.clampUVs ?? true
        let nearest = resolution?.noInterpolation ?? false
        let key = (clamp ? 1 : 0) | (nearest ? 2 : 0) | (useMipmaps ? 4 : 0)
        if let cached = customSamplerStateCache[key] { return cached }
        let descriptor = customShaderSamplerDescriptor(clamp: clamp, nearest: nearest, useMipmaps: useMipmaps)
        // Force-unwrap matches the executor's other GPU-object creation: a valid
        // descriptor never fails to produce a sampler state on a live device.
        let state = device.makeSamplerState(descriptor: descriptor)!
        customSamplerStateCache[key] = state
        return state
    }

    func customShaderSamplerDescriptor(clamp: Bool, nearest: Bool, useMipmaps: Bool = false) -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = nearest ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        if useMipmaps || WPEMetalTextureLoader.allowsMipFiltering, !nearest {
            // Default `.notMipmapped` samples level 0 only. Nearest (noInterpolation) textures stay level-0-only: a fractional LOD would blend adjacent mips' entries.
            descriptor.mipFilter = .linear
        }
        let address: MTLSamplerAddressMode = clamp ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        return descriptor
    }

    #if !LITE_BUILD && DEBUG
    func customShaderSamplerDescription(for texture: MTLTexture?) -> [String: String] {
        let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
        return customShaderSamplerDescription(resolution: resolution)
    }

    func customShaderSamplerDescription(resolution: WPEMetalTextureResolution?) -> [String: String] {
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

    func seedTranslatedShaderCache(_ entries: [(key: String, result: WPEShaderCompileResult)]) {
        for entry in entries where translatedShaderCache[entry.key] == nil {
            translatedShaderCache[entry.key] = entry.result
        }
    }

    func seedCompiledShaderResultsByPassID(
        _ entries: [(passID: String, result: WPEShaderCompileResult)]
    ) {
        for entry in entries where compiledShaderResultByPassID[entry.passID] == nil {
            compiledShaderResultByPassID[entry.passID] = entry.result
        }
    }

    /// Pipeline keys include `MTLLibrary` identity, so recompiling an already-cached shader would build an unreachable PSO for a throwaway library.
    func partitionTranslatedShaderPrewarmRequests(
        _ requests: [WPEShaderCompileRequest]
    ) -> (
        cached: [(key: String, result: WPEShaderCompileResult)],
        missing: [WPEShaderCompileRequest]
    ) {
        var cached: [(key: String, result: WPEShaderCompileResult)] = []
        var missing: [WPEShaderCompileRequest] = []
        cached.reserveCapacity(requests.count)
        missing.reserveCapacity(requests.count)
        for request in requests {
            let key = request.translationCacheKey
            if let result = translatedShaderCache[key] {
                cached.append((key: key, result: result))
            } else {
                missing.append(request)
            }
        }
        return (cached: cached, missing: missing)
    }
    private var translatedPipelineCache: [TranslatedPipelineKey: MTLRenderPipelineState] = [:]
    var previousFrameHistory: PreviousFrameHistory?
    /// Clip-composite role detection depends on the object's animation layers, so cache the resolved
    /// (source→target) part pairs per `objectID` (empty array = clip puppet with no eligible pair).
    var puppetClipPairsCache: [String: [PuppetClipPair]] = [:]
    /// Throttles the one-shot clip-activation diagnostic to once per objectID.
    var loggedClipActivation: Set<String> = []
    /// One-shot per object: the clip composite was asked for but declined (see `puppetClipCompositePlan`).
    var loggedClipBail: Set<String> = []
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
    var untranslatableShaderReasonByPassID: [String: String] = [:]

    /// Reused only when (a) no async present of it is still in flight and (b) it isn't among the most recently vended outputs (`maxFramesInFlight`, min 2).
    var outputTexturePool: [MTLTexture] = []
    /// The most recently vended output textures (newest last); retained count is
    /// `max(2, maxFramesInFlight)` — see `noteVendedOutputTexture`.
    var recentOutputTextureIDs: [ObjectIdentifier] = []
    let presentTracker = PresentInFlightTracker()
    let gpuErrorSink = WPEGPUErrorSink()
    let shaderErrorSink = WPEShaderErrorSink()
    /// MUST equal the `recentOutputTextureIDs` retention: a vended output stays out of the reuse set for exactly that many vends.
    static let maxFramesInFlight = 2
    private let frameSubmissionPool = WPEMetalFrameSubmissionPool(
        slotCount: WPEMetalRenderExecutor.maxFramesInFlight
    )
    private(set) lazy var uniformArena = WPEMetalUniformArena(
        device: device, slotCount: Self.maxFramesInFlight
    )
    /// Nil whenever the caller passed no lease — those callers keep the per-pass allocation path.
    var currentUniformArenaSlot: Int?
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    /// True: `render()` and text passes block on GPU completion. False: frames submit async and the CPU stalls only via `inFlightSemaphore`.
    var synchronizeFrameCompletion = true
    #if DEBUG
    /// Test seam: remaining `encodePresent` calls that skip `nextDrawable()`.
    var remainingForcedDrawableMissesForTesting = 0
    #endif

    func beginFrameSubmission() throws -> WPEMetalFrameSubmissionLease {
        guard let submission = frameSubmissionPool.tryAcquire() else {
            throw WPEMetalFrameInFlightBudgetExhausted()
        }
        return submission
    }
    /// Cleared `.previous` bootstrap textures, one per (target, size, format).
    /// Cross-buffer reuse requires a successful clear completion; encoding a
    /// clear in an abandoned/failed buffer does not publish initialized data.
    var bootstrapPreviousTextureCache: [BootstrapPreviousKey: WPEMetalBootstrapTexture] = [:]
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

    /// `enabled` is false (and `palette` empty) whenever the validation gate rejects skinning, so the pass renders the static assembled mesh.
    struct PuppetSkinningState {
        let enabled: Bool
        let palette: [simd_float4x4]
        let attachmentsByName: [String: WPEPuppetAttachment]
        /// RAW MDLS bind-world per bone — the basis the palette (`current · rawBind⁻¹`) was built on, so `palette · (rawBind · MDAT)` recovers the anchor's CURRENT world position.
        let boneBindByIndex: [Int: simd_float4x4]
        /// ASSEMBLED bind-world per bone: frame-0 pose for character-sheet puppets (raw MDLS is the exploded sheet), raw bind for pre-assembled. Follow adds only the animated `current − rest` delta.
        let assembledBoneBindByIndex: [Int: simd_float4x4]
        let reason: String
    }

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

    init(device: MTLDevice, diagnosticControls: DiagnosticControls = .process) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        self.diagnosticControls = diagnosticControls
        device.shouldMaximizeConcurrentCompilation = true
        commandQueue = queue
        defaultLibrary = library
        self.targetPool = WPEMetalRenderTargetPool(device: device)
        self.depthCache = WPEMetalDepthStateCache(device: device)
        self.pipelineCache = WPEMetalPipelineCache(device: device, library: library)
        self.shaderCompiler = WPESwiftShaderCompiler(device: device)
    }

    var textureSourceDevice: MTLDevice {
        device
    }

    var textureSourceCommandQueue: MTLCommandQueue {
        commandQueue
    }

    private var stagedTextureWork: [any WPEDynamicTextureSource] = []

    func stageTextureWork(_ sources: [any WPEDynamicTextureSource]) {
        stagedTextureWork = sources
    }

    var loggedWaterWavesDispatch = false
    private(set) var currentSceneSize: CGSize = .zero

    /// `.inactive` until planned, so an executor that is never planned renders at full resolution — the pre-feature path, bit for bit.
    var upscalePlan: WPEMetalUpscalePlan = .inactive
    var lastPresentedDrawableSize: CGSize = .zero
    /// Cumulative seconds spent acquiring drawables, confined to the render actor.
    var drawableAcquisitionSeconds: TimeInterval = 0
    /// Drain at the end of the same frame — NOT at the demote site — so the pixel-keyed purge happens after the command buffer is committed rather than between encode and commit.
    private var presentSideDemotionPending = false

    /// One-shot: true exactly once per present-side demote.
    func takePresentSideDemotion() -> Bool {
        defer { presentSideDemotionPending = false }
        return presentSideDemotionPending
    }

    func notePresentSideDemotion() { presentSideDemotionPending = true }
    /// Resolution of the FBO chain's head, which `g_TexelSize`, `g_TexelSizeHalf`, and `g_Screen` must describe. WPE feeds head-resolution-derived globals to every pass of the chain.
    private(set) var currentScenePixelSize: CGSize = .zero

    /// `g_TexelSize` is derived from this rather than from any dictionary, so without a way to set it a characterization test can only chain the helpers.
    func setCurrentScenePixelSizeForTesting(_ size: CGSize) {
        currentScenePixelSize = size
    }

    // Not "parents anything": a composite-only child never reaches the scene, so its parent stays a real sub-rect box.
    private var groupingContainerObjectIDs: Set<String> = []
    /// WPE shifts a parented subtree by ONE offset — the root's — so a child must evaluate the static `(nodePos - camPos)` term at its root's origin, never at its own.
    var parallaxRootCenterByObjectID: [String: SIMD2<Float>] = [:]
    var parallaxObjectParentByID: [String: String] = [:]
    var parallaxHostDepthByObjectID: [String: SIMD2<Double>] = [:]
    var parallaxHostOriginByObjectID: [String: SIMD2<Double>] = [:]
    /// Logical targets rendered by >1 depth-using pass keep persistent depth rather than transient/memoryless.
    private var persistentDepthTargetIDs: Set<WPEMetalTargetID> = []

    #if DEBUG
    private(set) var scenePassDumps: [(label: String, texture: MTLTexture)] = []
    private var dumpLayerPassesID: String?
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
        textureSamplingDescriptors: [String: WPETexSpriteSamplingDescriptor] = [:],
        dynamicTextureNames: Set<String> = [],
        dynamicLayerIDs: Set<String> = [],
        runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        /// Merged over the authored values; empty for every scene without a bound script.
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [:],
        /// A missing entry falls back to the gate's authored seed; empty for every scene without a script-gated effect.
        passVisibility: [String: Bool] = [:],
        sceneID: String? = nil,
        particleSystems: [WPEParticleSystem] = [],
        particleTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:],
        particleParallax: WPECameraParallaxFrame = .neutral,
        textPayloads: [String: WPETextRenderPayload] = [:],
        frameSubmission: WPEMetalFrameSubmissionLease? = nil,
        frameProduction: WPEMetalFrameProductionCompletion? = nil,
        colorCorrection: WPEEngineColorCorrection = .neutral,
        /// Encode present into this scene command buffer. Nil on sync/readback.
        deferredPresent: DeferredPresentEncoder? = nil
    ) throws -> MTLTexture {
        var diagnostics = DiagnosticFrameStats(controls: diagnosticControls)
        diagnostics.particleBatchingEnabled = !diagnosticControls.disableParticleBatching
        diagnostics.solidBatchingEnabled = solidSceneBatchingEnabled && !diagnosticControls.disableSolidBatching
        diagnostics.sceneQuadBatchingEnabled = sceneQuadBatchingEnabled
        diagnostics.fboAliasingEnabled = !diagnosticControls.disableFBOAliasing
        defer { lastDiagnosticFrameStats = diagnostics }
        currentTextureSamplingDescriptors = textureSamplingDescriptors
        defer { currentTextureSamplingDescriptors.removeAll(keepingCapacity: true) }
        let asyncSubmission = !synchronizeFrameCompletion
        let stagedTextureWork = self.stagedTextureWork
        self.stagedTextureWork = []
        // Retain the historical semaphore only for callers that have not migrated to that lease; applying both budgets can reject a legitimate second buffer in the same fail-close frame.
        let usesLegacyCommandBufferBudget = asyncSubmission && frameSubmission == nil
        if usesLegacyCommandBufferBudget {
            // Poll, don't block: a blocking wait would stall this display's frame loop — and in `.main` backing mode the shared main thread.
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
        if let frameSubmission {
            uniformArena.beginFrame(slot: frameSubmission.slot)
            currentUniformArenaSlot = frameSubmission.slot
        }
        defer { currentUniformArenaSlot = nil }
        #if DEBUG
        scenePassDumps.removeAll()
        let dumpScenePasses = (sceneID.map { !$0.isEmpty && dumpScenePassesDefaultID == $0 } ?? false)
            || WPEOracleMode.perPassHashesEnabled
        dumpLayerPassesID = dumpLayerPassesDefaultID
        diagnostics.perPassReadbackActive = dumpScenePasses
        diagnostics.particleBatchingEnabled = diagnostics.particleBatchingEnabled && !dumpScenePasses
        diagnostics.solidBatchingEnabled = diagnostics.solidBatchingEnabled && !dumpScenePasses
        diagnostics.sceneQuadBatchingEnabled = diagnostics.sceneQuadBatchingEnabled && !dumpScenePasses
        #endif
        var shaderRuntimeUniforms = runtimeUniforms
        shaderRuntimeUniforms.frameTime = advanceShaderFrameTime(runtimeTime: runtimeUniforms.time)
        let (preparedPipeline, frameUniforms) = pipeline.addingMetalRuntimeUniforms(
            shaderRuntimeUniforms,
            camera: cameraUniforms,
            scriptedConstants: scriptedConstants,
            objectUniformCache: objectUniformCache
        )
        frameUniformContext = frameUniforms
        defer { frameUniformContext = .empty }
        currentOutputPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : Self.outputPixelFormat
        targetPool.promotesLDRFormatsToHDR = cameraUniforms.sceneHDR
        // ONE pixel scale for the whole frame: scene output, every pool target and the alias plan must shrink together or `copyTexture` blits mismatched extents. `size` stays WORLD-sized; only allocations and g_TexelSize go through the scaled-canvas conversion.
        let outputPixelScale = upscalePlan.renderPixelScale
        targetPool.pixelScale = outputPixelScale
        let outputPixelSize = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            size, pixelScale: outputPixelScale
        )
        currentScenePixelSize = outputPixelSize
        let output = try makeOutputTexture(size: outputPixelSize)
        let staticLayerCacheEnabled = Self.isStaticLayerCacheEnabled
        if staticLayerCacheEnabled {
            staticLayerCompositeCache.updateBudget(Self.staticLayerCacheBudgetBytes)
            staticLayerCompositeCache.setOutputFormat(currentOutputPixelFormat)
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
        defer {
            if staticLayerCacheEnabled { staticLayerCompositeCache.discardUnsubmittedWork(for: commandBuffer) }
            discardUnsubmittedBootstrapTextures(for: commandBuffer)
        }
        WPEFrameOccupancyMeter.count(.sceneCommandBuffer)
        // Video conversions first: they write textures the scene passes below sample, and same-buffer order is what guarantees write-before-read.
        var didPublishStagedTextureWork = stagedTextureWork.isEmpty
        for source in stagedTextureWork {
            source.encodeStagedFrameWork(into: commandBuffer)
        }
        func publishStagedTextureWork() {
            guard !didPublishStagedTextureWork else { return }
            didPublishStagedTextureWork = true
            for source in stagedTextureWork {
                source.commitStagedFrameWork()
            }
        }
        defer {
            if !didPublishStagedTextureWork {
                for source in stagedTextureWork {
                    source.rollbackStagedFrameWork()
                }
            }
        }

        let reusableHistory: PreviousFrameHistory?
        if let history = previousFrameHistory, history.sceneSize == size {
            reusableHistory = history
        } else {
            reusableHistory = nil
            previousFrameHistory = nil
        }

        // Aliasing is disabled while the debug bypass path is active — bypass skips a layer's passes, which would break the lockstep pass index the alias plan relies on.
        let plannedAliasIntervals = fboAliasIntervals(pipeline: preparedPipeline, sceneSize: size)
        let aliasIntervals = diagnosticControls.disableFBOAliasing ? [] : plannedAliasIntervals
        diagnostics.plannedAliasIntervalCount = plannedAliasIntervals.count
        diagnostics.aliasIntervalCount = aliasIntervals.count
        targetPool.prepare(
            pipeline: preparedPipeline,
            aliasIntervals: aliasIntervals,
            pipelineIdentity: fboAliasTopologyRebuildCount
        )
        targetPool.beginAliasFrame()
        // The per-frame output texture is `.private` and NOT zeroed by Metal. A scene-alias read before any scene-target pass writes would sample this garbage. Clear to the scene clear color so any pre-write alias read sees black.
        var initialClearStats = initialSceneClearPlan(
            pipeline: preparedPipeline, textures: textures, output: output,
            liveParticleSortIndices: particleSystems.lazy.filter { $0.liveInstanceCount > 0 }.map(\.sortIndex),
            hasFirstLayerTextPayload: preparedPipeline.layers.first.map { textPayloads[$0.graphLayer.objectID] != nil } ?? false,
            staticCacheEnabled: staticLayerCacheEnabled
        )
        var initialClearPending = initialClearStats.passID != nil
        defer { lastInitialSceneClearStats = initialClearStats }
        if !initialClearPending {
            try clearTexture(output, color: clearColor(for: .scene), commandBuffer: commandBuffer)
        }
        var frameState = WPEMetalFrameState(
            output: output,
            sceneSize: size,
            cameraUniforms: cameraUniforms,
            previousSceneTexture: reusableHistory?.sceneTexture,
            previousNamedTextures: reusableHistory?.namedTextures ?? [:],
            renderTargetPool: targetPool
        )
        frameState.cameraParallax = runtimeUniforms.cameraParallax
        defer {
            diagnostics.sceneAliasSnapshotBlits = frameState.sceneAliasSnapshotBlits
            diagnostics.sceneAliasDirectBinds = frameState.sceneAliasDirectBinds
        }
        currentSceneSize = size
        groupingContainerObjectIDs = preparedPipeline.layers.reduce(into: Set<String>()) { parents, layer in
            guard let parentID = layer.graphLayer.parentObjectID,
                  layer.graphLayer.passes.contains(where: { $0.target == .scene })
            else { return }
            parents.insert(parentID)
        }
        parallaxRootCenterByObjectID = Self.parallaxRootCenters(
            for: preparedPipeline.layers.lazy.map(\.graphLayer),
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

        let solidRun = WPEMetalSolidSceneRun { [targetPool] in targetPool.endPass(passIndex: $0) }
        var quadStats = WPEMetalSceneQuadBatchStats()
        defer {
            solidRun.end()
            lastSolidSceneBatchStats = (solidRun.encoderCount, solidRun.drawCount)
            quadStats.encoders = solidRun.encoderCount
            quadStats.draws = solidRun.drawCount
            quadStats.texturedDraws = solidRun.texturedDrawCount
            lastSceneQuadBatchStats = quadStats
        }
        func finishInitialSceneClear() throws {
            guard initialClearPending else { return }
            if frameState.hasInitialized(output) {
                initialClearStats.skipped = 1
            } else {
                solidRun.end()
                try clearTexture(output, color: clearColor(for: .scene), commandBuffer: commandBuffer)
                initialClearStats.fallback = 1
            }
            initialClearPending = false
        }
        // A particle with sortIndex P draws after every layer with a lower sortIndex and before any higher one.
        let sortedParticles = particleSystems.enumerated()
            .filter { $0.element.liveInstanceCount > 0 }
            .sorted { lhs, rhs in
                lhs.element.sortIndex != rhs.element.sortIndex
                    ? lhs.element.sortIndex < rhs.element.sortIndex
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        var particleCursor = 0
        // Refract systems need a pre-draw blit snapshot (no open encoder allowed) and DEBUG per-pass dumping needs a boundary per system, so both end the run and render standalone.
        func flushParticles(before threshold: Int) throws {
            if particleCursor < sortedParticles.count, sortedParticles[particleCursor].sortIndex < threshold {
                solidRun.end()
            }
            var particleRunEncoder: MTLRenderCommandEncoder?
            func endParticleRun() {
                guard let encoder = particleRunEncoder else { return }
                encoder.endEncoding()
                particleRunEncoder = nil
                frameState.registerWrite(texture: output, targetID: .scene)
            }
            // Close the run on EVERY exit — a thrown failure mid-run must not leak an open encoder (Metal validation asserts).
            defer { endParticleRun() }
            while particleCursor < sortedParticles.count,
                  sortedParticles[particleCursor].sortIndex < threshold {
                let system = sortedParticles[particleCursor]
                let traceIndex = particleCursor
                particleCursor += 1

                let isRefractSystem = !system.usesRibbonGeometry
                    && particleNormalTextures[ObjectIdentifier(system)] != nil
                #if DEBUG
                let standalone = isRefractSystem || dumpScenePasses || diagnosticControls.disableParticleBatching
                #else
                let standalone = isRefractSystem || diagnosticControls.disableParticleBatching
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
                        diagnostics.particleSystemsEncoded += 1
                        diagnostics.particleEncoderCount += 1
                        #if DEBUG
                        // Label MUST equal the trace passId `recordParticlePass` emits (`particle.<traceIndex>`); the old `.<sortIndex>.` form never matched.
                        captureScenePassIfDumping(dumpScenePasses, label: "particle.\(traceIndex)", output: output, commandBuffer: commandBuffer)
                        #endif
                    }
                    continue
                }

                let encoder = try particleRunEncoder
                    ?? makeParticleOutputEncoder(output: output, commandBuffer: commandBuffer)
                if particleRunEncoder == nil { diagnostics.particleEncoderCount += 1 }
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
                    diagnostics.particleSystemsEncoded += 1
                }
            }
        }

        // Flattened pass index for FBO aliasing — MUST advance in lockstep with the same `for layer { for pass in layer.passes }` order the alias plan used.
        var aliasPassCounter = 0
        for (layerIndex, layer) in preparedPipeline.layers.enumerated() {
            if layerIndex > 0 { try finishInitialSceneClear() }
            let solidEligible = WPEMetalSolidSceneRun.accepts(layer)
            let allowsSceneSharing = !(solidEligible && diagnosticControls.disableSolidBatching)
            var batchesSolid = diagnostics.solidBatchingEnabled && solidEligible
            if sceneQuadBatchingEnabled && allowsSceneSharing && !staticLayerCacheEnabled && !batchesSolid {
                let hasMedia = layer.passes.first.map {
                    mediaTextureStore?.declarations(forPassID: $0.pass.id) != nil
                } ?? false
                batchesSolid = WPEMetalSolidSceneRun.texturedRejectionReason(
                    layer, textures: textures, output: output, hasMediaSubstitution: hasMedia
                ) == nil
            }
            #if DEBUG
            batchesSolid = batchesSolid && !dumpScenePasses
                && dumpLayerPassesID != layer.graphLayer.objectID
            #endif
            if !batchesSolid { solidRun.end() }
            try flushParticles(before: layer.graphLayer.sortIndex)
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
                    requiredTargets: Set(plan.cachedTargets.keys),
                    commandBuffer: commandBuffer
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
            var pendingStaticSnapshots: [String: MTLTexture] = [:]
            var pendingStaticBytes = 0
            frameState.layerEntrySceneWriteGeneration = frameState.sceneWriteGeneration
            let graphLayer = layerApplyingAttachmentFollow(layer.graphLayer, context: attachmentContext)
            let skinningState = attachmentContext.skinningByObjectID[layer.graphLayer.objectID]
            if layer.passes.isEmpty {
                // Hidden plain-image layer: skip the scene blit. `didEncode` stays satisfied so an all-hidden scene renders empty instead of erroring.
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
                // Advance the alias index for EVERY pass (defer fires endPass at iteration exit, including the hidden-pass `continue`).
                let passAliasIndex = aliasPassCounter
                aliasPassCounter += 1
                var sharesSceneEncoder = false
                defer {
                    if sharesSceneEncoder, solidRun.encoder != nil {
                        solidRun.deferEndPass(passAliasIndex)
                    } else {
                        targetPool.endPass(passIndex: passAliasIndex)
                    }
                }
                // Hidden layer: still encode passes that write a composite/FBO, but skip the final scene draw and group-buffer writes (`_rt_layerGroup_*`).
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
                // While the gate is closed the effect must not alter a pixel, so the pass hands its input straight to its target.
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
                if cachedStaticLayer != nil {
                    switch pass.pass.target {
                    case .scene:
                        break
                    case .layerComposite, .fbo:
                        didEncode = true
                        continue
                    }
                }
                sharesSceneEncoder = batchesSolid
                if sceneQuadBatchingEnabled && allowsSceneSharing && !staticLayerCacheEnabled && !sharesSceneEncoder {
                    let finalCopy = layerPassIndex == layer.passes.count - 1
                        && WPEBuiltinShaderKind(normalizing: pass.pass.shader) == .copy
                    let reason = WPEMetalSolidSceneRun.texturedRejectionReason(
                        layer, textures: textures, output: output,
                        hasMediaSubstitution: mediaTextureStore?.declarations(forPassID: pass.pass.id) != nil,
                        finalCopyPass: finalCopy ? pass : nil, frameState: frameState
                    )
                    sharesSceneEncoder = reason == nil
                    if let reason { quadStats.rejectedPasses[reason, default: 0] += 1 }
                }
                #if DEBUG
                sharesSceneEncoder = sharesSceneEncoder && !dumpScenePasses
                    && dumpLayerPassesID != layer.graphLayer.objectID
                #endif
                if !sharesSceneEncoder { solidRun.end() }
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
                        frameState: &frameState,
                        solidRun: sharesSceneEncoder ? solidRun : nil
                    )
                } catch let error as WPEMetalRenderExecutorError where error.untranslatableShaderReason != nil {
                    // The pass opened (and therefore cleared) its render target before the shader failed, and `encode` published that cleared texture, so a downstream pass sampling it reads transparent black instead of failing the scene.
                    try finishInitialSceneClear()
                    let reason = error.untranslatableShaderReason ?? ""
                    if untranslatableShaderReasonByPassID.updateValue(reason, forKey: pass.id) == nil {
                        Logger.warning(
                            "WPE pass \(pass.pass.id) (\(pass.pass.shader)) skipped its draw: \(reason)"
                                + " — target \(pass.pass.target) keeps its cleared contents.",
                            category: .wpeRender
                        )
                    }
                    skippedShaderError = skippedShaderError ?? error
                    continue
                }
                didEncode = true
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
                    let dumpTarget: MTLTexture?
                    switch pass.pass.target {
                    case .scene:
                        dumpTarget = output
                    case .layerComposite(let name), .fbo(let name):
                        // Use the texture the pass ACTUALLY wrote to (FBO pooling/aliasing means re-resolving the name by `targetTexture` can vend a different/cleared one).
                        dumpTarget = frameState.latestNamedTextures[name]
                    }
                    if let dumpTarget {
                        captureScenePassIfDumping(dumpScenePasses, label: pass.pass.id, output: dumpTarget, commandBuffer: commandBuffer)
                    }
                }
                #endif
            }
        }

        solidRun.end()
        try finishInitialSceneClear()
        try flushParticles(before: Int.max)

        guard didEncode else {
            throw skippedShaderError ?? WPEMetalRenderExecutorError.noRenderablePasses
        }

        try encodeSceneBloomIfNeeded(
            cameraUniforms: cameraUniforms,
            output: output,
            commandBuffer: commandBuffer
        )
        // Last, so it grades the finished frame — bloom included — the way Wallpaper Engine's own correction sits after the scene, not inside it.
        let graded = try encodeColorCorrectionIfNeeded(
            colorCorrection, output: output, commandBuffer: commandBuffer
        )

        if asyncSubmission, let deferredPresent {
            _ = try deferredPresent(graded, commandBuffer)
        }

        recyclePaletteBuffersOnCompletion(of: commandBuffer)
        // Pin this frame's arena regions until the GPU is done reading them. Must be registered before `commit()` — the last moment Metal accepts a handler.
        if let frameSlot = currentUniformArenaSlot {
            uniformArena.trackSubmission(of: commandBuffer, frameSlot: frameSlot)
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
            let semaphore = usesLegacyCommandBufferBudget ? inFlightSemaphore : nil
            let sink = gpuErrorSink
            commandBuffer.addCompletedHandler { cb in
                semaphore?.signal()
                if cb.status == .error {
                    let detail = cb.error?.localizedDescription ?? "unknown"
                    let n = sink.record("async-frame: \(detail)")
                    if WPEGPUErrorSink.shouldLogOccurrence(n) {
                        Logger.warning(
                            "[WPE async-frame] command buffer error (#\(n)): \(detail)",
                            category: .wpeRender
                        )
                    }
                }
            }
            commandBuffer.commit()
            publishStagedTextureWork()
            didCommitAsync = true
        } else {
            commandBuffer.commit()
            publishStagedTextureWork()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status == .error {
                gpuErrorSink.record("frame: \(commandBuffer.error?.localizedDescription ?? "unknown")")
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
        }
        previousFrameHistory = PreviousFrameHistory(
            sceneSize: size,
            sceneTexture: frameState.latestSceneTexture,
            // Never carry named FBOs across frames. A precise "carry only `.previous`-read targets" filter was tried and REGRESSED: effect-bind `{name:"previous"}` lowers to the SAME `.previous` token as true cross-frame feedback.
            namedTextures: [:]
        )
        return graded
    }

    /// Slots are assigned sequentially, so the max `slot + slotCount` is the total.
    static func translatedSlotCount(for layout: [WPEUniformSlot]) -> Int {
        max(layout.reduce(0) { Swift.max($0, $1.slot + $1.slotCount) }, 1)
    }

    /// `.allocationFailed` used to be unrepresentable: the `>4 KB` branch was an `else if let` with no `else`, so a failed allocation left the slot unbound and silent.
    enum TranslatedUniformBinding: Equatable {
        case empty
        case inline(byteCount: Int)
        case buffer(byteCount: Int)
        case allocationFailed(byteCount: Int)
    }

    /// macOS caps `setFragmentBytes` at 4 KB (256 × 16-byte slots). Shaders under that ride the inline fast path; above it bind a transient shared buffer.
    @discardableResult
    func bindTranslatedUniformSlots(
        _ slots: [SIMD4<Float>],
        to encoder: MTLRenderCommandEncoder,
        index: Int = 0,
        allocate: ((UnsafeRawPointer, Int) -> MTLBuffer?)? = nil
    ) -> TranslatedUniformBinding {
        guard !slots.isEmpty else { return .empty }
        let byteCount = MemoryLayout<SIMD4<Float>>.stride * slots.count
        if byteCount <= 4096 {
            var inline = slots
            encoder.setFragmentBytes(&inline, length: byteCount, index: index)
            return .inline(byteCount: byteCount)
        }
        let buffer = slots.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            if let allocate { return allocate(base, byteCount) }
            return device.makeBuffer(bytes: base, length: byteCount, options: .storageModeShared)
        }
        guard let buffer else {
            // Nothing correct is left to bind: >4 KB cannot ride `setFragmentBytes`, and a zero-filled stand-in needs the allocation that just failed.
            let n = gpuErrorSink.record("uniform-buffer: \(byteCount) bytes (\(slots.count) slots)")
            if WPEGPUErrorSink.shouldLogOccurrence(n) {
                Logger.warning(
                    "[WPE uniforms] uniform buffer allocation failed (#\(n)): "
                        + "\(byteCount) bytes, \(slots.count) slots — this pass draws with undefined uniforms",
                    category: .wpeRender
                )
            }
            return .allocationFailed(byteCount: byteCount)
        }
        WPEFrameOccupancyMeter.count(.largeUniformBufferCreate)
        encoder.setFragmentBuffer(buffer, offset: 0, index: index)
        return .buffer(byteCount: byteCount)
    }

    /// Where a pass's packed uniform slots live between packing and binding.
    enum PackedTranslatedUniforms {
        case empty
        /// Written straight into this frame's arena slot — no per-pass allocation.
        case arena(WPEMetalUniformArena.Region)
        /// Pre-arena storage: no frame lease this frame, or the arena had no room.
        case array([SIMD4<Float>])

        var isEmpty: Bool {
            switch self {
            case .empty: true
            case .arena(let region): region.storage.isEmpty
            case .array(let slots): slots.isEmpty
            }
        }

        /// Copies the slots out. DEBUG trace recording only — the frame path binds
        /// from the packed storage and never materializes an array.
        func slotsForTracing() -> [SIMD4<Float>] {
            switch self {
            case .empty: []
            case .arena(let region): Array(region.storage)
            case .array(let slots): slots
            }
        }
    }

    func packTranslatedUniformsForBinding(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: WPEMetalTextureSlotTable? = nil
    ) throws -> PackedTranslatedUniforms {
        guard !layout.isEmpty else { return .empty }
        if let frameSlot = currentUniformArenaSlot,
           let region = uniformArena.reserve(
               slotCount: Self.translatedSlotCount(for: layout), frameSlot: frameSlot
           ) {
            try packTranslatedUniformSlots(
                for: pass, layout: layout, texturesBySlot: texturesBySlot, into: region.storage
            )
            return .arena(region)
        }
        return .array(
            try packTranslatedUniforms(for: pass, layout: layout, texturesBySlot: texturesBySlot)
        )
    }

    /// Under the cap `setFragmentBytes` copies into the command buffer's own argument storage; over the cap the arena buffer is bound in place.
    @discardableResult
    func bindTranslatedUniformSlots(
        _ packed: PackedTranslatedUniforms,
        to encoder: MTLRenderCommandEncoder,
        index: Int = 0
    ) -> TranslatedUniformBinding {
        switch packed {
        case .empty:
            return .empty
        case .array(let slots):
            return bindTranslatedUniformSlots(slots, to: encoder, index: index)
        case .arena(let region):
            let byteCount = region.byteCount
            guard byteCount > 0, let base = region.storage.baseAddress else { return .empty }
            if byteCount <= 4096 {
                encoder.setFragmentBytes(base, length: byteCount, index: index)
                return .inline(byteCount: byteCount)
            }
            encoder.setFragmentBuffer(region.buffer, offset: region.offset, index: index)
            return .buffer(byteCount: byteCount)
        }
    }

    var textGlyphPipelineCache: [UInt: MTLRenderPipelineState] = [:]
    var textBackgroundPipelineCache: [UInt: MTLRenderPipelineState] = [:]

    var particlePipelineCache: [ParticlePipelineKey: MTLRenderPipelineState] = [:]
    var refractionBackground: MTLTexture?

    /// A ping-pong composite's physical texture is reused across passes, so a later source-over pass writing the SAME named target would otherwise blend over an earlier pass's stale result. Only load when genuinely needed.
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
        frameState: inout WPEMetalFrameState,
        solidRun: WPEMetalSolidSceneRun? = nil
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
            // WORLD canvas for glyph-vertex normalization: under render scaling the destination texture is `pixelScale` smaller than the canvas, and normalizing by its dimensions would blow the text up by 1/pixelScale.
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

        let fetchSceneColor = puppetModel == nil && WPEMetalShaderInputs.canFetchSceneColor(
            pass: pass, layer: drawLayer, destination: destination.texture,
            textures: textures, frameState: frameState
        )
        if !fetchSceneColor {
            try snapshotFullFrameBufferIfAliasingScene(
                pass: pass, destinationTexture: destination.texture, layer: layer,
                commandBuffer: commandBuffer, frameState: &frameState
            )
        }

        // Blit + mipmap generation need their own encoder, so the capture has to
        // happen here, before this pass opens its render encoder.
        try captureReflectionSourceIfNeeded(
            pass: pass,
            layer: layer,
            commandBuffer: commandBuffer,
            frameState: frameState
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

        // A pass reading `.previous` while ALSO targeting the scene would bind `.previous` to the SAME live `output` it's drawing into, an undefined GPU read-write. Snapshot the scene-so-far into a scratch and rebind `.previous` to it.
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
                commandBuffer: commandBuffer,
                traceLabel: "feedback-init|\(pass.pass.id)"
            )
            frameState.markInitialized(destination.texture)
        }

        let needsDepth = depthCache.needsAttachment(for: pass)
        // WPE's perspective projection is reversed-Z. An otherwise orthographic scene gets it too for objects that author `perspective: true`.
        let usesReversedZ = frameState.cameraUniforms.usesPerspectiveProjection
            || frameState.cameraUniforms.usesObjectPerspective(objectID: drawLayer.objectID)

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

        // Sharing requires this exact physical attachment and preservation of its
        // current contents. A target label alone cannot establish either fact.
        if let solidRun, solidRun.encoder != nil,
           solidRun.destinationTexture !== destination.texture || !shouldLoadExistingAttachment || needsDepth {
            solidRun.end()
        }
        let encoder: MTLRenderCommandEncoder
        if let sharedEncoder = solidRun?.encoder {
            encoder = sharedEncoder
        } else {
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
                    // Depth is keyed independently of the color target and allocated fresh on first use per frame, so the color's `shouldLoadExistingAttachment` must NOT decide it. `.load` only once this exact depth texture was written this frame.
                    let depthInitialized = frameState.hasInitialized(depth)
                    descriptor.depthAttachment.loadAction = depthInitialized ? .load : .clear
                    descriptor.depthAttachment.storeAction = .store
                    frameState.markInitialized(depth)
                }
                descriptor.depthAttachment.clearDepth = WPEMetalDepthStateCache.clearDepth(
                    reversedZ: usesReversedZ
                )
            }

            gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "\(pass.pass.id)|\(pass.pass.shader)")
            guard let createdEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
            encoder = createdEncoder
            encoder.applyTraceLabel("pass|\(pass.pass.id)|\(pass.pass.shader)")
            WPEFrameOccupancyMeter.count(.renderPassEncoder)

            if let solidRun {
                solidRun.encoder = encoder
                solidRun.destinationTexture = destination.texture
                solidRun.encoderCount += 1
                encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                               width: Double(destination.texture.width),
                                               height: Double(destination.texture.height), znear: 0, zfar: 1))
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: destination.texture.width,
                                                    height: destination.texture.height))
            }
        }
        defer { if solidRun == nil { encoder.endEncoding() } }

        // Builtin quads and puppet atlas/composite vertices construct NDC directly. Only the scene-model mesh path applies the camera matrix and overrides this.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(
            depthTest: pass.pass.depthTest,
            depthWrite: pass.pass.depthWrite,
            reversedZ: usesReversedZ
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
            do {
                try dispatcher.dispatch(
                    pass: pass,
                    layer: drawLayer,
                    destination: destination,
                    textures: textures,
                    frameState: frameState,
                    encoder: encoder,
                    depthPixelFormat: needsDepth ? .depth32Float : .invalid,
                    fetchSceneColor: fetchSceneColor
                )
            } catch let error as WPEMetalRenderExecutorError where error.untranslatableShaderReason != nil {
                // The encoder is already open and has cleared this target, so hand the cleared texture to `frameState`: a later pass sampling the same name reads transparent black instead of failing the WHOLE scene.
                frameState.registerWrite(texture: destination.texture, targetID: destination.id)
                throw error
            }

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            solidRun?.drawCount += 1
            if WPEBuiltinShaderKind(normalizing: pass.pass.shader) != .solidLayer {
                solidRun?.texturedDrawCount += 1
            }
        }
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

    /// The scene can stack several animation layers; play them all so blinks/mouth motion compose on top of the body sway, instead of only the first layer.
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
        // The objectID→layer index is only ever read to resolve a child's parent puppet; a scene with no attached children never touches it, so skip building it there.
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

    var lastLoggedPuppetSkinningReason: [String: String] = [:]

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

    /// Cache-hit counters proving the memoization actually short-circuits (a recompute-only path would still pass the output-equality tests).
    var puppetPaletteCacheHitsForTesting = 0
    var puppetBoundScanCacheHitsForTesting = 0

    /// Power-of-two bucketed. The shader only reads `paletteCount` entries (`indices < paletteCount` guards every tap), so a bucket's stale tail is never sampled.
    /// Lock-protected: `recycle` runs on Metal completion threads.
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
    /// A frame aborted before commit leaves its buffers here — they ride along with the next commit (never executed by the GPU, so recycling them late is safe, early would be too).
    var bonePaletteBuffersInFlight: [MTLBuffer] = []

    struct PuppetMeshBufferKey: Hashable {
        /// Path + mesh index identifies immutable topology without hashing millions of vertex/index elements on every draw. The cache is cleared on every reload.
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

    private func snapshotFullFrameBufferIfAliasingScene(
        pass: WPEPreparedRenderPass,
        destinationTexture: MTLTexture,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws {
        // Any pass sampling a scene alias participates — not only scene-target draws. WPE re-captures the frame for EVERY layer that samples it, so a stale snapshot from one layer corrupts later ones.
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

        // A layer's first alias read before any own-layer scene write, drawn into a target that shares no storage with the scene, binds the live scene and skips the blit. Scene-targeted draws and layers that already wrote the scene keep the capture.
        let liveScene = frameState.currentFrameSceneTexture ?? frameState.output
        let bindsLiveScene = !diagnosticControls.disableSceneAliasDirectBind
            && frameState.currentFrameSceneTexture != nil
            && pass.pass.target != .scene
            && frameState.sceneWriteGeneration == frameState.layerEntrySceneWriteGeneration
            && layer.puppetPath == nil
            && destinationTexture.sampleCount == 1 && liveScene.sampleCount == 1
            && !WPEMetalSolidSceneRun.samplesAttachment(destinationTexture, output: liveScene)
        let previousReadsTarget = pass.textureReferences.contains(.previous)
            ? WPEMetalTargetID(target: pass.pass.target) : nil

        var seen = Set<String>()
        for reference in pass.textureReferences {
            guard case .fbo(let alias) = reference,
                  WPETextureReference.isSceneAliasName(alias),
                  seen.insert(alias).inserted,
                  needsSnapshot(alias) else {
                continue
            }
            if bindsLiveScene, previousReadsTarget != .named(alias),
               targetPool.sceneSnapshotMatches(liveScene, alias: alias, layer: layer, sceneSize: frameState.sceneSize) {
                frameState.latestNamedTextures.removeValue(forKey: alias)
                frameState.sceneAliasSnapshotGenerations.removeValue(forKey: alias)
                frameState.sceneAliasDirectBinds += 1
                continue
            }
            let snapshot = try targetPool.texture(
                for: .fbo(name: alias),
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: destinationTexture
            )
            if let source = frameState.currentFrameSceneTexture {
                try copyTexture(source, to: snapshot, commandBuffer: commandBuffer,
                                traceLabel: "scene-snapshot|\(pass.pass.id)|\(alias)")
                frameState.sceneAliasSnapshotBlits += 1
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
        encoder.applyTraceLabel("clear")
        WPEFrameOccupancyMeter.count(.helperEncoder)
        encoder.endEncoding()
    }

    /// It must be a separate texture, not the live scene target — this pass draws into that target, and sampling it would be an undefined read-write.
    private func captureReflectionSourceIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: WPEMetalFrameState
    ) throws {
        reflectionSourceTexture = nil
        guard case .material = pass.pass.phase,
              (pass.pass.combos["REFLECTION"] ?? 0) != 0,
              Self.sceneModelMaterialShader(for: pass.pass.shader) != nil,
              layer.puppetPath != nil,
              (layer.imagePath as NSString).pathExtension.lowercased() == "mdl",
              let source = frameState.currentFrameSceneTexture else {
            return
        }
        let capture = try reflectionCaptureTexture(matching: source)
        try copyTexture(source, to: capture, commandBuffer: commandBuffer,
                        traceLabel: "reflection|\(pass.pass.id)", generateMipmaps: true)
        WPEFrameOccupancyMeter.count(.reflectionCapture)
        reflectionSourceTexture = capture
    }

    private func reflectionCaptureTexture(matching source: MTLTexture) throws -> MTLTexture {
        if let cached = reflectionCaptureCache,
           cached.width == source.width,
           cached.height == source.height,
           cached.pixelFormat == source.pixelFormat {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: true
        )
        // `.renderTarget` is what `generateMipmaps` requires (it renders each level).
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "_rt_MipMappedFrameBuffer"
        reflectionCaptureCache = texture
        return texture
    }

    /// The target must end the pass holding exactly what the source held, or the next chain pass samples an FBO nothing wrote this frame. Only composite targets need this.
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
        try copyTexture(sourceTexture, to: destination.texture, commandBuffer: commandBuffer,
                        traceLabel: "gated-passthrough|\(pass.pass.id)")
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
                commandBuffer: commandBuffer,
                traceLabel: "copy-feedback-init|\(layer.objectID)"
            )
            frameState.markInitialized(destination.texture)
        }

        // Resolved BEFORE the encoder exists: with `.dontCare` below, an encoder that ends without drawing leaves the attachment undefined, so a missing texture or pipeline must abort while the destination is still whole.
        let pipelineState = try renderPipeline(
            fragmentName: "wpe_copy_fragment",
            blendMode: "disabled",
            colorPixelFormat: destination.texture.pixelFormat
        )
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: reference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        // Fullscreen quad, blending disabled, full write mask: every texel is overwritten, so neither previous contents nor a clear is ever observable. `.dontCare` drops the attachment read.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "copy|\(layer.objectName)")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("copy-draw|\(layer.objectID)")
        WPEFrameOccupancyMeter.count(.helperEncoder)
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        // Parallax is a geometry translation applied in object-quad scene passes; raw-pointer UV shifts are intentionally not applied here.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        frameState.registerWrite(texture: destination.texture, targetID: destination.id)
    }

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

    /// True when this pass is WPE `effects/skew` in MODE=1 (Vertex): the quad geometry must be displaced in the vertex stage. MODE=0 (UV) is handled by the ordinary transpiled fragment.
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

    /// MODE=1 skew corner-displacement as fractions of the quad extent. WPE's `skew.vert` multiplies the displacement by `g_TextureReductionScale`, folded in here; it defaults to 1.0.
    func vertexSkewParams(for pass: WPEPreparedRenderPass) -> WPESkewParams {
        let keyIndex = uniformKeyIndex(for: pass)
        func value(_ names: [String], default fallback: Float = 0) -> Float {
            for name in names {
                if let v = pass.uniformValues[name] ?? pass.pass.constants[name] {
                    return Self.scalarValue(v, default: fallback)
                }
            }
            // Same precedence as the scan this replaces: any uniformValues case-variant match wins over any constants one.
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
            // Route identity full-frame layers through the object quad only when there's an actual parallax shift. Gated on `amount != 0` AND a live cursor: a nonzero `smoothed` alone would drag full-frame layers off the fullscreen path for a zero shift.
            return layer.parallaxDepth != SIMD2<Double>(0, 0)
                && cameraParallax.amount != 0
                && cameraParallax.smoothed != SIMD2<Float>(0, 0)
        }
        // WPE fullscreen/passthrough utility layers capture + copy the full frame 1:1. A `composelayer.json` in a safe sub-rect captures the matching scene area, then its final scene output is confined to that box via the object quad.
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
        // A compose layer that parents children is a layer-group container, not a scene-effect box: confining its own passthrough to the authored box would paint a scene-copy PiP. Keep it fullscreen.
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
        // WORLD canvas, never `destination.texture` dimensions: with render scaling the group RT is allocated `pixelScale` smaller, and quad NDC math built on the texture size would grow every group member by 1/pixelScale.
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

    /// The static half of the shift, `(nodePos - camPos) * depth * amount`, must be evaluated ONCE at the root — feeding each child its own origin turns the rigid translation into an anisotropic scale of the subtree about the scene centre by `(1 + depth * amount)`.
    static func parallaxRootCenters(
        for layers: some Collection<WPERenderLayer>,
        sceneSize: CGSize,
        objectParentByID: [String: String] = [:],
        hostDepthByObjectID: [String: SIMD2<Double>] = [:],
        hostOriginByObjectID: [String: SIMD2<Double>] = [:]
    ) -> [String: SIMD2<Float>] {
        guard layers.contains(where: { $0.parentObjectID != nil }) else { return [:] }
        // Same anchor-node selection as the depth propagation, so the depth and the static-term origin always come from the SAME node — a non-drawn group host counts.
        var geometryByID: [String: WPERenderLayerGeometry] = [:]
        geometryByID.reserveCapacity(layers.count)
        var depthByID = hostDepthByObjectID
        var parentByID = objectParentByID
        let inferParents = parentByID.isEmpty
        for layer in layers {
            let id = layer.objectID
            if geometryByID[id] == nil { geometryByID[id] = layer.geometry }
            if depthByID[id] == nil { depthByID[id] = layer.parallaxDepth }
            if inferParents, parentByID[id] == nil, let parent = layer.parentObjectID {
                parentByID[id] = parent
            }
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

    /// The object-quad anchor: authored origin measured from the scene centre, accepting the normalized 0...1 origin form the parser can emit.
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

    /// AUTHORED image size from the metadata registry, which survives the loader uploading a reduced mip under render scaling. Unregistered textures fall back to their own dimensions.
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
        // Identity (full-frame) layers map to a scene-sized quad centered at the origin — identical coverage + UV to `wpe_fullscreen_vertex` — plus the camera-parallax shift. Only reached when parallax is active.
        if geometry == .identity {
            // Full-frame layer: its origin IS the scene centre, so the static parallax term is zero and only the cursor moves it — unless it is parented, in which case it rides its root's offset.
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
        // `geometry.origin` is already top-left-pixel convention, so `originX - sceneWidth*0.5` places the box correctly. An earlier center-origin special-case pushed the box off-screen.
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

    /// A DIRECTDRAW `shape: "quad"` layer draws through the 4-corner geometry, not the axis-aligned object quad. Gated to the orthographic scene draw — the corners are pre-projected here so a live perspective camera falls back to the object quad.
    func usesShapeQuadGeometry(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        frameState: WPEMetalFrameState
    ) -> Bool {
        guard let points = layer.geometry.shapePoints, points.count == 4 else { return false }
        guard case .scene = pass.pass.target else { return false }
        return !frameState.cameraUniforms.usesPerspectiveProjection
    }

    /// Each WPE point maps to a model-space corner `((p.x-0.5)·H, (0.5-p.y)·H)` in a square base of the scene height, then layer scale/rotation/origin/parallax apply. Corners emit in triangle-strip order (p0, p1, p3, p2).
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
        WPEFrameOccupancyMeter.count(.helperEncoder)
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
        WPEFrameOccupancyMeter.count(.helperEncoder)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }
    #endif

    private static let imageUniformDebugEnabled = UserDefaults.standard.bool(forKey: "WPEImageUniformDebugLog")
    private static let loggedImageUniformNames = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func genericImageUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasMask: Bool,
        sourceTexture: MTLTexture? = nil,
        maskTexture: MTLTexture? = nil
    ) -> WPEGenericImageUniforms {
        // WPE bakes the object's authored `color` into g_Color4 for every image material, so the layer tint multiplies the material's own g_Color — same channel the brightness field already rides.
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
        // genericimage shaders do `rgb = sampled.rgb * color.rgb * brightness`, so brightness==0 OR color==0 blacks out the layer while alpha (a separate term) survives.
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

    /// Bindings use the shader-annotation names ("color" → g_TintColor), NOT the g_* names, uploaded RAW (no sRGB conversion). The emissive term requires BOTH the slot-2 component map and authored emissive constants.
    func sceneModelGenericUniforms(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        hasComponentMap: Bool,
        materialShader: SceneModelMaterialShader = .genericImage4,
        hasReflectionSource: Bool = false,
        reflectionTopMipLevel: Int = 0,
        noiseTexture: MTLTexture? = nil
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

        // generic2 and generic4 expose the SAME uniforms under DIFFERENT material names. generic2 annotates "Brigtness" (WPE's own typo — match it verbatim, do not "fix" it). The spellings cannot share one priority list: authors ship BOTH keys and only the shader's own is bound.
        let isGeneric2 = materialShader == .generic2
        let tint = constantVector3(
            isGeneric2 ? ["Color", "g_TintColor"] : ["color", "g_TintColor"],
            default: SIMD3<Float>(1, 1, 1)
        )
        let tintAlpha = constantScalar(
            isGeneric2 ? ["Alpha", "g_TintAlpha"] : ["alpha", "Alpha", "g_TintAlpha"],
            default: 1
        ) * Float(layer.geometry.alpha)
        let emissiveColor = constantVector3(["emissivecolor", "g_EmissiveColor"], default: SIMD3<Float>(1, 1, 1))
        let emissiveBrightness = constantScalar(["emissivebrightness", "g_EmissiveBrightness"], default: 1)
        let brightness = constantScalar(
            isGeneric2 ? ["Brigtness", "g_Brightness"] : ["brightness", "g_Brightness"],
            default: 1
        ) * Float(layer.geometry.brightness)
        let ambient = mergedVector3("g_LightAmbientColor", default: SIMD3<Float>(1, 1, 1))
        let skylight = mergedVector3("g_LightSkylightColor", default: SIMD3<Float>(1, 1, 1))
        let lightingEnabled = (pass.pass.combos["LIGHTING"] ?? 1) != 0
        let hdrValue = frameUniformContext.frameValue(named: "g_SceneHDREnabled")
            ?? pass.uniformValues["g_SceneHDREnabled"]
        let hdr = (hdrValue?.numberValue ?? 0) > 0.5
        let emissiveAuthored = pass.pass.constants["emissivecolor"] != nil
            || pass.pass.constants["emissivebrightness"] != nil
        let emissiveMapActive = hasComponentMap && emissiveAuthored

        // REFLECTION only draws when the mip-mapped scene capture is actually
        // bound: without it `g_Texture3` would fall back to the albedo and paint
        // the model with its own texture.
        let reflectionEnabled = (pass.pass.combos["REFLECTION"] ?? 0) != 0 && hasReflectionSource
        let reflectivity = constantScalar(["reflectivity", "g_Reflectivity"], default: 1)
        let roughness = constantScalar(["roughness", "g_Roughness"], default: 0.7)
        let metallic = constantScalar(["metallic", "g_Metallic"], default: 0)
        let tintFront = constantVector3(["tintfront", "g_TintFront"], default: SIMD3<Float>(1, 1, 1))
        let tintBack = constantVector3(["tintback", "g_TintBack"], default: SIMD3<Float>(1, 1, 1))
        let renderSize = currentScenePixelSize
        let aspect = renderSize.height > 0 ? Float(renderSize.width / renderSize.height) : 1

        return WPESceneModelGenericUniforms(
            tintColorAlpha: SIMD4<Float>(tint.x, tint.y, tint.z, tintAlpha),
            emissive: SIMD4<Float>(emissiveColor.x, emissiveColor.y, emissiveColor.z, emissiveBrightness),
            ambientLighting: SIMD4<Float>(ambient.x, ambient.y, ambient.z, lightingEnabled ? 1 : 0),
            brightnessFlags: SIMD4<Float>(
                brightness,
                emissiveMapActive ? 1 : 0,
                hdr ? 1 : 0,
                reflectionEnabled ? 1 : 0
            ),
            skylightColor: SIMD4<Float>(skylight.x, skylight.y, skylight.z, 0),
            reflection: SIMD4<Float>(reflectivity, roughness, metallic, Float(reflectionTopMipLevel)),
            screen: SIMD4<Float>(Float(renderSize.width), Float(renderSize.height), aspect, 0),
            // chroma4's front/back tint defaults to white so an unauthored material is a
            // no-op multiply rather than a black mesh.
            chromaTintFront: SIMD4<Float>(
                tintFront.x, tintFront.y, tintFront.z,
                constantScalar(["tintpigmentation", "g_TintPigmentation"], default: 0)
            ),
            chromaTintBack: SIMD4<Float>(
                tintBack.x, tintBack.y, tintBack.z,
                constantScalar(["tintwexponent", "g_TintExponent"], default: 1)
            ),
            chromaNoise: SIMD4<Float>(
                Float(noiseTexture?.width ?? 0),
                Float(noiseTexture?.height ?? 0),
                noiseTexture != nil ? 1 : 0,
                0
            )
        )
    }

    // MARK: - Scene HDR bloom

    /// Kill switch: `defaults write com.loomscreen.pro WPEMetalSceneBloomEnabled -bool NO`.
    static let isSceneBloomEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalSceneBloomEnabled") as? Bool) ?? true


    /// Set by `captureReflectionSourceIfNeeded` for the pass about to be encoded,
    /// cleared for every other pass so a stale capture can never leak into one.
    var reflectionSourceTexture: MTLTexture?
    /// Reused across frames; only the allocation persists, the content is
    /// re-captured per reflecting pass.
    private var reflectionCaptureCache: MTLTexture?

    var bloomLevelTextures: [MTLTexture] = []
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
        if pass.access.hasPreviousReference { return true }
        guard case .named(let name) = targetID else { return false }
        return pass.access.fboNames.contains(name)
    }

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

    /// `@unchecked Sendable`: the Metal handles it carries (device, library, functions) are all
    /// documented thread-safe, so the whole request crosses into the prewarm task group as one
    /// Sendable value and no bare `MTLDevice` is captured.
    struct WPETranslatedPipelinePrewarm: @unchecked Sendable {
        let device: MTLDevice
        let defaultLibrary: MTLLibrary
        let result: WPEShaderCompileResult
        let vertexName: String?
        let blendMode: String
        let alphaWritePolicy: WPEMetalAlphaWritePolicy
        let colorPixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat
    }

    struct WPEPrewarmedPipeline: @unchecked Sendable {
        fileprivate let key: TranslatedPipelineKey
        fileprivate let state: MTLRenderPipelineState
    }

    /// Does NO cache mutation, so it runs concurrently off-actor. A pipeline is FULLY determined by its cache key; an imperfect prediction only costs a cache miss, never correctness.
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
            ?? prewarm.defaultLibrary.makeFunction(name: resolvedVertexName),
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

    func seedTranslatedPipelines(_ prewarmed: [WPEPrewarmedPipeline]) {
        for entry in prewarmed where translatedPipelineCache[entry.key] == nil {
            translatedPipelineCache[entry.key] = entry.state
        }
    }

    func packTranslatedUniforms(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: WPEMetalTextureSlotTable? = nil
    ) throws -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.translatedSlotCount(for: layout))
        try slots.withUnsafeMutableBufferPointer {
            try packTranslatedUniformSlots(
                for: pass, layout: layout, texturesBySlot: texturesBySlot, into: $0
            )
        }
        return slots
    }

    /// The packing itself, over storage the caller owns. `slots` MUST arrive zeroed:
    /// each claimed column writes all four lanes (unused lanes are zero). Slots
    /// not claimed by any uniform retain the caller-provided zero fill.
    func packTranslatedUniformSlots(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot],
        texturesBySlot: WPEMetalTextureSlotTable?,
        into slots: UnsafeMutableBufferPointer<SIMD4<Float>>
    ) throws {
        let plans = uniformPlans(for: pass, layout: layout)
        let frame = frameUniformContext
        let useDirectPacking = derivedUniformPackingEnabled
        for (index, u) in layout.enumerated() {
            if useDirectPacking,
               let packing = plans[index].directPacking,
               let vector = directUniformVector(packing, texturesBySlot: texturesBySlot) {
                slots[u.slot] = vector
                continue
            }
            let value = resolvedUniformValue(
                plan: plans[index],
                pass: pass,
                frame: frame,
                texturesBySlot: texturesBySlot
            )
            try WPEUniformPacking.pack(value, uniform: u, into: slots)
        }
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

    /// `g_TexelSize` is a SCENE-level constant, not a per-pass one. WPE feeds the SAME `g_TexelSize` = 1/(head width, head height) to every downsample in the bloom chain — a fixed width in SCREEN space.
    static let texelSizeUniformName = "g_TexelSize"
    static let texelSizeHalfUniformName = "g_TexelSizeHalf"
    static let screenUniformName = "g_Screen"

    static func texelSizeValue(named name: String, sceneSize: CGSize) -> WPESceneShaderConstantValue? {
        guard name == texelSizeUniformName else { return nil }
        let width = Double(sceneSize.width)
        let height = Double(sceneSize.height)
        guard width > 0, height > 0 else { return nil }
        return .vector([1 / width, 1 / height])
    }

    static func texelSizeHalfValue(named name: String, sceneSize: CGSize) -> WPESceneShaderConstantValue? {
        guard name == texelSizeHalfUniformName else { return nil }
        let width = Double(sceneSize.width)
        let height = Double(sceneSize.height)
        guard width > 0, height > 0 else { return nil }
        return .vector([0.5 / width, 0.5 / height])
    }

    static func screenValue(named name: String, sceneSize: CGSize) -> WPESceneShaderConstantValue? {
        guard name == screenUniformName else { return nil }
        let width = Double(sceneSize.width)
        let height = Double(sceneSize.height)
        guard width > 0, height > 0 else { return nil }
        return .vector([width, height, width / height])
    }

    /// Equal timestamps are the same logical frame and therefore keep the already-derived delta. A rewind starts a new clock epoch at zero.
    @discardableResult
    func advanceShaderFrameTime(runtimeTime: Double) -> Double {
        guard runtimeTime.isFinite else {
            lastShaderRuntimeTime = nil
            currentShaderFrameTime = 0
            return 0
        }
        guard let previous = lastShaderRuntimeTime else {
            lastShaderRuntimeTime = runtimeTime
            currentShaderFrameTime = 0
            return 0
        }
        if runtimeTime > previous {
            currentShaderFrameTime = runtimeTime - previous
            lastShaderRuntimeTime = runtimeTime
        } else if runtimeTime < previous {
            currentShaderFrameTime = 0
            lastShaderRuntimeTime = runtimeTime
        }
        return currentShaderFrameTime
    }

    func resetShaderFrameTime() {
        lastShaderRuntimeTime = nil
        currentShaderFrameTime = 0
    }

    static func textureResolutionSlotIndex(for name: String) -> Int? {
        let prefix = "g_Texture"
        let suffix = "Resolution"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let slotText = name.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(slotText)
    }

    static func textureRotationSlotIndex(for name: String) -> Int? {
        officialTextureSamplingSlotIndex(for: name, suffix: "Rotation")
    }

    static func textureTranslationSlotIndex(for name: String) -> Int? {
        officialTextureSamplingSlotIndex(for: name, suffix: "Translation")
    }

    private static func officialTextureSamplingSlotIndex(
        for name: String,
        suffix: String
    ) -> Int? {
        let prefix = "g_Texture"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let slotText = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let slot = Int(slotText), (0..<WPEShaderTranspiler.customTextureSlotLimit).contains(slot) else {
            return nil
        }
        return slot
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

    /// Those targets already store premultiplied RGB, so a transpiled straight-alpha shader must un-premultiply them before running its original math.
    private static func premultipliedInputSlots(for pass: WPEPreparedRenderPass) -> Set<Int> {
        var slots = Set<Int>()
        for slot in 0..<WPEShaderTranspiler.customTextureSlotLimit {
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

    /// Returns nil for built-in/shader-less passes. `recordFailure` gates the scene-debug artifact so the warm stays silent.
    static func makeCompileRequest(
        for pass: WPEPreparedRenderPass,
        recordFailure: Bool
    ) throws -> WPEShaderCompileRequest? {
        guard let program = pass.shader, !program.isBuiltin else { return nil }
        let premultipliedInputSlots = premultipliedInputSlots(for: pass)
        let premultipliedOutput = usesPremultipliedOutput(blendMode: pass.pass.blending)
        let materialTextureBindings = Dictionary(
            uniqueKeysWithValues: pass.textureBindings.compactMap { (slot, ref) -> (Int, String)? in
                switch ref {
                case .image(let p), .asset(let p): return (slot, p)
                case .fbo(let n): return (slot, n)
                case .previous: return nil
                }
            }
        )
        do {
            // Memoized on the four inputs of `process`. Builtins carry no fingerprint; a nil here degrades to the uncached path rather than key on a placeholder.
            let key = program.sourceFingerprint.map { fingerprint in
                WPEShaderPreprocessMemoKey(
                    shaderName: program.name,
                    sourceFingerprint: fingerprint,
                    comboValues: pass.comboValues,
                    materialTextureBindings: materialTextureBindings
                )
            }
            let processed = try WPEShaderPreprocessMemoStore.shared.value(for: key) {
                // program.*Source is already #include-expanded at graph-build time
                // (WPERenderPipelineBuilder.preprocess); this stage does no include
                // resolution of its own.
                let processor = WPEShaderPreprocessor()
                return try processor.process(
                    shaderName: program.name,
                    vertexSource: program.vertexSource,
                    fragmentSource: program.fragmentSource,
                    comboValues: pass.comboValues,
                    materialTextureBindings: materialTextureBindings
                )
            }
            // Applied after the memo on purpose: the PMA flags come from the
            // pass's blend mode and bound targets, not from `process`'s inputs,
            // so they must not widen the memo key.
            return processed.replacingPremultipliedAlphaSettings(
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
