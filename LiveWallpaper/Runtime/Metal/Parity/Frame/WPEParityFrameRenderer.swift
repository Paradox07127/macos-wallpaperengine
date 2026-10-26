#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import simd

/// Compiles WPE programs through the shader store.
struct WPEParityFrameShaderSource: Sendable {
    let store: WPEParityShaderStore
    let compilerIdentity: String
    let bindingABIVersion: Int
    var options = WPEParityShaderCompileOptions()
    var requireAllPrograms = false

    func artifact(for program: WPEParityProgram) async throws -> WPEParityShaderArtifact {
        try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program.hlsl, compilerIdentity: compilerIdentity, options: options, bindingABIVersion: bindingABIVersion
        ))
    }
}

/// Host state the engine uniforms read each frame.
struct WPEParityFrameInput {
    /// Physical render-target pixels, y down; SceneScript receives the corresponding logical client pixels.
    var cursor: SIMD2<Float> = .zero
    /// The SceneScript cursor in the same pixels when it is not `cursor`; g_PointerPosition stays on `cursor`.
    var scriptCursor: SIMD2<Float>?
    /// False while the cursor is on another display or a letterbox margin; `cursor` then holds a stand-in position.
    var cursorOverPicture = true
    var buttonDown = false
    /// 64 linear bins per channel; nil is silence.
    var audio: (left: [Float], right: [Float])?
    /// Local time for g_Daytime.
    var date = Date()
}

enum WPEParityFrameRenderError: Error, LocalizedError {
    case missingBackbuffer
    case requiredShaderUnavailable(String)
    case arenaUnavailable
    case allocationFailed(WPEResourceID)
    case encoderUnavailable
    case invalidUserProperties
    case requiredPostProcessUnavailable(pass: String, reason: WPEParityFrameSkip)

    var errorDescription: String? {
        switch self {
        case let .requiredShaderUnavailable(reason): "Required WPE shader unavailable: \(reason)"
        case .missingBackbuffer: "The WPE frame has no backbuffer"
        case .arenaUnavailable: "The WPE frame arena is unavailable"
        case let .allocationFailed(resource): "The WPE frame could not allocate \(resource)"
        case .encoderUnavailable: "The WPE frame encoder is unavailable"
        case .invalidUserProperties: "The WPE user properties are not a JSON object"
        case let .requiredPostProcessUnavailable(pass, reason): "Required WPE postprocess \(pass) unavailable: \(reason)"
        }
    }
}

/// Renders a plan's frames on Metal: one compiled graph per frame variant, renderer-owned dedicated and pooled
/// targets, executor-owned heap and memoryless transients. A skipped draw stays in the graph and encodes nothing.
final class WPEParityFrameRenderer {
    /// The frames of one set of shown effects and the plans of their draws.
    struct Layout {
        /// The planner plans from this; a graph restored from the cache restores it too.
        let planned: WPEParityFrameLayout
        /// The state's effect visible bits the frames were composed with.
        let effects: [Bool]
        var post: WPEParityPostProcessConfig {
            planned.post
        }

        var frames: [WPEParityFrame] {
            planned.frames
        }

        let draws: [Int: WPEParityFrameDrawPlan]
        let skipped: [Int: WPEParityFrameSkip]
        /// The camerafade draw's operation index.
        let fade: Int?
    }

    /// A draw named by its pass and the draws of that pass before it, which holds across effect sets.
    struct DrawName: Hashable {
        let pass: WPEPassIdentity
        let occurrence: Int
    }

    /// One compiled graph per frame variant of a layout without the operations of hidden objects.
    struct Graphs {
        let layout: Layout
        /// Per state object, whether it or an ancestor is hidden.
        let hidden: [Bool]
        let executors: [WPEParityGraphExecutor]
        /// Per executor, graph operation index → layout operation index.
        let operations: [[WPEParityGraphDrawSource]]
        let particleDraws: [WPEParityParticleDrawKey: Int]
        let particleSnapshotSkips: [String: WPEParityFrameSkip]

        /// Pooled targets an executor keeps in its heap or tile memory instead of a renderer-owned texture.
        var aliasedTargets: Set<WPEResourceID> {
            Set(executors.flatMap { executor in
                executor.transientTextures.keys.filter { executor.graph.resources[$0]?.lifetime == .pooled }
            })
        }
    }

    /// Set by a failed command buffer of an aliasing graph; later graphs in this process keep every pooled target.
    static let renderTargetAliasingFailed = OSAllocatedUnfairLock(initialState: false)

    let backbuffer: MTLTexture
    /// Render targets the renderer allocates; layer images are not among them.
    var targets: [WPEResourceID: MTLTexture] {
        didSet { frameTextures = nil }
    }

    /// `targets` with the planner's layer images over them, as the frame encodes; nil once either changed.
    private var frameTextures: [WPEResourceID: MTLTexture]?
    var instance: WPEParitySceneInstance
    /// Material constant re-packs after a pass's constants changed, over the renderer's life.
    private(set) var constantPacks = 0
    var packedConstants: [Int: (generation: Int, constants: [WPEHLSLStage: [String: WPECBufferValue]])] = [:]
    var seenTransforms = 0
    /// Set once a layer transform left its loaded value: draws then place themselves from `layers` every frame.
    var layersMoved = false
    var seenVisibility = 0
    var seenEffects = 0
    var seenMembership = 0
    var seenModelData = 0
    var graphs: Graphs {
        didSet { drawVideoSources = nil }
    }

    /// Per layout draw operation, the video sources its passes bind; nil until the next frame after the graphs changed.
    var drawVideoSources: [Int: Set<Int>]?
    /// The graphs before the last visibility change, kept so toggling back does not recompile.
    var previousGraphs: Graphs?
    /// Dropped draws of graphs no longer kept.
    var retiredDrops = 0
    let plan: WPEParityFramePlan
    var logicalSize: SIMD2<Float> {
        SIMD2(Float(plan.width), Float(plan.height))
    }

    var colorTransfer: WPEPresentColorTransfer {
        plan.colorTransfer
    }

    /// Loaded text identity metadata; mutable colors remain only in SceneState.
    private let textBackgroundOwners: [WPEPassIdentity: String]
    /// Draws of later effect sets plan here, reusing its images and pipelines.
    var planner: WPEParityFrameDrawPlanner {
        didSet { frameTextures = nil; plannerRevision &+= 1 }
    }

    var plannerRevision = 0

    /// Every program the plan can draw with, compiled at load.
    var artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>]
    let mipMappedFrameBufferRequested: Bool
    /// Post-process draw constants for `bloom`, by draw operation, where they differ from the planned ones.
    var postConstants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] = [:]
    let device: MTLDevice
    let drawEncoder: WPEParityDrawEncoder
    let videos: WPEParityVideoTextures
    let videoWorkshopID: String
    let queue: MTLCommandQueue
    private let screen: WPEParityUniformScreen
    /// The scene camera; a camera path pose replaces it for the frame.
    let rootCamera: WPEParityCamera
    /// Centre crops of `mediaTextures` images; keyed by identity, so they are dropped with the snapshot.
    var mediaCrops: [MediaCrop: MTLTexture] = [:]
    var hasMediaTextureDemand: Bool {
        graphs.layout.draws.values.contains { !$0.mediaSlots.isEmpty }
    }

    /// (visibility, membership) generations last reported to the sound runtime.
    var seenSoundVisibility = SIMD2(-1, -1)
    var seenLightTransforms = -1
    var seenLightVisibility = -1
    var seenLayerFields = -1
    var seenAnimationLayerFields = -1
    /// Each puppet animation layer's field keys; `seed` is the scene JSON value a key compares with before any push.
    struct AnimationLayerFields {
        let objectID: String
        let sceneIndex: Int
        let fields: [(name: String, seed: WPEParitySceneState.ScriptValue, key: WPEParitySceneState.ScriptFieldKey)]
    }

    /// Built for the state membership generation it records.
    var animationLayerFields: (membership: Int, layers: [AnimationLayerFields])?
    var lights: WPEParityUniformLights
    /// This frame's shadow atlas layout; nil when shadow quality is 0 or the plan declares no atlas.
    var shadowLayout: WPEParityShadowLayout?
    let generalZoom: Float
    /// The fade draw's planned constants with this frame's g_Alpha.
    var fadeConstants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
    /// Native no-hook fields are polled at the camera-update and layer-render read points.
    private var cameraParallax: WPESceneCameraParallaxSettings {
        var settings = WPESceneCameraParallaxSettings.disabled
        if case let .vector(value)? = instance.state.scriptField("cameraparallax", of: "") {
            settings.enabled = value.x != 0
        }
        if case let .vector(value)? = instance.state.scriptField("cameraparallaxamount", of: "") {
            settings.amount = Double(value.x)
        }
        if case let .vector(value)? = instance.state.scriptField("cameraparallaxdelay", of: "") {
            settings.delay = Double(value.x)
        }
        if case let .vector(value)? = instance.state.scriptField("cameraparallaxmouseinfluence", of: "") {
            settings.mouseInfluence = Double(value.x)
        }
        return settings
    }

    var cameraShake: WPEParityCameraShake? {
        guard case let .vector(enabled)? = instance.state.scriptField("camerashake", of: ""), enabled.x != 0 else { return nil }
        var settings = WPEParityCameraShake(orthographic: rootCamera.scenePerspective == nil)
        if case let .vector(value)? = instance.state.scriptField("camerashakespeed", of: "") {
            settings.speed = value.x
        }
        if case let .vector(value)? = instance.state.scriptField("camerashakeamplitude", of: "") {
            settings.amplitude = value.x
        }
        if case let .vector(value)? = instance.state.scriptField("camerashakeroughness", of: "") {
            settings.roughness = value.x
        }
        return settings
    }

    /// Left-button edges in backbuffer UV (y down) for the next committed frame's cursor pass, in order.
    var buttonEdges: [(position: SIMD2<Float>, down: Bool)] = []
    private let particleFullFrameBuffer: [String: [[WPEParityParticlePathElement]: Bool]]
    private let particleBaseFailures: [String: [[WPEParityParticlePathElement]: WPEParityFrameSkip]]
    let particleSnapshotObjects: Set<String>
    private(set) var particleMaterialSkips: [String: WPEParityFrameSkip]
    let arena: WPEParityFrameArena
    /// Arena bytes outside the particle share, for the other draws' cbuffers and tables.
    var baseArenaBytes: Int
    /// False when the caller fixed the particle share.
    private let growsParticleShare: Bool
    static let maxParticleShare = WPEParityProgramScene.maxParticleShare
    /// Particle objects whose dropped batches were already logged.
    private var loggedParticleDrops: Set<String> = []
    private static let silence = [Float](repeating: 0, count: 64)
    var layers: WPEParityLayerTransformSet
    /// Every particle object and its state index; hidden ones are not stepped.
    private let particleObjects: [(id: String, index: Int?)]
    #if DEBUG
    /// The draws the last frame encoded, by draw operation, in encode order.
    private(set) var lastFrameDraws: [(operation: Int, draw: WPEParityDraw)] = []
    #endif
    /// Actual decoder owners, including live user-video replacements; controlled tests reject video workloads.
    var videoSourceCount: Int {
        videos.sourceCount
    }

    /// Counts from the last selected executor; skipped submissions must not be treated as measured work.
    var lastFrameCopyCount: Int? {
        guard instance.frameIndex > 0, !graphs.executors.isEmpty else { return nil }
        let executor = graphs.executors[(instance.frameIndex - 1) % graphs.executors.count]
        return executor.copyEncoded
    }

    /// The draw operations the last frame encoded, in encode order.
    private var lastFrameOperations: [Int] = []
    var lastFrameDrawCount: Int {
        lastFrameOperations.count
    }

    var targetSamplers: [ObjectIdentifier: WPEParitySamplerState] = [:]
    var resourceBindings: WPEParityResourceBindings = [:]
    var seenScriptText = 0
    private struct MaterialClear {
        let texture: MTLTexture
        let color: WPEClearColor
    }

    /// Calls retain the actual texture version and order until its clear has been encoded on a committed buffer.
    private var materialClears: [MaterialClear] = []
    /// Images and targets of removed objects that frames already submitted may still read; the next committed
    /// frame's completion releases them.
    var retiredTextures: [MTLTexture] = []

    /// The frames of the effects the state shows; draw operation indices refer to them.
    var frames: [WPEParityFrame] {
        graphs.layout.frames
    }

    #if DEBUG
    /// Actual executor identities for the ModelData immutable-version product guard; retains no resources.
    var graphExecutorIdentities: [ObjectIdentifier] {
        graphs.executors.map(ObjectIdentifier.init)
    }

    var compiledGraphs: [WPECompiledRenderGraph] {
        graphs.executors.map(\.graph)
    }

    var frameLayoutCalls: Int {
        plan.layoutCalls.withLock { $0 }
    }

    /// Times the per-puppet animation-layer field keys were built.
    var animationLayerFieldIndexBuilds = 0

    /// Reads the current graph's actual allocation, including heap/memoryless targets; owns no extra resources.
    func renderTarget(_ id: WPEResourceID, scope: WPEResourceBindingScope = .frame) -> MTLTexture? {
        let variant = max(0, instance.frameIndex - 1) % graphs.executors.count
        let physical = resourceBindings[scope]?[id] ?? id
        return graphs.executors[variant].transientTextures[physical] ?? targets[physical]
    }

    var aliasedRenderTargets: Set<WPEResourceID> {
        graphs.aliasedTargets
    }

    /// The sampler a draw binds when it samples `texture` as a scene render target.
    func targetSampler(of texture: MTLTexture) -> WPEParitySamplerState? {
        targetSamplers[ObjectIdentifier(texture)]
    }

    /// Heaps of the current graphs and of the graphs cached for a visibility toggle back.
    var retainedGraphHeaps: [MTLHeap] {
        (graphs.executors + (previousGraphs?.executors ?? [])).compactMap(\.heap)
    }
    #endif

    var skipped: [Int: WPEParityFrameSkip] {
        var result = graphs.layout.skipped
        for (index, description) in graphs.layout.frames[0].draws {
            if case let .scene(draw) = description, case .particles = draw.geometry,
               let failure = graphs.particleSnapshotSkips[draw.objectID] {
                result[index] = failure
                continue
            }
            if case let .scene(draw) = description, case let .particles(key) = draw.geometry,
               let failures = particleBaseFailures[draw.objectID],
               let failure = failures.first(where: { key.path.starts(with: $0.key) })?.value {
                result[index] = failure
            }
        }
        return result
    }

    var drawCount: Int {
        frames[0].operations.count {
            if case .draw = $0.kind {
                true
            } else {
                false
            }
        }
    }

    /// Pipeline states built over the renderer's life; an effect toggle builds none.
    var pipelineCreations: Int {
        planner.pipelineCreations
    }

    /// Render graph sets compiled after init; the graphs built during init are not counted.
    var graphCompilations = 0

    private var draws: [Int: WPEParityFrameDrawPlan] {
        graphs.layout.draws
    }

    var executedDrawCount: Int {
        draws.count
    }

    /// Particle batches dropped because a frame's particle draws outgrew their arena share or the arena.
    var droppedParticleBatches: Int {
        let current = graphs.executors.reduce(instance.particles.dropped + retiredDrops) { $0 + $1.droppedDraws }
        return previousGraphs?.executors.reduce(current) { $0 + $1.droppedDraws } ?? current
    }

    /// Arena bytes a frame's particle draws may take now.
    var particleShare: Int {
        instance.particles.budget
    }

    /// Live particles of a particle object, children included.
    func particleLiveCount(_ objectID: String) -> Int? {
        instance.particles.scene.liveCount(objectID)
    }

    /// Per encoded draw, declared textures the frame does not have, bound to a transparent texel.
    var fallbackTextures: [Int: [String]] {
        draws.mapValues(\.fallbackTextures).filter { !$0.value.isEmpty }
    }

    func particleRenderer(_ operation: Int) -> WPEParityParticleRenderer? {
        guard case let .particles(particle)? = draws[operation]?.geometry else { return nil }
        return particle.renderer
    }

    /// Per encoded draw and stage, the binding description's constants.
    var constants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] {
        draws.mapValues(\.constants)
    }

    /// The engine matrices draw `operation` packs for the current frame.
    func uniforms(_ operation: Int) throws -> WPEParityUniformDraw? {
        try draws[operation]?.frameUniforms(parallax: instance.parallax.smoothed, camera: pathCamera,
                                            layers: layersMoved ? layers : nil)
    }

    /// The published camera pose with the layer renderer's current parallax controls.
    var pathCamera: WPEParityCamera {
        var selected = instance.camera
        let parallax = cameraParallax
        selected.parallaxAmount = parallax.enabled && selected.scenePerspective == nil ? Float(parallax.amount) : nil
        return selected
    }

    var heapBytes: Int {
        graphs.executors.reduce(0) { $0 + ($1.heap?.size ?? 0) }
    }

    var arenaBytes: Int {
        arena.capacity * WPEParityFrameArena.slotCount
    }

    /// Nothing the scene loaded changes its frame: no keyframe animation, particle, video, puppet, camera path,
    /// camera shake or parallax, multi-frame sprite sheet, script, audio processing, or program reading a per-frame engine input.
    private let hasStaticBase: Bool
    var isStatic: Bool {
        hasStaticBase && videos.sourceCount == 0 && !cameraParallax.enabled && cameraShake == nil && !instance.cameraQueues.values.contains {
            $0.hasEligibleItems && instance.state.isAlive($0.objectID) && instance.state.isVisible($0.objectID)
        } && instance.userShortcutIcons?.videoURLs.isEmpty != false
    }

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
    }

    /// The fixed textures video .tex draws sample.
    var videoTextures: [MTLTexture] {
        videos.textures
    }

    var pendingVideoLayout: PendingVideoLayout?
    var deferredVideoFrame: DeferredVideoFrame?

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        videos.applyPerformanceProfile(profile)
    }

    #if DEBUG
    nonisolated(nonsending) func seekVideosForCapture(to seconds: Double) async {
        await videos.seekForCapture(to: seconds)
    }
    #endif

    /// A resize reuses the video collection. Keeping that collection as the command target avoids retaining or
    /// calling the old renderer through a SceneScript engine that continues into the new frame plan.
    var scriptVideoPause: (String) -> Bool {
        { [weak videos] ownerID in videos?.pause(ownerID: ownerID) ?? false }
    }

    var scriptVideoCommand: (String, WPEParityScriptEngine.VideoCommand, Double) -> Double? {
        { [weak videos] ownerID, command, argument in videos?.command(ownerID: ownerID, command, argument: argument) }
    }

    var scriptMaterialFunction: (WPEParitySceneState.EffectKey, String) -> Void {
        { [weak self] key, name in self?.executeMaterialFunction(key, name: name) }
    }

    /// Nil for a layer whose own image has no sprite sheet; the first call creates the layer's joined state.
    var scriptTextureAnimation: (String, WPEParityScriptEngine.TextureAnimationCommand, Double) -> Double? {
        { [weak self] id, command, value in
            guard let self else { return nil }
            let steps = planner.layerSprites(id)
            guard !steps.isEmpty else { return nil }
            return instance.textureAnimations[id, default: WPEParityTextureAnimation()].perform(
                command, value: value, shared: WPEParityFrameDrawPlan.sharedSprite(steps, at: instance.clock.time),
                durations: steps.map { Float($0.duration) }
            )
        }
    }

    /// Nil when the layer has no puppet or the puppet has no layer at that `animationlayers` index.
    var scriptAnimationLayer: (String, Int, WPEParityScriptEngine.AnimationLayerCommand, Double) -> Double? {
        { [weak self] id, index, command, value in
            guard let self, let layer = instance.puppets[id]?.layers.first(where: { $0.sceneIndex == index }) else { return nil }
            switch command {
            case .play: instance.puppets[id]?.controlLayer(at: index, action: .play)
            case .pause: instance.puppets[id]?.controlLayer(at: index, action: .pause)
            case .stop: instance.puppets[id]?.controlLayer(at: index, action: .stop)
            case .setFrame: instance.puppets[id]?.controlLayer(at: index, action: .setFrame(Float(value)))
            case .isPlaying: return layer.isPlaying ? 1 : 0
            case .getFrame: return Double(layer.frame)
            case .fps: return Double(layer.fps)
            case .frameCount: return Double(layer.animation.frameCount)
            case .duration: return Double(layer.duration)
            }
            return 0
        }
    }

    /// Writes land in the puppet the draw planner reads after this frame's script tick.
    var scriptPuppet: (String, (inout WPEParityPuppetAnimator) -> Void) -> Bool {
        { [weak self] id, body in
            guard let self, instance.puppets[id] != nil else { return false }
            body(&instance.puppets[id]!)
            return true
        }
    }

    /// Nil when the object has no loaded particle system.
    var scriptParticleSystem: (String, WPEParityScriptEngine.ParticleCommand, Int32) -> Double? {
        { [weak self] id, command, count in
            self?.instance.particles.scene.control(objectID: id) { system in
                switch command {
                case .play: system.play()
                case .pause: system.pause()
                case .stop: system.stop()
                case .isPlaying: return system.isPlaying ? 1 : 0
                case .emitParticles: system.emitParticles(count)
                }
                return 0
            }
        }
    }

    /// Answers from the callback's own state on a copy of the layer worlds; `self.state` lags a callback's writes.
    var scriptTransformMatrix: (String, WPEParityScriptLayerKind, WPEParitySceneState) -> simd_float4x4? {
        { [weak self] id, kind, state in
            guard let self, layers.layers[id] != nil else { return nil }
            var transforms = layers
            for (index, objectID) in state.ids.enumerated() {
                let object = state.objects[index]
                transforms.setTransform(objectID, origin: object.origin, angles: object.angles, scale: object.scale)
            }
            transforms.refreshWorlds { self.instance.puppets[$0]?.boneWorld }
            // 1401fd3f0: an image answers its alignment-shifted W′; other objects answer W.
            return kind == .image ? transforms.model(id) : transforms.world(id)
        }
    }

    private func executeMaterialFunction(_ key: WPEParitySceneState.EffectKey, name: String) {
        guard let metadata = plan.scene.resolvedMaterialFunctions[key] else { return }
        do {
            let requested = try metadata.clearTargets(named: name)
            guard !requested.isEmpty else { return }
            let scope = WPEResourceBindingScope.effect(objectID: key.objectID, effectID: key.effectID)
            let bound = try WPEParityGraphExecutor.scopedTextures(targets, bindings: resourceBindings, scope: scope)
            guard let resources = plan.materialFunctionResources(key, names: requested.map(\.name),
                                                                 texts: planner.texts) else {
                throw WPEParityGraphExecutionError.missingTexture(WPEResourceID(key.effectID))
            }
            var accepted: [MaterialClear] = []
            accepted.reserveCapacity(requested.count)
            for (target, logical) in zip(requested, resources) {
                guard let texture = bound[logical] else {
                    throw WPEParityGraphExecutionError.missingTexture(logical)
                }
                accepted.append(MaterialClear(texture: texture, color: target.clearColor))
            }
            materialClears += accepted
        } catch {
            Logger.warning("Parity material function \(key.objectID)/\(key.effectID)/\(name) unavailable: \(error)",
                           category: .wpeRender)
        }
    }

    /// GraphExecutor only invokes prepare on a buffer it will commit, including an encoded prefix on failure.
    /// Drop each successfully encoded request, retaining the failing request and all later requests for retry.
    private func encodeMaterialClears(on commandBuffer: MTLCommandBuffer) throws {
        var encoded = 0
        defer { materialClears.removeFirst(encoded) }
        for request in materialClears {
            try WPEParityGraphExecutor.encodeColorClear(request.texture, color: request.color, on: commandBuffer)
            encoded += 1
        }
    }

    /// Resize initialization must follow previously accepted calls on the same queue. No arena slot is needed
    /// for these color-only commands; normal frames still consume their commands through GraphExecutor.prepare.
    private func submitMaterialClears() throws {
        guard !materialClears.isEmpty else { return }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw WPEParityFrameRenderError.encoderUnavailable }
        do {
            try encodeMaterialClears(on: commandBuffer)
        } catch {
            commandBuffer.commit()
            throw error
        }
        commandBuffer.commit()
    }

    /// The text layers' glyph atlases as last uploaded.
    var textAtlases: [String: WPEParityGlyphAtlasInstance] {
        planner.textAtlases.atlases
    }

    /// Each text layer as its draws were last planned.
    var texts: [String: WPEParitySceneText] {
        planner.texts
    }

    var conditionalPropertyBindings: [String: [WPEScenePropertyBinding]] {
        planner.conditionalPropertyBindings
    }

    /// Built on the first text change, from the layers and atlases as loaded.
    lazy var textPipeline = WPEParityTextPipeline(
        assets: plan.scene.assets, hdr: plan.scene.engineFlags.hdr,
        orthographic: plan.scene.engineFlags.orthographicProjection,
        texts: plan.scene.scene.objects.compactMap { object in
            if case let .text(text) = object.kind {
                planner.texts[object.id] ?? text
            } else {
                nil
            }
        },
        atlases: planner.textAtlases.atlases
    )
    /// nil is the normal product path. Explicit diagnostic hosts start a count interval after load.
    var textReplanDiagnostics: TextReplanDiagnostics?

    /// CPU frame-layout reuse for admitted direct glyph extent changes. Resolved once at construction.
    let reusesDirectTextExtentLayouts: Bool

    /// Requests remain ordered until the CPU/GPU cohort is accepted; repeated objects are meaningful.
    var textRequests: [WPEParityTextPipeline.RelayoutRequest] = []
    var pendingScriptTextGeneration: Int?
    var pendingTextEffectsGeneration: Int?
    /// Only a previously attempted failed prefix; later unattempted input must remain ordered.
    var failedTextRequestCount = 0

    #if DEBUG
    /// Runs after all fallible GPU preparation, before CPU accept. Tests may inject one explicit failure.
    var textPreparationCheckpoint: ((TextPreparationSnapshot) throws -> Void)?
    #endif

    /// `particleArenaBytes` fixes each frame's particle share; nil grows it to each frame's measured particle demand.
    /// `workshopID` keys the video disk cache; nil uses the scene directory's name.
    nonisolated(nonsending) init(plan: WPEParityFramePlan, device: MTLDevice, queue: MTLCommandQueue, shaders: WPEParityFrameShaderSource,
                                 particleSeed: UInt32 = WPEParityParticleScene.productSeed(), particleArenaBytes: Int? = nil,
                                 workshopID: String? = nil, continuing previous: WPEParityFrameRenderer? = nil,
                                 userPropertiesJSON: String = "{}",
                                 textureCompression: WPEParityTextureCompression? = .resolve(),
                                 reuseDirectTextExtentLayouts: Bool? = nil) async throws {
        reusesDirectTextExtentLayouts = Self.resolveDirectTextExtentReuse(explicit: reuseDirectTextExtentLayouts)
        let factory = WPEParityPipelineFactory(device: device)
        let encoder = WPEParityDrawEncoder(factory: factory)
        var planner = try WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan,
                                                    preservingVideoImages: previous?.planner.videoImages ?? [:],
                                                    userProperties: Self.propertySnapshot(userPropertiesJSON), textureCompression: textureCompression)
        // Disabled effects' programs too, so a toggle compiles nothing.
        let artifacts = await withTaskGroup(
            of: (WPEHLSLProgram, Result<WPEParityShaderArtifact, WPEParityFrameSkip>).self
        ) { group in
            for program in plan.loadPrograms {
                group.addTask {
                    do {
                        return try await (program.hlsl, .success(shaders.artifact(for: program)))
                    } catch {
                        return (program.hlsl, .failure(.noShader("\(program.shader): \(error)")))
                    }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        try Task.checkCancellation()
        if shaders.requireAllPrograms {
            for artifact in artifacts.values {
                if case let .failure(reason) = artifact {
                    throw WPEParityFrameRenderError.requiredShaderUnavailable(reason.description)
                }
            }
        }
        let probes = try plan.probeFrames()
        var mipRequested = plan.requestsMipMappedFrameBuffer(in: probes, artifacts: artifacts)
        var particleFacts: [String: [[WPEParityParticlePathElement]: Bool]] = [:]
        var particleFailures: [String: WPEParityFrameSkip] = [:]
        var baseFailures: [String: [[WPEParityParticlePathElement]: WPEParityFrameSkip]] = [:]
        for probe in plan.particleMaterials {
            switch probe.material {
            case let .unavailable(reason):
                particleFailures[probe.objectID] = .program(reason)
                baseFailures[probe.objectID, default: [:]][probe.path] = .program(reason)
            case let .ready(program, names):
                guard case let .success(artifact)? = artifacts[program.hlsl] else {
                    particleFailures[probe.objectID] = artifacts[program.hlsl].flatMap {
                        if case let .failure(failure) = $0 {
                            return failure
                        }
                        return nil
                    } ?? .noShader("particle base material: \(program.shader)")
                    baseFailures[probe.objectID, default: [:]][probe.path] = particleFailures[probe.objectID]
                    continue
                }
                // Native material+0x1fc uses only active VS/PS Texture slots, not GS or entry overrides.
                let active = (artifact.vertex.reflection.resources + artifact.fragment.reflection.resources)
                    .filter { $0.kind == .texture }
                particleFacts[probe.objectID, default: [:]][probe.path] = active.contains {
                    names[Int32($0.register)] == WPEParitySceneResource.fullFrameBuffer.rawValue
                }
                mipRequested = mipRequested || active.contains {
                    names[Int32($0.register)] == "_rt_MipMappedFrameBuffer"
                }
            }
        }
        // Objects the continued scene removed must not be planned, or their images would load again.
        var loaded = plan.state
        for id in plan.state.ids where previous?.instance.state.isAlive(id) == false {
            loaded.removeObject(id)
        }
        let planned = mipRequested || loaded.membershipGeneration != plan.state.membershipGeneration
            ? try plan.layout(effects: loaded, mipMappedFrameBufferRequested: mipRequested) : plan.layout
        let layout = try Self.makeLayout(planned, effects: plan.state.effectVisibility, artifacts: artifacts,
                                         planner: &planner, encoder: encoder,
                                         state: plan.state, reusing: nil)
        for probe in probes {
            let targets = WPEParityFrameDrawPlanner.targets(probe.frame)
            let resources = WPEParityFrameDrawPlanner.resources(probe.frame)
            for (index, description) in probe.frame.draws {
                let required = Self.requiredPost(description)
                guard let program = probe.programs[index],
                      case let .success(artifact)? = artifacts[program.hlsl] else {
                    if let required {
                        var reason = probe.skipped[index] ?? WPEParityFrameSkip.noShader("Required utility variant was not prepared")
                        if let unresolved = probe.programs[index],
                           case let .failure(failure)? = artifacts[unresolved.hlsl] {
                            reason = failure
                        }
                        throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                            pass: required, reason: reason
                        )
                    }
                    continue
                }
                do {
                    try planner.prewarmPipeline(probe.frame, index, targets: targets, resources: resources,
                                                program: program, artifact: artifact)
                } catch {
                    if let required {
                        throw WPEParityFrameRenderError.requiredPostProcessUnavailable(pass: required, reason: error)
                    }
                }
                if plan.post.hdrEnabled, let required, required == "combine_hdr" || required == "combine_srgb" {
                    try Self.validatePresentation(program, pass: required, post: plan.post)
                }
            }
        }
        let draws = layout.draws

        try planner.fillImportedImages()
        // A continued renderer has not committed its live state yet. New streams stay in its planner until
        // the first live graph selection can stage the ordinary admission transaction.
        let streams = previous == nil ? planner.takeVideoStreams() : []
        let videos: WPEParityVideoTextures = if let previous {
            previous.videos
        } else {
            try await WPEParityVideoTextures(streams: streams,
                                             workshopID: workshopID ?? plan.scene.assets.roots[0].lastPathComponent, device: device, queue: queue)
        }

        var videoOwners: [String: MTLTexture] = [:]
        let videoTextures = Set(videos.textures.map(ObjectIdentifier.init))
        for (index, draw) in layout.draws {
            guard case let .scene(description)? = layout.frames[0].draws[index], description.effectID == nil,
                  let source = draw.textures.first?["g_Texture0"] else { continue }
            let texture: MTLTexture? = switch source {
            case let .image(image): image
            case let .resource(id): planner.layerImages[id]
            }
            if let texture, videoTextures.contains(ObjectIdentifier(texture)) {
                videoOwners[description.objectID] = texture
            }
        }
        videos.setOwners(videoOwners)

        let particleBytes = particleArenaBytes ?? draws.values.reduce(0) { total, draw in
            guard case let .particles(particle) = draw.geometry else { return total }
            return total + WPEParityFrameArena.aligned(particle.maxBytes) + particle.argumentBytes
        }
        let baseArenaBytes = Self.baseArenaBytes(layout, shadowBatches: 1)
        guard let arena = WPEParityFrameArena(device: device, capacity: baseArenaBytes + particleBytes) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        var targets: [WPEResourceID: MTLTexture] = [:]
        try Self.prepareHDRBloomTargets(plan.post, device: device, targets: &targets)
        let snapshotObjects = Set(particleFacts.filter { $0.value.values.contains(true) }.map(\.key))
        let graphs = try Self.makeGraphs(layout: layout, state: plan.state, device: device, encoder: encoder,
                                         arena: arena, targets: &targets, snapshotObjects: snapshotObjects,
                                         aliasing: Self.aliasesRenderTargets(plan))
        if let atlas = layout.frames.flatMap(\.resources).first(where: { $0.id == WPEParitySceneResource.shadowAtlas }) {
            targets[atlas.id] = try Self.makeTarget(atlas, device: device)
        }
        guard let backbuffer = targets[WPEParitySceneResource.backbuffer] else {
            throw WPEParityFrameRenderError.missingBackbuffer
        }
        try Self.clear(Array(targets.values) + (previous == nil ? videos.textures : []), queue: queue,
                       colors: Self.clearColors(layout, targets: targets))

        self.graphs = graphs
        self.plan = plan
        self.planner = planner
        textBackgroundOwners = Dictionary(uniqueKeysWithValues: planner.texts.values.map { ($0.backgroundPass, $0.object.id) })
        lights = planner.lights
        self.artifacts = artifacts
        mipMappedFrameBufferRequested = mipRequested
        particleFullFrameBuffer = particleFacts
        particleBaseFailures = baseFailures
        particleSnapshotObjects = snapshotObjects
        particleMaterialSkips = particleFailures
        self.device = device
        drawEncoder = encoder
        var constantComponents: [WPEParityMaterialPassKey: [String: Int]] = [:]
        for binding in plan.bindings.joined().map(\.value) {
            guard let pass = binding.materialPass else { continue }
            for constant in binding.materialConstants.values.joined() {
                constantComponents[pass, default: [:]][constant.material] = constant.components
            }
        }
        let animations = WPEParitySceneAnimations(document: plan.document, state: plan.state,
                                                  constantComponents: constantComponents)
        self.backbuffer = backbuffer
        self.targets = targets
        targetSamplers = Self.targetSamplers(graphs, targets: targets)
        self.videos = videos
        videoWorkshopID = workshopID ?? plan.scene.assets.roots[0].lastPathComponent
        self.queue = queue
        self.arena = arena
        self.baseArenaBytes = baseArenaBytes
        growsParticleShare = particleArenaBytes == nil
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        rootCamera = WPEParityCamera.root(document: plan.document,
                                          renderTargetSize: SIMD2(Float(plan.width), Float(plan.height)),
                                          alignment: plan.alignment,
                                          orthoWithoutPaths: plan.scene.engineFlags.orthographicProjection
                                              && plan.scene.cameraPaths.paths.isEmpty)
        generalZoom = Float(plan.document.general.zoom)
        layers = planner.layers
        let particleObjects = plan.scene.scene.objects.compactMap { object -> (id: String, index: Int?)? in
            if case .particle = object.kind {
                (object.id, plan.state.index(of: object.id))
            } else {
                nil
            }
        }
        self.particleObjects = particleObjects
        let prewarm = Self.particleFrames(particleObjects, state: plan.state, layers: planner.layers,
                                          camera: planner.layers.camera, time: 0, cursor: nil)
        let sceneRNG = previous?.instance.sceneRNG ?? WPEParityMT19937(seed: particleSeed)
        let particles: WPEParityParticleFrame
        let cameraQueues: [String: WPEParityCameraQueue]
        if let previous {
            // Replanning must not prewarm new systems or consume the continuing scene random stream.
            particles = previous.instance.particles
            cameraQueues = previous.instance.cameraQueues
        } else {
            particles = WPEParityParticleFrame(
                scene: WPEParityParticleScene(document: plan.document, assets: plan.scene.assets,
                                              engineFlags: plan.scene.engineFlags, seed: particleSeed,
                                              frames: prewarm, rng: sceneRNG), budget: particleBytes
            )
            var queues: [String: WPEParityCameraQueue] = [:]
            for object in plan.document.paritySeeds.objects {
                guard object.isCamera,
                      let queue = try WPEParityCameraQueue(header: object, assets: plan.scene.assets,
                                                           randomInteger: { sceneRNG.integer($0, $1) })
                else { continue }
                queues[queue.objectID] = queue
            }
            cameraQueues = queues
        }
        let skinned = plan.scene.scene.objects.filter {
            $0.puppet?.skinned == true && plan.scene.puppetModels[$0.id] != nil
        }
        let document = plan.document
        hasStaticBase = animations.isEmpty && particleObjects.isEmpty
            && !(mipRequested && plan.post.qualityMipMappedFrameBufferEnabled)
            && videos.textures.isEmpty && skinned.isEmpty
            && plan.scene.cameraPaths.paths.isEmpty && !document.general.supportsAudioProcessing
            && !draws.values.contains { $0.sprites.values.contains { $0.count > 1 } }
            && !plan.loadPrograms.contains(where: Self.readsFrameInputs)
            && !WPEParitySceneScript.hasScripts(document)
        var puppets: [String: WPEParityPuppetAnimator] = [:]
        for object in skinned {
            guard let model = plan.scene.puppetModels[object.id] else { continue }
            let layers = plan.document.imageObjects.first { $0.id == object.id }?.animationLayers ?? []
            puppets[object.id] = WPEParityPuppetAnimator(model: model, layers: layers)
        }
        instance = WPEParitySceneInstance(
            clock: WPEParityClock(), pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
            cameraPaths: plan.scene.cameraPaths, cameraPose: nil, activeCameraID: nil, audio: WPEParityAudioSpectrum(),
            textureSlots: [:], renderVars: WPEParityRenderVarState(), puppets: puppets, pushedAnimationLayerFields: [:],
            textureAnimations: [:], particles: particles, sceneRNG: sceneRNG, cameraQueues: cameraQueues, frameIndex: 0,
            state: plan.state, animations: animations, camera: rootCamera, script: nil, media: nil, mediaGeneration: 0,
            mediaTextures: nil, userShortcutIcons: nil, mediaDiagnostics: [], seenScriptSound: 0,
            seenSoundBoundsFields: -1, seenScriptLighting: -1, seenScriptBloom: 0, bloom: plan.post.bloomSettings
        )
    }

    /// WPE's HLSL declares only the engine uniforms its combos leave live, so a mention is a read.
    private static func readsFrameInputs(_ program: WPEParityProgram) -> Bool {
        let inputs = ["g_Time", "g_Frametime", "g_Daytime", "g_Pointer", "g_AudioSpectrum", "g_ParallaxPosition"]
        return [program.hlsl.vertex, program.hlsl.geometry, program.hlsl.fragment].contains { stage in
            guard let source = stage.flatMap({ String(bytes: $0, encoding: .utf8) }) else { return false }
            return inputs.contains { source.contains($0) }
        }
    }

    /// Picks up `previous`'s scene where it stopped, for the same document planned at another size.
    func adoptView(from previous: WPEParityFrameRenderer, userPropertiesJSON: String? = nil) throws {
        try previous.submitMaterialClears()
        instance = previous.instance.copy()
        buttonEdges = previous.buttonEdges
        // Script registrations belong to the same scene and shader store; resizing changes draw targets only.
        artifacts.merge(previous.artifacts) { current, _ in current }
        arena.capacity = baseArenaBytes + instance.particles.budget
        resourceBindings = try migratedBindings(from: previous)
        // A resize is a real storage transaction. Compatible named RTs preserve history unless authored clear
        // requests initialization at resize; the new backbuffer always belongs to the new renderer.
        for resource in graphs.layout.frames.flatMap(\.resources) where resource.id != WPEParitySceneResource.backbuffer {
            guard resource.lifetime != .imported, let old = previous.targets[resource.id],
                  Self.matches(old, resource: resource) else { continue }
            targets[resource.id] = old
        }
        targetSamplers = Self.targetSamplers(graphs, targets: targets)
        let clearColors = Self.clearColors(graphs.layout, targets: targets)
        try Self.clear(targets.values.filter { clearColors[ObjectIdentifier($0)] != nil }, queue: queue,
                       colors: clearColors)
        instance.camera.renderTargetSize = rootCamera.renderTargetSize
        instance.camera.size = rootCamera.size
        lights = previous.lights
        shadowLayout = previous.shadowLayout
        reserveArena(for: graphs.layout)
        // The next frame takes the transforms, visibility and effects over from the copied state.
        seenTransforms = previous.layersMoved ? -1 : 0
        seenVisibility = -1
        seenEffects = -1
        seenMembership = -1
        seenModelData = -1
        for object in previous.plan.scene.scene.objects {
            guard let text = previous.planner.texts[object.id] else { continue }
            textRequests.append(.init(text.object, effectCount: text.effectCount))
        }
        // Resize handlers may call material functions on dynamically relaid text FBOs. Prepare those actual
        // targets first, and only replace the engine callback after all throwing adoption work succeeds.
        guard try replanRelaidTexts() else {
            throw WPEParityFrameSkip.videoTexture("Text preparation requires an unprepared video stream")
        }
        if let userPropertiesJSON {
            let snapshot = try Self.propertySnapshot(userPropertiesJSON)
            try replaceConditionalProperties(changed: snapshot, merged: snapshot)
        }
        instance.script?.engine.materialFunctionHandler = scriptMaterialFunction
        instance.script?.engine.transformMatrixHandler = scriptTransformMatrix
        instance.script?.engine.textureAnimationHandler = scriptTextureAnimation
        instance.script?.engine.animationLayerHandler = scriptAnimationLayer
        instance.script?.engine.puppetHandler = scriptPuppet
        instance.script?.engine.particleSystemHandler = scriptParticleSystem
        instance.script?.engine.propertyAnimationLookup = { [animations = instance.animations] in
            animations.animation(objectID: $0, pass: $1, name: $2)
        }
        instance.script?.engine.modelDataAdmissionHandler = scriptModelDataAdmission
        instance.script?.resize(canvasSize: instance.camera.size, screenResolution: logicalSize,
                                state: &instance.state)
        repackBloom()
    }

    /// Advances the clock by `elapsed` seconds and the engine inputs by one frame, then commits the frame.
    /// `paused` ramps scene time down to a hold, and back up once it is false again.
    func encodeFrame(elapsed: Double, paused: Bool = false, forceExternalFrame: Bool = false,
                     input: WPEParityFrameInput = WPEParityFrameInput(),
                     completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) throws -> WPEParityGraphExecutor.Submission {
        deferredVideoFrame = nil
        // Native object updates precede this frame's camera selection and matrix-stack publication.
        let objectCamera = pathCamera
        if forceExternalFrame, paused {
            instance.clock.holdForExternalFrame()
        } else {
            guard instance.clock.advance(elapsed: elapsed, paused: paused) else { return .skipped }
        }
        let edges = buttonEdges
        buttonEdges.removeAll()
        let shortcutIcons = instance.userShortcutIcons
        videos.bindUserVideos(shortcutIcons?.videoURLs ?? [:])
        let time = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: input.date)
        let daytime = WPEParityClock.daytime(hour: time.hour ?? 0, minute: time.minute ?? 0,
                                             second: time.second ?? 0, millisecond: (time.nanosecond ?? 0) / 1_000_000)
        applyAnimationLayerFields()
        // Scene time, so a paused clock holds the pose.
        for id in instance.puppets.keys {
            instance.puppets[id]?.advance(dt: Double(instance.clock.frametime))
        }
        for id in instance.textureAnimations.keys {
            instance.textureAnimations[id]?.step(dt: instance.clock.frametime, durations: planner.layerSprites(id).map { Float($0.duration) })
        }
        instance.pointer.advance(cursor: input.cursor, screen: screen, buttonDown: input.buttonDown)
        let scriptPointer = (input.scriptCursor ?? input.cursor) / screen.size
        let scriptCursor = scriptPointer * logicalSize
        // Far enough that cursor-following emitters spawn out of sight and attract/repel thresholds miss the picture.
        let particleCursor = input.cursorOverPicture ? instance.pointer.position : SIMD2<Float>(-1000, -1000)
        applyTransforms()
        applyLayerFields()
        updateSceneObjects(camera: objectCamera, timeOfDay: daytime, particleCursor: particleCursor)
        selectCamera(dt: instance.clock.frametime)
        // A cleared camerafade flag hides the fade each frame; setting it back cannot add a fade that never loaded.
        var fadeAlpha = instance.cameraPaths.fadeAlpha
        if case let .vector(value)? = instance.state.scriptField("camerafade", of: ""), value.x == 0 {
            fadeAlpha = 0
        }
        let camera = pathCamera
        // 1401891a0.c:288: the smoothed parallax only moves while camera parallax is on.
        let updateParallax = cameraParallax
        if updateParallax.enabled {
            instance.parallax.advance(pointer: instance.pointer.position, mouseInfluence: Float(updateParallax.mouseInfluence),
                                      delay: Float(updateParallax.delay), eye: SIMD2(camera.eye.x, camera.eye.y),
                                      ortho: camera.size,
                                      frametime: instance.clock.frametime)
        }
        instance.audio.advance(left: input.audio?.left ?? Self.silence, right: input.audio?.right ?? Self.silence,
                               dt: instance.clock.frametime, silence: input.audio == nil)
        var frameUniforms = WPEParityUniformFrame(clock: instance.clock, daytime: daytime, screen: screen, pointer: instance.pointer,
                                                  parallax: instance.parallax, eyePosition: camera.eyePosition,
                                                  view: camera.view, audio: instance.audio)
        if let script = instance.script {
            script.prepareFrame(frame: UInt64(instance.frameIndex), dt: instance.clock.frametime, runtime: instance.clock.timeUniform,
                                cursor: scriptCursor, world: camera.cursorWorld(normalizedPointer: scriptPointer),
                                leftDown: input.buttonDown, timeOfDay: daytime)
            script.updateAudio(instance.audio.bins)
            try runScriptEvents(script, camera: camera, pointer: scriptPointer, edges: edges,
                                buttonDown: input.buttonDown, timeOfDay: daytime)
        }
        consumeMediaInputs()
        // Animations run after the object update and the camera, and render reads their values.
        instance.animations.advance(dt: instance.clock.frametime, state: &instance.state)
        if let script = instance.script {
            for event in instance.animations.firedEvents {
                script.engine.dispatch(.animationEvent, payloadJSON: event.payloadJSON, target: event.objectID, state: &instance.state)
            }
            script.engine.videoEnded(ownerIDs: videos.takeEndedOwnerIDs(), state: &instance.state)
            // 140171440.c:888-896: the tick after the animations, so update sees this frame's animated values.
            script.tick(dt: instance.clock.frametime, cursor: scriptCursor,
                        world: camera.cursorWorld(normalizedPointer: scriptPointer), leftDown: input.buttonDown, timeOfDay: daytime, state: &instance.state)
        }
        if let failure = instance.script?.engine.executionFailure {
            throw failure
        }
        // 18aac0 reads the post-tick Bool/amount with the smoother already advanced by 1891a0 above.
        let renderCamera = pathCamera
        videos.applyScriptFields(state: &instance.state)
        applyTransforms()
        applyLayerFields()
        applyScriptBloom()
        try applyScriptLighting(camera: renderCamera)
        frameUniforms.lights = lights
        let uniforms = frameUniforms
        applyScriptText()
        // Keep the existing ordered text requests, but do not publish a different planner underneath
        // an in-flight admission on every text tick. The first admitted frame processes the queue.
        var textsReady = true
        if pendingVideoAdmission == nil {
            textsReady = try replanRelaidTexts()
        }
        // 14018aac0.c:206 keys with g_ViewForward, which comes from the pre-script camera (14017fa70.c:383-387).
        if plan.scene.scene.transparentSorting {
            instance.state.sortTransparentMembers(viewForward: WPEParityUniformParallax.viewVectors(view: camera.view).forward)
        }
        if !textsReady {
            // Sorting may change membershipGeneration; stamp the private admission only after that change.
            try requestTextVideoAdmission()
        }
        guard try selectGraphs() else {
            deferredVideoFrame = DeferredVideoFrame(uniforms: uniforms, camera: renderCamera, fadeAlpha: fadeAlpha)
            return .skipped
        }
        return try encodeSelectedFrame(uniforms: uniforms, renderCamera: renderCamera, fadeAlpha: fadeAlpha, completion: completion)
    }

    func encodeSelectedFrame(uniforms: WPEParityUniformFrame, renderCamera: WPEParityCamera, fadeAlpha: Float,
                             completion: (@Sendable (MTLCommandBuffer) -> Void)?) throws -> WPEParityGraphExecutor.Submission {
        #if DEBUG
        let pipelinesBefore = pipelineCreations, graphsBefore = graphCompilations
        defer {
            assert(pipelineCreations == pipelinesBefore && graphCompilations == graphsBefore,
                   "encodeSelectedFrame must consume the selected graphs, not build pipelines or graphs")
        }
        #endif
        let shortcutIcons = instance.userShortcutIcons
        let graphs = graphs
        let draws = graphs.layout.draws
        let live = layersMoved ? layers : nil
        let variant = instance.frameIndex % graphs.executors.count
        instance.frameIndex += 1
        let dropped = droppedParticleBatches
        defer {
            videos.finishFrame()
            if growsParticleShare, droppedParticleBatches > dropped, instance.particles.budget < Self.maxParticleShare {
                instance.particles.budget = min(instance.particles.budget * 2, Self.maxParticleShare)
                arena.capacity = baseArenaBytes + instance.particles.budget
            }
        }
        #if DEBUG
        lastFrameDraws.removeAll(keepingCapacity: true)
        #endif
        lastFrameOperations.removeAll(keepingCapacity: true)
        let executor = graphs.executors[variant]
        executor.restoreResourceBindings(resourceBindings)
        // Encoding can throw after submitting a prefix. Carry every reached swap into the next frame too.
        defer { resourceBindings = executor.resourceBindings }
        // A failed stream is kept so its error surfaces where the block encodes, after the frame's earlier steps.
        var particleStreams: [Int: Result<WPEParityParticleDrawStream, any Error>] = [:]
        let blocks = graphs.layout.frames[variant].particleBlocks
        func stream(for block: Int) throws -> WPEParityParticleDrawStream? {
            if let cached = particleStreams[block] {
                return try cached.get()
            }
            let particleBlock = blocks[block]
            let objectID = particleBlock.objectID
            let facts = particleFullFrameBuffer[objectID, default: [:]]
            let failures = particleBaseFailures[objectID, default: [:]]
            let worldModel = particleBlock.compositeOwnerID.map { layers.model($0).inverse }
                ?? matrix_identity_float4x4
            let stream = Result {
                try instance.particles.scene.drawStream(objectID: objectID, ownerModel: layers.world(objectID),
                                               worldModel: worldModel) { path in
                    if failures[path] != nil {
                        return nil
                    }
                    guard let fact = facts[path] else {
                        throw WPEParityFrameSkip.program("missing particle base-material fact: \(objectID) \(path)")
                    }
                    return fact
                }
            }
            particleStreams[block] = stream
            return try stream.get()
        }
        var particleDemand = 0
        for case let .particlePrefix(block) in graphs.operations[variant] {
            guard let stream = try? stream(for: block) else { continue }
            for batch in stream.batches {
                guard let operation = graphs.particleDraws[batch.key],
                      case let .particles(particle)? = draws[operation]?.geometry else { continue }
                particleDemand += WPEParityFrameArena.aligned(batch.vertices.bytes.count) + particle.argumentBytes
            }
        }
        // The arena takes a new capacity only when a frame begins, so the share is sized before encoding.
        if growsParticleShare, particleDemand > instance.particles.budget {
            instance.particles.budget = min(max(particleDemand, instance.particles.budget * 2), Self.maxParticleShare)
            arena.capacity = baseArenaBytes + instance.particles.budget
        }
        var submitted = false
        defer {
            if submitted {
                let bound = drawVideoSources ?? bindVideoSources()
                videos.recordSampled(sources: lastFrameOperations.lazy.flatMap { bound[$0] ?? [] })
            }
        }
        let textures = frameTextures ?? targets.merging(planner.layerImages) { $1 }
        frameTextures = textures
        let aliasing = !graphs.aliasedTargets.isEmpty
        return try executor.encodeFrame(on: queue, textures: textures,
                                        prepare: { commandBuffer in
                                            submitted = true
                                            if let completion {
                                                commandBuffer.addCompletedHandler(completion)
                                            }
                                            if aliasing {
                                                commandBuffer.addCompletedHandler { buffer in
                                                    if buffer.error != nil {
                                                        Self.renderTargetAliasingFailed.withLock { $0 = true }
                                                    }
                                                }
                                            }
                                            if !retiredTextures.isEmpty {
                                                // The handler only drops the last reference; releasing an MTLTexture is thread-safe.
                                                nonisolated(unsafe) let retired = retiredTextures
                                                retiredTextures.removeAll()
                                                commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retired) {} }
                                            }
                                            try encodeMaterialClears(on: commandBuffer)
                                            try videos.encode(into: commandBuffer)
                                        }, shouldTransfer: { step in
                                            if case let .particleSnapshot(block) = graphs.operations[variant][step] {
                                                return (try? particleStreams[block]?.get())?.snapshotBoundary != nil
                                            }
                                            return true
                                        }, clearColor: { pass in
                                            guard let owner = textBackgroundOwners[pass], let color = backgroundColor(of: owner) else { return nil }
                                            return WPEClearColor(red: Double(color.x), green: Double(color.y),
                                                                 blue: Double(color.z), alpha: Double(color.w))
                                        }, visit: { step, textures, arena, emit in
                                            func encode(_ provided: consuming WPEParityDraw, operation: Int) throws {
                                                for (name, texture) in provided.textures {
                                                    if let sampler = targetSamplers[ObjectIdentifier(texture)] {
                                                        provided.samplers[name + "SamplerState"] = sampler
                                                    }
                                                }
                                                #if DEBUG
                                                lastFrameDraws.append((operation, provided))
                                                #endif
                                                lastFrameOperations.append(operation)
                                                try emit(provided)
                                            }
                                            let source = graphs.operations[variant][step]
                                            switch source {
                                            case let .particlePrefix(block), let .particleSuffix(block):
                                                guard let stream = try stream(for: block) else { return }
                                                let boundary = stream.snapshotBoundary ?? stream.batches.count
                                                let range: Range<Int> = if case .particlePrefix = source {
                                                    0 ..< boundary
                                                } else {
                                                    boundary ..< stream.batches.count
                                                }
                                                for index in range {
                                                    let batch = stream.batches[index]
                                                    guard let operation = graphs.particleDraws[batch.key], let plan = draws[operation] else { continue }
                                                    if let provided = try plan.makeParticleDraw(batch, frame: uniforms, camera: renderCamera, variant: variant,
                                                                                                textures: textures, arena: arena, textureSlots: &instance.textureSlots,
                                                                                                renderVars: &instance.renderVars, particles: &instance.particles, layers: live,
                                                                                                mediaTexture: { croppedMediaTexture($0, aspect: $1) },
                                                                                                userShortcutTexture: { videos.userTexture(for: $0) ?? shortcutIcons?.texture(for: $0) }) {
                                                        // Encode argument tables before the next batch reserves any vertex bytes.
                                                        try encode(provided, operation: operation)
                                                    } else if loggedParticleDrops.insert(batch.key.objectID).inserted {
                                                        Logger.warning("Particle object \(batch.key.objectID) dropped draw batches: frame demand "
                                                            + "\(particleDemand) bytes, share \(instance.particles.budget) bytes", category: .wpeRender)
                                                    }
                                                }
                                            case let .layout(operation):
                                                guard let plan = draws[operation] else { return }
                                                let fade = operation == graphs.layout.fade
                                                if fade {
                                                    guard fadeAlpha > 0 else { return }
                                                    if fadeConstants.isEmpty {
                                                        fadeConstants = plan.constants
                                                    }
                                                    fadeConstants[.fragment]?["g_Alpha"] = .float(fadeAlpha)
                                                }
                                                plan.applyRenderVarWrites(to: &instance.renderVars)
                                                let frameDraw = graphs.layout.frames[variant].draws[operation]
                                                let color = drawColor(frameDraw, plan: plan)
                                                let provided = try plan.makeDraw(frame: uniforms, camera: renderCamera, variant: variant, textures: textures,
                                                                                 textureSlots: &instance.textureSlots, puppets: instance.puppets,
                                                                                 textureAnimations: instance.textureAnimations, layers: live,
                                                                                 constants: fade ? fadeConstants : postConstants[operation] ?? materialConstants(operation, plan),
                                                                                 layerColor: color == plan.layerColor?.loaded ? nil : color,
                                                                                 renderVar0: plan.clipMaskInverted == nil ? nil : instance.renderVars.rv0,
                                                                                 textRenderVarState: plan.textRenderVars == nil ? nil : instance.renderVars,
                                                                                 mediaTexture: { croppedMediaTexture($0, aspect: $1) },
                                                                                 userShortcutTexture: { videos.userTexture(for: $0) ?? shortcutIcons?.texture(for: $0) })
                                                guard case let .scene(description)? = frameDraw,
                                                      description.target == WPEParitySceneResource.shadowAtlas else {
                                                    try encode(provided, operation: operation)
                                                    return
                                                }
                                                // Depth-only GREATER makes this caster-major order fill the atlas as WPE's batch-major
                                                // order does (140196530.c:13-59).
                                                for batch in shadowLayout?.batches ?? [] {
                                                    var caster = provided
                                                    caster.constants[.vertex, default: [:]]["g_ViewportViewProjectionMatrices"] =
                                                        .array(batch.map { .wpeTransposed($0.viewProjection) })
                                                    caster.instanceCount = batch.count
                                                    caster.viewports = batch.map {
                                                        MTLViewport(originX: Double($0.viewport.x), originY: Double($0.viewport.y),
                                                                    width: Double($0.viewport.width), height: Double($0.viewport.height),
                                                                    znear: 0, zfar: 1)
                                                    }
                                                    try encode(caster, operation: operation)
                                                }
                                            case .particleSnapshot, .state: break
                                            }
                                        })
    }

    /// Text background brightness has no layout hook. Consume it here without rebuilding glyph geometry or atlases.
    private func drawColor(_ frameDraw: WPEParityFrameDraw?, plan: WPEParityFrameDrawPlan) -> SIMD4<Float>? {
        guard case let .scene(description)? = frameDraw,
              description.geometry == .textBackground else {
            return plan.layerColor.map { instance.state.layerColor(at: $0.object) }
        }
        return backgroundColor(of: description.objectID)
    }

    private func backgroundColor(of objectID: String) -> SIMD4<Float>? {
        guard let text = planner.texts[objectID] else { return nil }
        var brightness = text.object.backgroundBrightness
        if case let .vector(value)? = instance.state.scriptField("backgroundbrightness", of: objectID) {
            brightness = value.x
        }
        return SIMD4(text.object.backgroundColor * (instance.state.hdr ? brightness : 1),
                     instance.state.object(objectID)?.alpha ?? text.object.alpha)
    }

    /// The draw's constants, re-packed from the state only after its material pass changed.
    private func materialConstants(_ operation: Int,
                                   _ plan: WPEParityFrameDrawPlan) -> [WPEHLSLStage: [String: WPECBufferValue]] {
        guard let pass = plan.materialPass else { return plan.constants }
        let generation = instance.state.constantGeneration(pass: pass)
        guard generation != 0 else { return plan.constants }
        if let packed = packedConstants[operation], packed.generation == generation {
            return packed.constants
        }
        var constants = plan.constants
        let values = instance.state.constants(pass: pass)
        for (stage, uniforms) in plan.materialConstants {
            for uniform in uniforms {
                guard let value = values[uniform.material] else { continue }
                constants[stage]?[uniform.name] = uniform.value(value)
            }
        }
        packedConstants[operation] = (generation, constants)
        constantPacks += 1
        return constants
    }
}

/// The scene's logical state that one renderer owns and a replanned renderer continues from a copy of.
final class WPEParitySceneInstance {
    // Not a struct: exclusivity is checked per stored property, so as a struct field two inout fields would trap.

    var clock: WPEParityClock
    var pointer: WPEParityUniformPointer
    var parallax: WPEParityUniformParallax
    var cameraPaths: WPEParityCameraPaths
    var cameraPose: WPEParityCameraPose?
    var activeCameraID: String?
    var audio: WPEParityAudioSpectrum
    /// Last TEXS rotation and translation per slot, which draws without a sprite frame upload again.
    var textureSlots: [String: WPECBufferValue]
    /// g_RenderVar0/1 as the last draw left them, in frame draw order and across frames.
    var renderVars: WPEParityRenderVarState
    /// One bone animator per skinned puppet layer, keyed by object id.
    var puppets: [String: WPEParityPuppetAnimator]
    /// Animation-layer script fields last pushed into `puppets`; an absent key compares with its scene JSON value.
    var pushedAnimationLayerFields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue]
    /// Script texture animation of each image layer that asked for one, keyed by object id.
    var textureAnimations: [String: WPEParityTextureAnimation]
    var particles: WPEParityParticleFrame
    var sceneRNG: WPEParityMT19937
    var cameraQueues: [String: WPEParityCameraQueue]
    var frameIndex: Int
    /// Object and material state the draws read every frame; animations write it, and so may callers between frames.
    var state: WPEParitySceneState
    var animations: WPEParitySceneAnimations
    /// The camera pose published by the last camera update, including that update's shake.
    var camera: WPEParityCamera
    /// The scene's SceneScript engine; nil for a scene without property scripts.
    var script: WPEParitySceneScript?
    var media: WPESceneMediaEventMailbox?
    var mediaGeneration: Int
    var mediaTextures: WPEMediaTextureStore.ParitySnapshot?
    var userShortcutIcons: WPEUserShortcutIconStore?
    var mediaDiagnostics: [String]
    var seenScriptSound: Int
    var seenSoundBoundsFields: Int
    var seenScriptLighting: Int
    var seenScriptBloom: Int
    var bloom: WPEParityBloomSettings

    init(clock: WPEParityClock, pointer: WPEParityUniformPointer, parallax: WPEParityUniformParallax,
         cameraPaths: WPEParityCameraPaths, cameraPose: WPEParityCameraPose?, activeCameraID: String?,
         audio: WPEParityAudioSpectrum, textureSlots: [String: WPECBufferValue], renderVars: WPEParityRenderVarState,
         puppets: [String: WPEParityPuppetAnimator],
         pushedAnimationLayerFields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue],
         textureAnimations: [String: WPEParityTextureAnimation], particles: WPEParityParticleFrame,
         sceneRNG: WPEParityMT19937, cameraQueues: [String: WPEParityCameraQueue], frameIndex: Int,
         state: WPEParitySceneState, animations: WPEParitySceneAnimations, camera: WPEParityCamera,
         script: WPEParitySceneScript?, media: WPESceneMediaEventMailbox?, mediaGeneration: Int,
         mediaTextures: WPEMediaTextureStore.ParitySnapshot?, userShortcutIcons: WPEUserShortcutIconStore?,
         mediaDiagnostics: [String], seenScriptSound: Int, seenSoundBoundsFields: Int, seenScriptLighting: Int,
         seenScriptBloom: Int, bloom: WPEParityBloomSettings) {
        self.clock = clock
        self.pointer = pointer
        self.parallax = parallax
        self.cameraPaths = cameraPaths
        self.cameraPose = cameraPose
        self.activeCameraID = activeCameraID
        self.audio = audio
        self.textureSlots = textureSlots
        self.renderVars = renderVars
        self.puppets = puppets
        self.pushedAnimationLayerFields = pushedAnimationLayerFields
        self.textureAnimations = textureAnimations
        self.particles = particles
        self.sceneRNG = sceneRNG
        self.cameraQueues = cameraQueues
        self.frameIndex = frameIndex
        self.state = state
        self.animations = animations
        self.camera = camera
        self.script = script
        self.media = media
        self.mediaGeneration = mediaGeneration
        self.mediaTextures = mediaTextures
        self.userShortcutIcons = userShortcutIcons
        self.mediaDiagnostics = mediaDiagnostics
        self.seenScriptSound = seenScriptSound
        self.seenSoundBoundsFields = seenSoundBoundsFields
        self.seenScriptLighting = seenScriptLighting
        self.seenScriptBloom = seenScriptBloom
        self.bloom = bloom
    }

    func copy() -> WPEParitySceneInstance {
        WPEParitySceneInstance(
            clock: clock, pointer: pointer, parallax: parallax, cameraPaths: cameraPaths, cameraPose: cameraPose,
            activeCameraID: activeCameraID, audio: audio, textureSlots: textureSlots, renderVars: renderVars,
            puppets: puppets, pushedAnimationLayerFields: pushedAnimationLayerFields,
            textureAnimations: textureAnimations, particles: particles, sceneRNG: sceneRNG, cameraQueues: cameraQueues,
            frameIndex: frameIndex, state: state, animations: animations, camera: camera, script: script, media: media,
            mediaGeneration: mediaGeneration, mediaTextures: mediaTextures, userShortcutIcons: userShortcutIcons,
            mediaDiagnostics: mediaDiagnostics, seenScriptSound: seenScriptSound,
            seenSoundBoundsFields: seenSoundBoundsFields, seenScriptLighting: seenScriptLighting,
            seenScriptBloom: seenScriptBloom, bloom: bloom
        )
    }
}
#endif
