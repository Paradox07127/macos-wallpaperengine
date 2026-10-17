#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import simd

/// Compiles WPE programs through the shader store.
struct WPEParityFrameShaderSource: Sendable {
    let store: WPEParityShaderStore
    let compilerIdentity: String
    let bindingABIVersion: Int

    func artifact(for program: WPEParityProgram) async throws -> WPEParityShaderArtifact {
        try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program.hlsl, compilerIdentity: compilerIdentity, bindingABIVersion: bindingABIVersion
        ))
    }
}

/// Host state the engine uniforms read each frame.
struct WPEParityFrameInput {
    /// Physical render-target pixels, y down; SceneScript receives the corresponding logical client pixels.
    var cursor: SIMD2<Float> = .zero
    var buttonDown = false
    /// 64 linear bins per channel; nil is silence.
    var audio: (left: [Float], right: [Float])?
    /// Local time for g_Daytime.
    var date = Date()
}

enum WPEParityFrameRenderError: Error, LocalizedError {
    case missingBackbuffer
    case arenaUnavailable
    case allocationFailed(WPEResourceID)
    case encoderUnavailable
    case invalidUserProperties
    case requiredPostProcessUnavailable(pass: String, reason: WPEParityFrameSkip)

    var errorDescription: String? {
        switch self {
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
    private struct Layout {
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
    private struct DrawName: Hashable {
        let pass: WPEPassIdentity
        let occurrence: Int
    }

    /// One compiled graph per frame variant of a layout without the operations of hidden objects (R24 Q2).
    private struct Graphs {
        let layout: Layout
        /// Per state object, whether it or an ancestor is hidden.
        let hidden: [Bool]
        let executors: [WPEParityGraphExecutor]
        /// Per executor, graph operation index → layout operation index.
        let operations: [[WPEParityGraphDrawSource]]
        let particleDraws: [WPEParityParticleDrawKey: Int]
        let particleSnapshotSkips: [String: WPEParityFrameSkip]
    }

    let backbuffer: MTLTexture
    /// Render targets the renderer allocates; layer images are not among them.
    private(set) var targets: [WPEResourceID: MTLTexture]
    /// Object and material state the draws read every frame; animations write it, and so may callers between frames.
    var state: WPEParitySceneState
    /// Material constant re-packs after a pass's constants changed, over the renderer's life.
    private(set) var constantPacks = 0
    private var animations: WPEParitySceneAnimations
    private var packedConstants: [Int: (generation: Int, constants: [WPEHLSLStage: [String: WPECBufferValue]])] = [:]
    private var seenTransforms = 0
    /// Set once a layer transform left its loaded value: draws then place themselves from `layers` every frame.
    private var layersMoved = false
    private var seenVisibility = 0
    private var seenEffects = 0
    private var seenMembership = 0
    private var seenModelData = 0
    private var graphs: Graphs
    /// The graphs before the last visibility change, kept so toggling back does not recompile.
    private var previousGraphs: Graphs?
    /// Dropped draws of graphs no longer kept.
    private var retiredDrops = 0
    private let plan: WPEParityFramePlan
    var logicalSize: SIMD2<Float> {
        SIMD2(Float(plan.width), Float(plan.height))
    }

    var colorTransfer: WPEPresentColorTransfer {
        plan.colorTransfer
    }

    /// Loaded text identity metadata; mutable colors remain only in SceneState.
    private let textBackgroundOwners: [WPEPassIdentity: String]
    /// Draws of later effect sets plan here, reusing its images and pipelines.
    private var planner: WPEParityFrameDrawPlanner
    /// Every program the plan can draw with, compiled at load.
    private var artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>]
    private let mipMappedFrameBufferRequested: Bool
    private var bloom: WPEParityBloomSettings
    /// Post-process draw constants for `bloom`, by draw operation, where they differ from the planned ones.
    private var postConstants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] = [:]
    private let device: MTLDevice
    private let drawEncoder: WPEParityDrawEncoder
    private let videos: WPEParityVideoTextures
    private let queue: MTLCommandQueue
    private let screen: WPEParityUniformScreen
    /// The scene camera; a camera path pose replaces it for the frame.
    private let rootCamera: WPEParityCamera
    /// The camera pose published by the last camera update, including that update's shake.
    private var camera: WPEParityCamera
    private var activeCameraID: String?
    private var sceneRNG: WPEParityMT19937
    private var cameraQueues: [String: WPEParityCameraQueue]
    /// The scene's SceneScript engine; nil for a scene without property scripts.
    private(set) var script: WPEParitySceneScript?
    private var media: WPESceneMediaEventMailbox?
    private var mediaGeneration = 0
    private(set) var mediaTextures: WPEMediaTextureStore.ParitySnapshot?
    var userShortcutIcons: WPEUserShortcutIconStore?
    private(set) var mediaDiagnostics: [String] = []
    var hasMediaTextureDemand: Bool {
        graphs.layout.draws.values.contains { !$0.mediaSlots.isEmpty }
    }

    private var seenScriptBloom = 0
    private var seenScriptSound = 0
    private var seenSoundBoundsFields = -1
    private var seenSoundVisibility = -1
    private var seenScriptLighting = -1
    private var seenLightTransforms = -1
    private var seenLightVisibility = -1
    private var seenLayerFields = -1
    private var seenAnimationLayerFields = -1
    /// Animation-layer script fields last pushed into `puppets`; an absent key compares with its scene JSON value.
    private var pushedAnimationLayerFields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:]
    private var lights: WPEParityUniformLights
    /// This frame's shadow atlas layout; nil when shadow quality is 0 or the plan declares no atlas.
    private(set) var shadowLayout: WPEParityShadowLayout?
    private let generalZoom: Float
    private var cameraPaths: WPEParityCameraPaths
    private var cameraPose: WPEParityCameraPose?
    /// The fade draw's planned constants with this frame's g_Alpha.
    private var fadeConstants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
    /// Native no-hook fields are polled at the camera-update and layer-render read points.
    private var cameraParallax: WPESceneCameraParallaxSettings {
        var settings = WPESceneCameraParallaxSettings.disabled
        if case let .vector(value)? = state.scriptField("cameraparallax", of: "") {
            settings.enabled = value.x != 0
        }
        if case let .vector(value)? = state.scriptField("cameraparallaxamount", of: "") {
            settings.amount = Double(value.x)
        }
        if case let .vector(value)? = state.scriptField("cameraparallaxdelay", of: "") {
            settings.delay = Double(value.x)
        }
        if case let .vector(value)? = state.scriptField("cameraparallaxmouseinfluence", of: "") {
            settings.mouseInfluence = Double(value.x)
        }
        return settings
    }

    private var cameraShake: WPEParityCameraShake? {
        guard case let .vector(enabled)? = state.scriptField("camerashake", of: ""), enabled.x != 0 else { return nil }
        var settings = WPEParityCameraShake(orthographic: rootCamera.scenePerspective == nil)
        if case let .vector(value)? = state.scriptField("camerashakespeed", of: "") {
            settings.speed = value.x
        }
        if case let .vector(value)? = state.scriptField("camerashakeamplitude", of: "") {
            settings.amplitude = value.x
        }
        if case let .vector(value)? = state.scriptField("camerashakeroughness", of: "") {
            settings.roughness = value.x
        }
        return settings
    }

    private(set) var clock = WPEParityClock()
    private(set) var pointer = WPEParityUniformPointer()
    private var parallax = WPEParityUniformParallax()
    private var audio = WPEParityAudioSpectrum()
    /// Last TEXS rotation and translation per slot, which draws without a sprite frame upload again.
    private var textureSlots: [String: WPECBufferValue] = [:]
    /// g_RenderVar0/1 as the last draw left them, in frame draw order and across frames (R22 Q3).
    private var renderVars = WPEParityRenderVarState()
    /// One bone animator per skinned puppet layer, keyed by object id.
    private(set) var puppets: [String: WPEParityPuppetAnimator] = [:]
    /// Script texture animation of each image layer that asked for one, keyed by object id.
    private(set) var textureAnimations: [String: WPEParityTextureAnimation] = [:]
    private var particles: WPEParityParticleFrame
    private let particleFullFrameBuffer: [String: [[WPEParityParticlePathElement]: Bool]]
    private let particleBaseFailures: [String: [[WPEParityParticlePathElement]: WPEParityFrameSkip]]
    private let particleSnapshotObjects: Set<String>
    private(set) var particleMaterialSkips: [String: WPEParityFrameSkip]
    private let arena: WPEParityFrameArena
    /// Arena bytes outside the particle share, for the other draws' cbuffers and tables.
    private let baseArenaBytes: Int
    /// False when the caller fixed the particle share.
    private let growsParticleShare: Bool
    static let maxParticleShare = 256 << 20
    private var layers: WPEParityLayerTransformSet
    /// Every particle object and its state index; hidden ones are not stepped (R24 Q2).
    private let particleObjects: [(id: String, index: Int?)]
    /// The draws the last frame encoded, by draw operation, in encode order.
    private(set) var lastFrameDraws: [(operation: Int, draw: WPEParityDraw)] = []
    private var frameIndex = 0
    private var targetSamplers: [ObjectIdentifier: WPEParitySamplerState] = [:]
    private var resourceBindings: WPEParityResourceBindings = [:]
    private var seenScriptText = 0
    private struct MaterialClear {
        let texture: MTLTexture
        let color: WPEClearColor
    }

    /// Calls retain the actual texture version and order until its clear has been encoded on a committed buffer.
    private var materialClears: [MaterialClear] = []
    /// Images and targets of removed objects that frames already submitted may still read; the next committed
    /// frame's completion releases them.
    private var retiredTextures: [MTLTexture] = []

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

    /// Reads the current graph's actual allocation, including heap/memoryless targets; owns no extra resources.
    func renderTarget(_ id: WPEResourceID, scope: WPEResourceBindingScope = .frame) -> MTLTexture? {
        let variant = max(0, frameIndex - 1) % graphs.executors.count
        let physical = resourceBindings[scope]?[id] ?? id
        return graphs.executors[variant].transientTextures[physical] ?? targets[physical]
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

    private var draws: [Int: WPEParityFrameDrawPlan] {
        graphs.layout.draws
    }

    var executedDrawCount: Int {
        draws.count
    }

    /// Particle batches dropped because a frame's particle draws outgrew their arena share or the arena.
    var droppedParticleBatches: Int {
        let current = graphs.executors.reduce(particles.dropped + retiredDrops) { $0 + $1.droppedDraws }
        return previousGraphs?.executors.reduce(current) { $0 + $1.droppedDraws } ?? current
    }

    /// Live particles of a particle object, children included.
    func particleLiveCount(_ objectID: String) -> Int? {
        particles.scene.liveCount(objectID)
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
        try draws[operation]?.frameUniforms(parallax: parallax.smoothed, camera: pathCamera,
                                            layers: layersMoved ? layers : nil)
    }

    /// The published camera pose with the layer renderer's current parallax controls.
    var pathCamera: WPEParityCamera {
        var selected = camera
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
        hasStaticBase && !cameraParallax.enabled && cameraShake == nil && !cameraQueues.values.contains {
            $0.hasEligibleItems && state.isAlive($0.objectID) && state.isVisible($0.objectID)
        }
    }

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
    }

    /// The fixed textures video .tex draws sample.
    var videoTextures: [MTLTexture] {
        videos.textures
    }

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
            return textureAnimations[id, default: WPEParityTextureAnimation()].perform(
                command, value: value, shared: WPEParityFrameDrawPlan.sharedSprite(steps, at: clock.time),
                durations: steps.map { Float($0.duration) }
            )
        }
    }

    /// Nil when the layer has no puppet or the puppet has no layer at that `animationlayers` index.
    var scriptAnimationLayer: (String, Int, WPEParityScriptEngine.AnimationLayerCommand, Double) -> Double? {
        { [weak self] id, index, command, value in
            guard let self, let layer = puppets[id]?.layers.first(where: { $0.sceneIndex == index }) else { return nil }
            switch command {
            case .play: puppets[id]?.controlLayer(at: index, action: .play)
            case .pause: puppets[id]?.controlLayer(at: index, action: .pause)
            case .stop: puppets[id]?.controlLayer(at: index, action: .stop)
            case .setFrame: puppets[id]?.controlLayer(at: index, action: .setFrame(Float(value)))
            case .isPlaying: return layer.isPlaying ? 1 : 0
            case .getFrame: return Double(layer.frame)
            case .fps: return Double(layer.fps)
            case .frameCount: return Double(layer.animation.frameCount)
            case .duration: return Double(layer.duration)
            }
            return 0
        }
    }

    /// Nil when the object has no loaded particle system.
    var scriptParticleSystem: (String, WPEParityScriptEngine.ParticleCommand, Int32) -> Double? {
        { [weak self] id, command, count in
            self?.particles.scene.control(objectID: id) { system in
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
            transforms.refreshWorlds { self.puppets[$0]?.boneWorld }
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
    private lazy var textPipeline = WPEParityTextPipeline(
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
    /// Requests remain ordered until the CPU/GPU cohort is accepted; repeated objects are meaningful.
    private var textRequests: [WPEParityTextPipeline.RelayoutRequest] = []
    private var pendingScriptTextGeneration: Int?
    private var pendingTextEffectsGeneration: Int?
    /// Only a previously attempted failed prefix; later unattempted input must remain ordered.
    private var failedTextRequestCount = 0

    #if DEBUG
    /// Value snapshots for the real Metal preparation guard, never an additional resource owner/cache.
    struct TextPreparationSnapshot {
        let texts: [String: WPEParitySceneText]
        let atlases: WPEParityTextAtlasTextures
        let pipelineAtlases: [String: WPEParityGlyphAtlasInstance]
        let layers: WPEParityLayerTransformSet
        let frames: [WPEParityFrame]
        let draws: [Int: WPEParityFrameDrawPlan]
        let targets: [WPEResourceID: MTLTexture]
        let bindings: WPEParityResourceBindings
        let executorIDs: [ObjectIdentifier]
        let pendingRequests: Int
        let initialization: MTLCommandBuffer?
    }

    /// Runs after all fallible GPU preparation, before CPU accept. Tests may inject one explicit failure.
    var textPreparationCheckpoint: ((TextPreparationSnapshot) throws -> Void)?

    var textPreparationState: TextPreparationSnapshot {
        textSnapshot(planner: planner, layers: layers, graphs: graphs, targets: targets,
                     pipelineAtlases: textPipeline.atlases, initialization: nil)
    }

    private func textSnapshot(planner: WPEParityFrameDrawPlanner, layers: WPEParityLayerTransformSet,
                              graphs: Graphs, targets: [WPEResourceID: MTLTexture],
                              pipelineAtlases: [String: WPEParityGlyphAtlasInstance],
                              initialization: MTLCommandBuffer?) -> TextPreparationSnapshot {
        TextPreparationSnapshot(texts: planner.texts, atlases: planner.textAtlases,
                                pipelineAtlases: pipelineAtlases, layers: layers,
                                frames: graphs.layout.frames, draws: graphs.layout.draws, targets: targets,
                                bindings: resourceBindings, executorIDs: graphs.executors.map(ObjectIdentifier.init),
                                pendingRequests: textRequests.count, initialization: initialization)
    }
    #endif

    /// `particleArenaBytes` fixes each frame's particle share of the arena. By default the share starts with every
    /// particle draw at full capacity, an event group as one instance, and doubles after each frame that drops
    /// particle batches, up to `maxParticleShare`. `workshopID` keys the video disk cache; nil uses the scene
    /// directory's name.
    nonisolated(nonsending) init(plan: WPEParityFramePlan, device: MTLDevice, queue: MTLCommandQueue, shaders: WPEParityFrameShaderSource,
                                 particleSeed: UInt32 = WPEParityParticleScene.productSeed(), particleArenaBytes: Int? = nil,
                                 workshopID: String? = nil, continuing previous: WPEParityFrameRenderer? = nil,
                                 userPropertiesJSON: String = "{}") async throws {
        let factory = WPEParityPipelineFactory(device: device)
        let encoder = WPEParityDrawEncoder(factory: factory)
        var planner = try WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan,
                                                    preservingVideoImages: previous?.planner.videoImages ?? [:],
                                                    userProperties: Self.propertySnapshot(userPropertiesJSON))
        // Disabled effects' programs too, so a toggle compiles nothing (R24 Q3).
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
        for id in plan.state.ids where previous?.state.isAlive(id) == false {
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
        let streams = planner.takeVideoStreams()
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

        // Each draw needs at most a few argument tables and cbuffers, all 256-byte aligned.
        let particleBytes = particleArenaBytes ?? draws.values.reduce(0) { total, draw in
            guard case let .particles(particle) = draw.geometry else { return total }
            return total + WPEParityFrameArena.aligned(particle.maxBytes) + particle.argumentBytes
        }
        // Sized for the effect set with the most draws.
        let drawCount = probes.reduce(draws.count) { max($0, $1.frame.draws.count) }
        let baseArenaBytes = max(1 << 16, drawCount * 16 * 1024)
        guard let arena = WPEParityFrameArena(device: device, capacity: baseArenaBytes + particleBytes) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        var targets: [WPEResourceID: MTLTexture] = [:]
        try Self.prepareHDRBloomTargets(plan.post, device: device, targets: &targets)
        let snapshotObjects = Set(particleFacts.filter { $0.value.values.contains(true) }.map(\.key))
        let graphs = try Self.makeGraphs(layout: layout, state: plan.state, device: device, encoder: encoder,
                                         arena: arena, targets: &targets, snapshotObjects: snapshotObjects)
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
        bloom = plan.post.bloomSettings
        self.device = device
        drawEncoder = encoder
        state = plan.state
        var constantComponents: [WPEParityMaterialPassKey: [String: Int]] = [:]
        for binding in plan.bindings.joined().map(\.value) {
            guard let pass = binding.materialPass else { continue }
            for constant in binding.materialConstants.values.joined() {
                constantComponents[pass, default: [:]][constant.material] = constant.components
            }
        }
        let animations = WPEParitySceneAnimations(document: plan.document, state: plan.state,
                                                  constantComponents: constantComponents)
        self.animations = animations
        self.backbuffer = backbuffer
        self.targets = targets
        targetSamplers = Self.targetSamplers(layout, targets: targets)
        self.videos = videos
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
        camera = rootCamera
        generalZoom = Float(plan.document.general.zoom)
        cameraPaths = plan.scene.cameraPaths
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
        let sceneRNG = previous?.sceneRNG ?? WPEParityMT19937(seed: particleSeed)
        self.sceneRNG = sceneRNG
        if let previous {
            // Replanning must not prewarm new systems or consume the continuing scene random stream.
            particles = previous.particles
            cameraQueues = previous.cameraQueues
        } else {
            particles = WPEParityParticleFrame(
                scene: WPEParityParticleScene(document: plan.document, assets: plan.scene.assets,
                                              engineFlags: plan.scene.engineFlags, seed: particleSeed,
                                              frames: prewarm, rng: sceneRNG), budget: particleBytes
            )
            var queues: [String: WPEParityCameraQueue] = [:]
            for object in plan.document.resolvedObjectsJSON {
                guard case .string? = object["camera"],
                      let queue = try WPEParityCameraQueue(object: object, assets: plan.scene.assets,
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
        for object in skinned {
            guard let model = plan.scene.puppetModels[object.id] else { continue }
            let layers = plan.document.imageObjects.first { $0.id == object.id }?.animationLayers ?? []
            puppets[object.id] = WPEParityPuppetAnimator(model: model, layers: layers)
        }
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
    func continueScene(from previous: WPEParityFrameRenderer, userPropertiesJSON: String? = nil) throws {
        try previous.submitMaterialClears()
        clock = previous.clock
        pointer = previous.pointer
        parallax = previous.parallax
        cameraPaths = previous.cameraPaths
        cameraPose = previous.cameraPose
        activeCameraID = previous.activeCameraID
        audio = previous.audio
        textureSlots = previous.textureSlots
        renderVars = previous.renderVars
        puppets = previous.puppets
        pushedAnimationLayerFields = previous.pushedAnimationLayerFields
        textureAnimations = previous.textureAnimations
        particles = previous.particles
        sceneRNG = previous.sceneRNG
        // Script registrations belong to the same scene and shader store; resizing changes draw targets only.
        artifacts.merge(previous.artifacts) { current, _ in current }
        cameraQueues = previous.cameraQueues
        arena.capacity = baseArenaBytes + particles.budget
        frameIndex = previous.frameIndex
        resourceBindings = try migratedBindings(from: previous)
        // A resize is a real storage transaction. Compatible named RTs preserve history unless authored clear
        // requests initialization at resize; the new backbuffer always belongs to the new renderer.
        for resource in graphs.layout.frames.flatMap(\.resources) where resource.id != WPEParitySceneResource.backbuffer {
            guard resource.lifetime != .imported, let old = previous.targets[resource.id],
                  Self.matches(old, resource: resource) else { continue }
            targets[resource.id] = old
        }
        targetSamplers = Self.targetSamplers(graphs.layout, targets: targets)
        let clearColors = Self.clearColors(graphs.layout, targets: targets)
        try Self.clear(targets.values.filter { clearColors[ObjectIdentifier($0)] != nil }, queue: queue,
                       colors: clearColors)
        state = previous.state
        animations = previous.animations
        camera = previous.camera
        camera.renderTargetSize = rootCamera.renderTargetSize
        camera.size = rootCamera.size
        script = previous.script
        media = previous.media
        mediaGeneration = previous.mediaGeneration
        mediaTextures = previous.mediaTextures
        userShortcutIcons = previous.userShortcutIcons
        mediaDiagnostics = previous.mediaDiagnostics
        seenScriptSound = previous.seenScriptSound
        seenSoundBoundsFields = previous.seenSoundBoundsFields
        seenScriptLighting = previous.seenScriptLighting
        lights = previous.lights
        shadowLayout = previous.shadowLayout
        // A script's bloom write reaches `bloom` below; the generation only marks it consumed.
        seenScriptBloom = previous.seenScriptBloom
        // The next frame takes the transforms, visibility and effects over from the copied state.
        seenTransforms = previous.layersMoved ? -1 : 0
        seenVisibility = -1
        seenEffects = -1
        seenMembership = -1
        seenModelData = -1
        bloom = previous.bloom
        for object in previous.plan.scene.scene.objects {
            guard let text = previous.planner.texts[object.id] else { continue }
            textRequests.append(.init(text.object, effectCount: text.effectCount))
        }
        // Resize handlers may call material functions on dynamically relaid text FBOs. Prepare those actual
        // targets first, and only replace the engine callback after all throwing adoption work succeeds.
        try replanRelaidTexts()
        if let userPropertiesJSON {
            let snapshot = try Self.propertySnapshot(userPropertiesJSON)
            try replaceConditionalProperties(changed: snapshot, merged: snapshot)
        }
        script?.engine.materialFunctionHandler = scriptMaterialFunction
        script?.engine.transformMatrixHandler = scriptTransformMatrix
        script?.engine.textureAnimationHandler = scriptTextureAnimation
        script?.engine.animationLayerHandler = scriptAnimationLayer
        script?.engine.particleSystemHandler = scriptParticleSystem
        script?.engine.propertyAnimationLookup = { [animations] in animations.animation(objectID: $0, pass: $1, name: $2) }
        script?.engine.modelDataAdmissionHandler = scriptModelDataAdmission
        script?.resize(canvasSize: camera.size, screenResolution: logicalSize,
                       state: &state)
        repackBloom()
    }

    /// Writes a user-property change between frames; changed text layers are re-laid now. `changedJSON` holds the
    /// changed project properties, `mergedJSON` all of them (1401731d0.c:143-840).
    func applyUserProperties(_ update: WPEParityUserPropertyUpdate, changedJSON: String = "{}",
                             mergedJSON: String = "{}") throws {
        try replaceConditionalProperties(changed: Self.propertySnapshot(changedJSON),
                                         merged: Self.propertySnapshot(mergedJSON))
        update.apply(to: &state)
        let updatedBloom = bloomSettingsFromState(update.bloom)
        if updatedBloom != bloom {
            bloom = updatedBloom
            repackBloom()
        }
        if !update.texts.isEmpty {
            discardSupersededFailedTexts()
        }
        for text in update.texts {
            textRequests.append(.init(text))
            for (name, value) in WPEParityTextFields.seed(text) {
                state.setScriptField(name, of: text.id, to: value, invalidating: .textLayout)
            }
        }
        script?.applyUserProperties(changedJSON: changedJSON, mergedJSON: mergedJSON, state: &state)
    }

    private static func propertySnapshot(_ json: String) throws -> WPESceneJSONValue {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let value = WPESceneJSONValue(jsonValue: raw), case .object = value else {
            throw WPEParityFrameRenderError.invalidUserProperties
        }
        return value
    }

    /// Prepare all immutable texture replacements and their existing readers before adopting them. Native
    /// reload destroys its old resources before its placeholder fallback; matching that failure path is still
    /// open. A failed Mac preparation currently leaves the valid cohort intact and rejects the product commit.
    private func replaceConditionalProperties(changed: WPESceneJSONValue, merged: WPESceneJSONValue) throws {
        let prepared = try planner.preparingConditionalProperties(changed: changed, merged: merged)
        var candidate = prepared.planner
        guard !prepared.affectedOperations.isEmpty else {
            planner = candidate
            return
        }
        let current = graphs.layout
        let affectedNames = Set(Self.drawNames(current.frames[0]).compactMap { index, name in
            prepared.affectedOperations.contains(index) ? name : nil
        })
        let reuse = Layout(planned: current.planned, effects: current.effects,
                           draws: current.draws.filter { !prepared.affectedOperations.contains($0.key) },
                           skipped: current.skipped, fade: current.fade)
        let planned = try plan.layout(effects: state, texts: candidate.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                         planner: &candidate, encoder: drawEncoder,
                                         state: state, reusing: reuse)
        for (index, name) in Self.drawNames(planned.frames[0])
            where affectedNames.contains(name) && planned.programs[index] != nil && layout.draws[index] == nil {
            throw layout.skipped[index] ?? WPEParityFrameSkip.noMaterial
        }
        try installGraphs(layout, cachePrevious: false)
        planner = candidate
        packedConstants.removeAll()
        fadeConstants.removeAll()
        repackBloom()
    }

    /// Runs `script`'s init against the loaded state; its events and update then run inside every frame.
    func attachScript(_ script: WPEParitySceneScript) throws {
        self.script = script
        script.engine.materialFunctionHandler = scriptMaterialFunction
        script.engine.transformMatrixHandler = scriptTransformMatrix
        script.engine.videoTextureHandler = scriptVideoCommand
        script.engine.textureAnimationHandler = scriptTextureAnimation
        script.engine.animationLayerHandler = scriptAnimationLayer
        script.engine.particleSystemHandler = scriptParticleSystem
        script.engine.propertyAnimationLookup = { [animations] in animations.animation(objectID: $0, pass: $1, name: $2) }
        script.engine.modelDataAdmissionHandler = scriptModelDataAdmission
        try script.start(state: &state)
    }

    var scriptModelDataProvider: WPEParityScriptModelDataProvider {
        WPEParityModelDataLayerAdmission.provider(plan: plan, device: device, admitShape: scriptModelDataAdmission)
    }

    /// Immutable loader inputs survive renderer resize without keeping its old graph or resource owner alive.
    var scriptModelDataAdmission:
        (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> (any WPEParityModelDataPreparedShape)? {
        let plan = plan
        let artifacts = artifacts
        let device = device
        return { shape, mutation in
            try WPEParityModelDataMetalShape.prepare(shape, mutation: mutation, plan: plan,
                                                     artifacts: artifacts, device: device)
        }
    }

    /// Called by the original binding's registration load gate before its init is dispatched.
    /// Material and shader bytes resolve through ProgramScene; the existing shader table owns the result.
    nonisolated(nonsending) func prepareRegisteredModelDataMaterial(
        _ path: String, shaders: WPEParityFrameShaderSource
    ) async throws {
        guard plan.scene.modelDataMesh(materialPath: path) != nil else {
            throw WPEParityModelDataFailure.native(1)
        }
        let program = try WPEParityModelDataMetalShape.program(materialPath: path, plan: plan)
        if case .success? = artifacts[program.hlsl] {
            return
        }
        let artifact = try await shaders.artifact(for: program)
        artifacts[program.hlsl] = .success(artifact)
    }

    /// Warm leaf images use the common post-update removal path. Other class destructors and dependent
    /// owners need their original resource contract before the product admits them.
    var scriptLayerRemovalAdmission: (String, UInt32?) -> Bool {
        // The engine continues through renderer replacement. Capture immutable loaded-class metadata,
        // without keeping the old renderer/Metal owners alive or consulting a dead weak renderer.
        let objects = plan.scene.scene.objects
        let parents = plan.document.objectParentByID
        let videoIDs = objects.filter { videos.hasOwner($0.id) }.map(\.id)
        let loadedIDs = plan.state.loadedIDs
        return { id, modelDataToken in
            // Created image clones own no class resource beyond their template's shared images.
            if modelDataToken != nil || !loadedIDs.contains(id) {
                return true
            }
            guard let object = objects.first(where: { $0.id == id }), case .image = object.kind,
                  object.puppet == nil, !videoIDs.contains(id), !parents.values.contains(id),
                  !object.dependencyTarget else { return false }
            return true
        }
    }

    func attachMedia(_ mailbox: WPESceneMediaEventMailbox?, generation: Int) {
        media = mailbox
        mediaGeneration = generation
    }

    /// The same accepted input supplies both textures and script properties/events before animation and update.
    private func consumeMediaInputs() {
        guard let media else { return }
        for input in media.drainParityInputs(generation: mediaGeneration) {
            if let textures = input.textures {
                mediaTextures = textures
            }
            mediaDiagnostics = input.diagnostics
            script?.applyMedia(properties: input.systemProperties, events: input.events, state: &state)
        }
    }

    /// Event 3 to every binding; later frames run no script.
    func destroyScript() {
        script?.engine.destroy(state: &state)
        script = nil
    }

    /// Object updates precede camera selection; scripts/animations of this frame affect the next selection.
    /// The last effectively visible camera owns the world pose. Root paths hold while an object is active.
    private func selectCamera(dt: Float) {
        let active = WPEParityCamera.activeObjectID(document: plan.document, state: state)
        var selected = rootCamera
        if case let .vector(value)? = state.scriptField("perspectiveoverridefov", of: "") {
            selected.perspectiveFOV = value.x
        }
        // 1891a0 selects effective O148 from raw O140; 183a70 reads near/far before the manager tick.
        // Camera objects and queues may replace only effective FOV after this canonical snapshot.
        if selected.scenePerspective != nil {
            if case let .vector(value)? = state.scriptField("fov", of: "") {
                selected.scenePerspective?.fov = value.x
            }
            if case let .vector(value)? = state.scriptField("nearz", of: "") {
                selected.scenePerspective?.near = value.x
            }
            if case let .vector(value)? = state.scriptField("farz", of: "") {
                selected.scenePerspective?.far = value.x
            }
        }
        var sceneZoom = generalZoom
        if case let .vector(value)? = state.scriptField("zoom", of: "") {
            sceneZoom = value.x
        }
        if let active {
            selected = selected.applyingObject(world: layers.world(active), objectID: active, document: plan.document,
                                               state: state, generalZoom: sceneZoom)
            if let queue = cameraQueues[active], queue.selectedIndex != nil {
                selected.zoom = sceneZoom * (queue.selectedZoom ?? 1)
                if selected.scenePerspective != nil {
                    selected.scenePerspective?.fov = queue.selectedFOV ?? 50
                }
            }
        } else {
            cameraPose = cameraPaths.advance(dt: dt)
            if let pose = cameraPose {
                selected = selected.posed(pose, generalZoom: sceneZoom)
            } else {
                // 1401891a0.c:72-75, :132-139: without a path, pose and zoom are the root values.
                func root(_ name: String) -> SIMD4<Float>? {
                    guard case let .vector(value)? = state.scriptField("cameraTransforms.\(name)", of: "") else {
                        return nil
                    }
                    return value
                }
                func vector(_ name: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                    root(name).map { SIMD3($0.x, $0.y, $0.z) } ?? fallback
                }
                let pose = WPEParityCameraPose(eye: vector("eye", rootCamera.eye), center: vector("center", rootCamera.center),
                                               up: vector("up", rootCamera.up), zoom: root("zoom")?.x ?? 1)
                selected = selected.posed(pose, generalZoom: sceneZoom)
            }
        }
        selected.shake = cameraShake
        selected = selected.shaken(time: clock.timeUniform)
        if camera != selected || activeCameraID != active {
            layersMoved = true
        }
        camera = selected
        activeCameraID = active
    }

    /// One common-scene sweep shares the native scene RNG across particle and camera queue consumers.
    private func updateSceneObjects(camera: WPEParityCamera, timeOfDay: Float) {
        particles.beginFrame()
        particles.scene.applyScriptInstanceFields(state: state)
        let viewProjection = camera.projection * camera.view
        for id in state.commonOrder {
            if let queue = cameraQueues[id],
               let output = queue.advance(dt: clock.frametime, world: layers.world(id),
                                          orthographic: plan.scene.engineFlags.orthographicProjection, state: state) {
                state.set(.origin, of: id, to: SIMD4(output.origin, 0))
                state.set(.angles, of: id, to: SIMD4(output.angles, 0))
                applyTransforms()
            } else if particles.scene.liveCount(id) != nil {
                let frame = state.isVisible(id)
                    ? WPEParityParticleFrameContext(time: clock.timeUniform, cursor: pointer.position,
                                                    viewProjection: viewProjection, objectMatrix: layers.world(id),
                                                    timeOfDay: timeOfDay, previousFrametime: clock.previousFrametime) : nil
                particles.scene.advance(objectID: id, dt: clock.frametime, frame: frame)
            }
        }
    }

    private func applyLayerFields() {
        guard seenLayerFields != state.scriptFieldsGeneration else { return }
        if layers.applyFields(state: state) {
            layersMoved = true
        }
        seenLayerFields = state.scriptFieldsGeneration
    }

    /// Only changed fields are pushed: replaying an unchanged blendin would re-arm a ramp the animator finished.
    private func applyAnimationLayerFields() {
        guard seenAnimationLayerFields != state.scriptFieldsGeneration else { return }
        seenAnimationLayerFields = state.scriptFieldsGeneration
        for (id, puppet) in puppets {
            let authored = plan.document.imageObjects.first { $0.id == id }?.animationLayers ?? []
            for layer in puppet.layers where authored.indices.contains(layer.sceneIndex) {
                let scene = authored[layer.sceneIndex]
                func scalar(_ value: Double) -> WPEParitySceneState.ScriptValue {
                    .vector(SIMD4(Float(value), 0, 0, 0))
                }
                let seeds: [String: WPEParitySceneState.ScriptValue] = [
                    "visible": scalar(scene.visible ? 1 : 0), "additive": scalar(scene.additive ? 1 : 0),
                    "blendin": scalar(scene.blendIn ? 1 : 0), "blendout": scalar(scene.blendOut ? 1 : 0),
                    "name": .string(scene.name), "rate": scalar(scene.rate), "blend": scalar(scene.blend),
                    "blendtime": scalar(scene.blendTime),
                ]
                var changed: [String: WPEParitySceneState.ScriptValue] = [:]
                for (name, seed) in seeds {
                    let key = WPEParitySceneState.ScriptFieldKey(objectID: id,
                                                                 name: "animationlayers.\(layer.sceneIndex).\(name)")
                    guard let value = state.scriptField(key.name, of: id),
                          value != (pushedAnimationLayerFields[key] ?? seed) else { continue }
                    pushedAnimationLayerFields[key] = value
                    changed[name] = value
                }
                guard !changed.isEmpty else { continue }
                func float(_ name: String) -> Float? {
                    guard case let .vector(value)? = changed[name] else { return nil }
                    return value.x
                }
                func flag(_ name: String) -> Bool? {
                    float(name).map { $0 != 0 }
                }
                var name: String?
                if case let .string(value)? = changed["name"] {
                    name = value
                }
                puppets[id]?.updateLayer(at: layer.sceneIndex, enabled: flag("visible"), rate: float("rate"),
                                         blend: float("blend"), name: name, additive: flag("additive"),
                                         blendIn: flag("blendin"), blendOut: flag("blendout"),
                                         blendTime: float("blendtime"))
            }
        }
    }

    /// Bloom fields share canonical State with scripts and accepted document deltas.
    /// A full settings snapshot must not replace unchanged or rejected seeds over live values.
    private func bloomSettingsFromState(_ source: WPEParityBloomSettings) -> WPEParityBloomSettings {
        var settings = source
        if case let .vector(value)? = state.scriptField("bloomstrength", of: "") {
            settings.strength = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomthreshold", of: "") {
            settings.threshold = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrstrength", of: "") {
            settings.hdrStrength = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrthreshold", of: "") {
            settings.hdrThreshold = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrfeather", of: "") {
            settings.hdrFeather = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrscatter", of: "") {
            settings.hdrScatter = value.x
        }
        if case let .integer(value)? = state.scriptField("bloomhdriterations", of: "") {
            settings.hdrIterations = Int(value)
        }
        if case let .vector(value)? = state.scriptField("bloomtint", of: "") {
            settings.tint = SIMD3(value.x, value.y, value.z)
        }
        return settings
    }

    /// LDR/HDR bloom fields scripts wrote, rebuilt after the tick (14017fa70.c:478-481).
    private func applyScriptBloom() {
        guard state.generation(.bloom) != seenScriptBloom else { return }
        seenScriptBloom = state.generation(.bloom)
        let settings = bloomSettingsFromState(bloom)
        guard settings != bloom else { return }
        bloom = settings
        repackBloom()
    }

    /// Scene colour terms are consumed after the script tick, before this frame's lighting constants are packed.
    /// The shadow layout follows `camera`'s eye and forward, so it is rebuilt every frame (140190c80.c:938-967).
    private func applyScriptLighting(camera: WPEParityCamera) throws {
        let quality = plan.scene.engineFlags.shadowQuality
        let atlasID = WPEParitySceneResource.shadowAtlas
        let shadows = quality != 0 && targets[atlasID] != nil
        guard shadows || seenScriptLighting != state.generation(.lighting)
            || seenLightTransforms != state.transformGeneration || seenLightVisibility != state.visibilityGeneration
            || layers.hasAttachments else { return }
        if shadows {
            let layout = WPEParityShadowLayout(
                document: plan.document, transforms: layers, state: state, quality: quality, eye: camera.eyePosition,
                forward: WPEParityUniformParallax.viewVectors(view: camera.view).forward,
                orthographic: plan.scene.engineFlags.orthographicProjection, previousAtlasSize: shadowLayout?.atlasSize
            )
            shadowLayout = layout
            if layout.atlasSize != .zero, let atlas = targets[atlasID],
               SIMD2(atlas.width, atlas.height) != layout.atlasSize {
                targets[atlasID] = try Self.makeTarget(
                    WPELogicalResource(id: atlasID, width: layout.atlasSize.x, height: layout.atlasSize.y,
                                       format: WPEParitySceneResource.depthFormat, lifetime: .imported),
                    device: device
                )
                retiredTextures.append(atlas)
            }
        }
        lights = WPEParityUniformLights(document: plan.document, transforms: layers, state: state,
                                        shadowQuality: quality, shadows: shadowLayout)
        seenScriptLighting = state.generation(.lighting)
        seenLightTransforms = state.transformGeneration
        seenLightVisibility = state.visibilityGeneration
    }

    var scriptFieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] {
        var defaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:]
        for text in planner.texts.values {
            for (name, value) in WPEParityTextFields.seed(text.object) {
                defaults[.init(objectID: text.object.id, name: name)] = value
            }
            defaults[.init(objectID: text.object.id, name: "size")] =
                .vector(SIMD4(lowHalf: text.scriptSize, highHalf: .zero))
        }
        defaults.merge(videos.scriptFieldDefaults) { _, actual in actual }
        // Root zoom starts at 1 (140186c90.c:136); the root pose is the scene's root camera.
        defaults[.init(objectID: "", name: "cameraTransforms.eye")] = .vector(SIMD4(rootCamera.eye, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.center")] = .vector(SIMD4(rootCamera.center, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.up")] = .vector(SIMD4(rootCamera.up, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.zoom")] = .vector(SIMD4(1, 0, 0, 0))
        return defaults
    }

    func takeSoundVisibility(_ body: (String, Bool) -> Void) {
        guard seenSoundVisibility != state.visibilityGeneration else { return }
        for sound in plan.document.soundObjects {
            body(sound.id, state.isVisible(sound.id))
        }
        seenSoundVisibility = state.visibilityGeneration
    }

    /// Sound volumes scripts wrote since the last call, by sound object; the runtime applies volume² × master.
    func takeScriptSoundVolumes(_ body: (String, Float) -> Void) {
        guard let script, state.generation(.soundGain) != seenScriptSound else { return }
        seenScriptSound = state.generation(.soundGain)
        for id in script.soundIDs {
            if case let .vector(volume)? = state.scriptField("volume", of: id) {
                body(id, volume.x)
            }
        }
    }

    /// These descriptors have no native onChanged hook; consume their stored fields at the next sound update.
    func takeScriptSoundBounds(_ body: (String, Double?, Double?) -> Void) {
        guard let script, seenSoundBoundsFields != state.scriptFieldsGeneration else { return }
        seenSoundBoundsFields = state.scriptFieldsGeneration
        for id in script.soundIDs {
            let minimum: Double? = if case let .vector(value)? = state.scriptField("mintime", of: id) {
                Double(value.x)
            } else {
                nil
            }
            let maximum: Double? = if case let .vector(value)? = state.scriptField("maxtime", of: id) {
                Double(value.x)
            } else {
                nil
            }
            body(id, minimum, maximum)
        }
    }

    /// The cursor pass and the queued media events of the frame, before the animations (14017fa70.c:473-476).
    private func runScriptEvents(_ script: WPEParitySceneScript, camera: WPEParityCamera, cursor: SIMD2<Float>,
                                 buttonDown: Bool, timeOfDay: Float) throws {
        let world = cursorWorld(camera: camera)
        try script.updateCursorTargets(state: state, quad: { try cursorQuad($0, camera: camera) })
        script.cursor(at: cursor, world: world, leftDown: buttonDown, timeOfDay: timeOfDay, state: &state)
        script.dispatchMedia(state: &state)
    }

    /// Native viewport-depth .5 unprojection; only an orthographic scene drops the returned Z.
    private func cursorWorld(camera: WPEParityCamera) -> SIMD3<Float> {
        camera.cursorWorld(normalizedPointer: pointer.position)
    }

    /// A layer's mesh corners in client pixels, y down, with its frame's parallax (140189e10.c:124-156).
    func cursorQuad(_ id: String,
                    camera: WPEParityCamera) throws -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? {
        guard let size = layers.layers[id]?.size, size.x > 0, size.y > 0 else { return nil }
        var placed = layers
        placed.camera = camera
        let matrix = try placed.projection(id) * placed.view(id, parallax: parallax.smoothed) * placed.model(id)
        let pixels = logicalSize
        func corner(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let clip = matrix * SIMD4(x, y, 0, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            return SIMD2((ndc.x + 1) * 0.5, (1 - ndc.y) * 0.5) * pixels
        }
        let half = size * 0.5
        return (corner(-half.x, -half.y), corner(half.x, -half.y),
                corner(half.x, half.y), corner(-half.x, half.y))
    }

    /// The native text dirty hook is consumed only after this ordered cohort is admitted.
    private func applyScriptText() {
        let textGeneration = state.generation(.textLayout)
        let effectsGeneration = state.effectVisibilityGeneration
        let changed = textGeneration != (pendingScriptTextGeneration ?? seenScriptText)
        let effectsChanged = effectsGeneration != (pendingTextEffectsGeneration ?? seenEffects)
        guard changed || effectsChanged else { return }
        discardSupersededFailedTexts()
        // Discarding a failed cohort also drops its pending receipt; its canonical fields remain unconsumed.
        let projectFields = textGeneration != (pendingScriptTextGeneration ?? seenScriptText)
        var latest = textPipeline.texts.mapValues(\.object)
        for request in textRequests {
            latest[request.object.id] = request.object
        }
        for sceneObject in plan.scene.scene.objects {
            guard var object = latest[sceneObject.id] else { continue }
            if projectFields {
                object = WPEParityTextFields.applying(to: object, state: state)
            }
            let effects = state.effects.indices.count {
                state.effects[$0].objectID == object.id && state.effectVisibility[$0]
            }
            textRequests.append(.init(object, effectCount: effects))
        }
        pendingScriptTextGeneration = textGeneration
        pendingTextEffectsGeneration = effectsGeneration
    }

    private func discardSupersededFailedTexts() {
        guard failedTextRequestCount > 0 else { return }
        // Only the failed attempted prefix is superseded; preserve an already appended unattempted tail.
        textRequests.removeFirst(failedTextRequestCount)
        failedTextRequestCount = 0
        pendingScriptTextGeneration = nil
        pendingTextEffectsGeneration = nil
    }

    private func consumeTextRequests(_ count: Int) {
        textRequests.removeFirst(count)
        failedTextRequestCount = 0
        if let generation = pendingScriptTextGeneration {
            seenScriptText = generation
        }
        pendingScriptTextGeneration = nil
        pendingTextEffectsGeneration = nil
    }

    /// Prepare all text/atlas/geometry/RT values on this serial owner, then publish once after CPU accept.
    private func replanRelaidTexts() throws {
        guard !textRequests.isEmpty else { return }
        let attemptedCount = textRequests.count
        failedTextRequestCount = 0
        var completed = false
        defer {
            if !completed {
                failedTextRequestCount = attemptedCount
            }
        }
        let pipeline = textPipeline
        let requested = try WPEParityTextFieldAdmission.requests(textRequests, texts: pipeline.texts)
        guard let prepared = try pipeline.prepareRelayouts(requested) else {
            consumeTextRequests(attemptedCount)
            completed = true
            return
        }
        var accepted = false
        defer {
            if !accepted {
                try? pipeline.discard(prepared)
            }
        }
        let changed = Set(prepared.changedObjectIDs)
        var candidatePlanner = planner
        guard candidatePlanner.updateTexts(prepared.changedObjectIDs.compactMap { prepared.texts[$0] },
                                           atlases: prepared.atlases) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        var candidateLayers = layers
        for id in prepared.changedObjectIDs {
            guard let text = prepared.texts[id] else { continue }
            candidateLayers.setSize(id, size: SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))
        }
        let current = graphs.layout
        let planned = try plan.layout(effects: state, texts: prepared.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let kept = current.draws.filter { index, _ in
            guard case let .scene(draw)? = current.frames[0].draws[index] else { return true }
            guard changed.contains(draw.objectID) else { return true }
            // makeLayout still checks the actual program/source, resources and frame compatibility before reuse.
            guard case .textGlyphs = draw.geometry, let before = planner.texts[draw.objectID],
                  let after = prepared.texts[draw.objectID] else { return false }
            return before.layout == after.layout && before.atlasKey == after.atlasKey
        }
        let reuse = Layout(planned: current.planned, effects: current.effects, draws: kept,
                           skipped: current.skipped, fade: current.fade)
        var layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                         planner: &candidatePlanner, encoder: drawEncoder,
                                         state: state, reusing: reuse)
        // makeLayout records per-draw failures as skips. Required readers of this changed text cohort cannot
        // be silently dropped while its CPU atlas/ref/layout is accepted.
        for (index, description) in planned.frames[0].draws {
            guard case let .scene(draw) = description, changed.contains(draw.objectID) else { continue }
            guard planned.programs[index] != nil, layout.draws[index] != nil else {
                throw layout.skipped[index] ?? WPEParityFrameSkip.noMaterial
            }
        }
        // A text layout must not publish a newly discovered video texture without its existing async decoder
        // admission. This synchronous transaction never constructs a second video owner.
        guard candidatePlanner.videos.count == planner.videos.count else {
            throw WPEParityFrameSkip.videoTexture("Text preparation requires an unprepared video stream")
        }
        var rebound = layout.draws
        for index in rebound.keys {
            candidatePlanner.refreshTextParameters(&rebound[index]!, operation: index)
            try candidatePlanner.refreshAtlasBindings(&rebound[index]!, operation: index)
        }
        layout = Layout(planned: layout.planned, effects: layout.effects, draws: rebound,
                        skipped: layout.skipped, fade: layout.fade)
        let readinessChanged = Set(layout.draws.keys) != Set(current.draws.keys)
        let requiresRebuild = prepared.delta.changes.contains { $0.requiresFrameRebuild }
        let gpu: PreparedGraphs = if requiresRebuild || readinessChanged || layout.effects != current.effects {
            try prepareGraphs(layout)
        } else {
            PreparedGraphs(graphs: Graphs(layout: layout, hidden: graphs.hidden, executors: graphs.executors,
                                          operations: graphs.operations, particleDraws: graphs.particleDraws,
                                          particleSnapshotSkips: graphs.particleSnapshotSkips),
                           targets: targets, samplers: targetSamplers, initialization: nil)
        }
        #if DEBUG
        try textPreparationCheckpoint?(textSnapshot(planner: candidatePlanner, layers: candidateLayers,
                                                    graphs: gpu.graphs, targets: gpu.targets,
                                                    pipelineAtlases: prepared.atlases,
                                                    initialization: gpu.initialization))
        #endif
        // Last throwing operation. No await, GPU allocation, graph encode or other admission follows accept.
        try pipeline.accept(prepared)
        accepted = true
        planner = candidatePlanner
        layers = candidateLayers
        layersMoved = true
        publishGraphs(gpu, cachePrevious: false)
        pipeline.atlases = candidatePlanner.textAtlases.atlases
        packedConstants.removeAll()
        fadeConstants.removeAll()
        for id in prepared.changedObjectIDs {
            guard let text = prepared.texts[id] else { continue }
            state.setScriptField("size", of: id, to: .vector(SIMD4(lowHalf: text.scriptSize, highHalf: .zero)),
                                 invalidating: .none)
        }
        consumeTextRequests(attemptedCount)
        completed = true
        repackBloom()
    }

    /// Advances the clock by `elapsed` seconds and the engine inputs by one frame, then commits the frame.
    /// `paused` ramps scene time down to a hold, and back up once it is false again.
    func encodeFrame(elapsed: Double, paused: Bool = false,
                     input: WPEParityFrameInput = WPEParityFrameInput()) throws -> WPEParityGraphExecutor.Submission {
        // Native object updates precede this frame's camera selection and matrix-stack publication.
        let objectCamera = pathCamera
        guard clock.advance(elapsed: elapsed, paused: paused) else { return .skipped }
        let shortcutTextures = userShortcutIcons?.snapshot() ?? [:]
        let time = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: input.date)
        let daytime = WPEParityClock.daytime(hour: time.hour ?? 0, minute: time.minute ?? 0,
                                             second: time.second ?? 0, millisecond: (time.nanosecond ?? 0) / 1_000_000)
        applyAnimationLayerFields()
        // Scene time, so a paused clock holds the pose.
        for id in puppets.keys {
            puppets[id]?.advance(dt: Double(clock.frametime))
        }
        for id in textureAnimations.keys {
            textureAnimations[id]?.step(dt: clock.frametime, durations: planner.layerSprites(id).map { Float($0.duration) })
        }
        pointer.advance(cursor: input.cursor, screen: screen, buttonDown: input.buttonDown)
        let scriptCursor = input.cursor * logicalSize / SIMD2(Float(backbuffer.width), Float(backbuffer.height))
        applyTransforms()
        applyLayerFields()
        updateSceneObjects(camera: objectCamera, timeOfDay: daytime)
        selectCamera(dt: clock.frametime)
        let fadeAlpha = cameraPaths.fadeAlpha
        let camera = pathCamera
        // 1401891a0.c:288: the smoothed parallax only moves while camera parallax is on.
        let updateParallax = cameraParallax
        if updateParallax.enabled {
            parallax.advance(pointer: pointer.position, mouseInfluence: Float(updateParallax.mouseInfluence),
                             delay: Float(updateParallax.delay), eye: SIMD2(camera.eye.x, camera.eye.y),
                             ortho: camera.size,
                             frametime: clock.frametime)
        }
        let silence = [Float](repeating: 0, count: 64)
        audio.advance(left: input.audio?.left ?? silence, right: input.audio?.right ?? silence,
                      dt: clock.frametime, silence: input.audio == nil)
        var uniforms = WPEParityUniformFrame(clock: clock, daytime: daytime, screen: screen, pointer: pointer,
                                             parallax: parallax, eyePosition: camera.eyePosition, view: camera.view,
                                             audio: audio)
        if let script {
            script.prepareFrame(frame: UInt64(frameIndex), dt: clock.frametime, runtime: clock.timeUniform,
                                cursor: scriptCursor, world: cursorWorld(camera: camera),
                                leftDown: input.buttonDown, timeOfDay: daytime)
            script.updateAudio(audio.bins)
            try runScriptEvents(script, camera: camera, cursor: scriptCursor, buttonDown: input.buttonDown, timeOfDay: daytime)
        }
        consumeMediaInputs()
        // R24 Q1: animations run after the object update and the camera, and render reads their values.
        animations.advance(dt: clock.frametime, state: &state)
        if let script {
            for event in animations.firedEvents {
                script.engine.dispatch(.animationEvent, payloadJSON: event.payloadJSON, target: event.objectID, state: &state)
            }
            // 140171440.c:888-896: the tick after the animations, so update sees this frame's animated values.
            script.tick(dt: clock.frametime, cursor: scriptCursor, world: cursorWorld(camera: camera),
                        leftDown: input.buttonDown, timeOfDay: daytime, state: &state)
        }
        // 18aac0 reads the post-tick Bool/amount with the smoother already advanced by 1891a0 above.
        let renderCamera = pathCamera
        videos.applyScriptFields(state: &state)
        applyTransforms()
        applyLayerFields()
        applyScriptBloom()
        try applyScriptLighting(camera: renderCamera)
        uniforms.lights = lights
        applyScriptText()
        try replanRelaidTexts()
        // 14018aac0.c:206 keys with g_ViewForward, which comes from the pre-script camera (14017fa70.c:383-387).
        if plan.scene.scene.transparentSorting {
            state.sortTransparentMembers(viewForward: WPEParityUniformParallax.viewVectors(view: camera.view).forward)
        }
        try selectGraphs()
        let graphs = graphs
        let draws = graphs.layout.draws
        let live = layersMoved ? layers : nil
        let variant = frameIndex % graphs.executors.count
        frameIndex += 1
        let dropped = droppedParticleBatches
        defer {
            videos.finishFrame()
            if growsParticleShare, droppedParticleBatches > dropped, particles.budget < Self.maxParticleShare {
                particles.budget = min(particles.budget * 2, Self.maxParticleShare)
                arena.capacity = baseArenaBytes + particles.budget
            }
        }
        lastFrameDraws.removeAll(keepingCapacity: true)
        let executor = graphs.executors[variant]
        executor.restoreResourceBindings(resourceBindings)
        // Encoding can throw after submitting a prefix. Carry every reached swap into the next frame too.
        defer { resourceBindings = executor.resourceBindings }
        var particleStreams: [Int: WPEParityParticleDrawStream] = [:]
        let blocks = graphs.layout.frames[variant].particleBlocks
        func stream(for block: Int) throws -> WPEParityParticleDrawStream? {
            if let cached = particleStreams[block] {
                return cached
            }
            let particleBlock = blocks[block]
            let objectID = particleBlock.objectID
            let facts = particleFullFrameBuffer[objectID, default: [:]]
            let failures = particleBaseFailures[objectID, default: [:]]
            let worldModel = particleBlock.compositeOwnerID.map { layers.model($0).inverse }
                ?? matrix_identity_float4x4
            let stream = try particles.scene.drawStream(objectID: objectID, ownerModel: layers.world(objectID),
                                                        worldModel: worldModel) { path in
                if failures[path] != nil {
                    return nil
                }
                guard let fact = facts[path] else {
                    throw WPEParityFrameSkip.program("missing particle base-material fact: \(objectID) \(path)")
                }
                return fact
            }
            particleStreams[block] = stream
            return stream
        }
        return try executor.encodeFrame(on: queue, textures: targets.merging(planner.layerImages) { $1 },
                                        prepare: { commandBuffer in
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
                                                return particleStreams[block]?.snapshotBoundary != nil
                                            }
                                            return true
                                        }, clearColor: { pass in
                                            guard let owner = textBackgroundOwners[pass], let color = backgroundColor(of: owner) else { return nil }
                                            return WPEClearColor(red: Double(color.x), green: Double(color.y),
                                                                 blue: Double(color.z), alpha: Double(color.w))
                                        }, visit: { step, textures, arena, emit in
                                            func encode(_ provided: WPEParityDraw, operation: Int) throws {
                                                var provided = provided
                                                for (name, texture) in provided.textures {
                                                    if let sampler = targetSamplers[ObjectIdentifier(texture)] {
                                                        provided.samplers[name + "SamplerState"] = sampler
                                                    }
                                                }
                                                lastFrameDraws.append((operation, provided))
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
                                                                                                textures: textures, arena: arena, textureSlots: &textureSlots,
                                                                                                renderVars: &renderVars, particles: &particles, layers: live,
                                                                                                mediaTexture: { mediaTextures?.texture(for: $0) },
                                                                                                userShortcutTexture: { shortcutTextures[$0] }) {
                                                        // Encode argument tables before the next batch reserves any vertex bytes.
                                                        try encode(provided, operation: operation)
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
                                                plan.applyRenderVarWrites(to: &renderVars)
                                                let color = drawColor(operation: operation, variant: variant, plan: plan)
                                                let provided = try plan.makeDraw(frame: uniforms, camera: renderCamera, variant: variant, textures: textures,
                                                                                 textureSlots: &textureSlots, puppets: puppets,
                                                                                 textureAnimations: textureAnimations, layers: live,
                                                                                 constants: fade ? fadeConstants : postConstants[operation] ?? materialConstants(operation, plan),
                                                                                 layerColor: color == plan.layerColor?.loaded ? nil : color,
                                                                                 renderVar0: plan.clipMaskInverted == nil ? nil : renderVars.rv0,
                                                                                 textRenderVarState: plan.textRenderVars == nil ? nil : renderVars,
                                                                                 mediaTexture: { mediaTextures?.texture(for: $0) },
                                                                                 userShortcutTexture: { shortcutTextures[$0] })
                                                guard case let .scene(description)? = graphs.layout.frames[variant].draws[operation],
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
    private func drawColor(operation: Int, variant: Int, plan: WPEParityFrameDrawPlan) -> SIMD4<Float>? {
        guard case let .scene(description)? = graphs.layout.frames[variant].draws[operation],
              description.geometry == .textBackground else {
            return plan.layerColor.map { state.layerColor(at: $0.object) }
        }
        return backgroundColor(of: description.objectID)
    }

    private func backgroundColor(of objectID: String) -> SIMD4<Float>? {
        guard let text = planner.texts[objectID] else { return nil }
        var brightness = text.object.backgroundBrightness
        if case let .vector(value)? = state.scriptField("backgroundbrightness", of: objectID) {
            brightness = value.x
        }
        return SIMD4(text.object.backgroundColor * (state.hdr ? brightness : 1),
                     state.object(objectID)?.alpha ?? text.object.alpha)
    }

    /// The draw's constants, re-packed from the state only after its material pass changed (R24 Q3).
    private func materialConstants(_ operation: Int,
                                   _ plan: WPEParityFrameDrawPlan) -> [WPEHLSLStage: [String: WPECBufferValue]] {
        guard let pass = plan.materialPass else { return plan.constants }
        let generation = state.constantGeneration(pass: pass)
        guard generation != 0 else { return plan.constants }
        if let packed = packedConstants[operation], packed.generation == generation {
            return packed.constants
        }
        var constants = plan.constants
        let values = state.constants(pass: pass)
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

    /// Moves the layer worlds to the state's transforms when any changed, and every frame while a child hangs on a
    /// puppet attachment point, whose bones this frame's animator step moved (R24 Q4).
    private func applyTransforms() {
        let moved = state.transformGeneration != seenTransforms
        guard moved || layers.hasAttachments else { return }
        if moved {
            seenTransforms = state.transformGeneration
            for (index, id) in state.ids.enumerated() {
                let object = state.objects[index]
                layers.setTransform(id, origin: object.origin, angles: object.angles, scale: object.scale)
            }
        }
        layers.refreshWorlds { puppets[$0]?.boneWorld }
        layersMoved = true
    }

    /// Encodes the frame with the effects the state shows and without the operations of hidden objects. A change
    /// recompiles the graphs, and an effect change re-plans the draws it alters, except when it returns to the
    /// previous set.
    private func selectGraphs() throws {
        let currentPost = plan.postConfig(state: state)
        let effectiveN = currentPost.hdrEnabled && currentPost.bloomEnabled ? currentPost.hdrBloomLevelCount : 0
        func matchesPost(_ post: WPEParityPostProcessConfig) -> Bool {
            post.bloomEnabled == currentPost.bloomEnabled
                && (post.hdrEnabled && post.bloomEnabled ? post.hdrBloomLevelCount : 0) == effectiveN
        }
        if state.membershipGeneration == seenMembership, state.modelDataGeneration != seenModelData,
           refreshModelDataDrawVersions() {
            seenModelData = state.modelDataGeneration
        }
        if state.membershipGeneration != seenMembership || state.modelDataGeneration != seenModelData {
            if state.membershipGeneration != seenMembership {
                layers = plan.modelDataTransforms(state: state, existing: layers)
                planner.adoptModelDataTransforms(layers)
                layersMoved = true
            }
            let previous = graphs.layout
            let planned = try plan.layout(effects: state, texts: planner.texts,
                                          mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
            let layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                             planner: &planner, encoder: drawEncoder,
                                             state: state, reusing: previous)
            // Removed owners cannot return through the visibility cache. Existing command buffers retain
            // their submitted resource versions; this drops the renderer's obsolete draw/graph references.
            try installGraphs(layout, cachePrevious: false)
            retireRemovedObjects(from: previous.planned)
            packedConstants.removeAll()
            fadeConstants.removeAll()
            seenMembership = state.membershipGeneration
            seenModelData = state.modelDataGeneration
            repackBloom()
        }
        guard state.visibilityGeneration != seenVisibility || state.effectVisibilityGeneration != seenEffects
            || !matchesPost(graphs.layout.post) else {
            return
        }
        let hidden = state.objects.indices.map { !state.isVisible(at: $0) }
        let effects = state.effectVisibility
        if hidden != graphs.hidden || effects != graphs.layout.effects || !matchesPost(graphs.layout.post) {
            if let previous = previousGraphs, previous.hidden == hidden, previous.layout.effects == effects,
               matchesPost(previous.layout.post),
               previous.executors.allSatisfy({ executor in
                   executor.graph.resources.values.allSatisfy { resource in
                       resource.lifetime == .imported || executor.transientTextures[resource.id] != nil
                           || targets[resource.id].map { Self.matches($0, resource: resource) } == true
                   }
               }) {
                (graphs, previousGraphs) = (previous, graphs)
                planner.use(graphs.layout.planned)
                targetSamplers = Self.targetSamplers(graphs.layout, targets: targets)
            } else {
                var layout = graphs.layout
                if effects != layout.effects || !matchesPost(layout.post) {
                    layout = try Self.makeLayout(plan.layout(effects: state, texts: planner.texts,
                                                             mipMappedFrameBufferRequested: mipMappedFrameBufferRequested), effects: effects,
                                                 artifacts: artifacts, planner: &planner, encoder: drawEncoder,
                                                 state: state, reusing: layout)
                }
                try installGraphs(layout, cachePrevious: true)
            }
            packedConstants.removeAll()
            fadeConstants.removeAll()
            repackBloom()
        }
        seenVisibility = state.visibilityGeneration
        seenEffects = state.effectVisibilityGeneration
    }

    /// Drops the images and targets only objects removed since `previous` used; the next committed frame retires them.
    private func retireRemovedObjects(from previous: WPEParityFrameLayout) {
        let removed = Set(previous.frames.flatMap(\.owners.values).filter { !state.isAlive($0) })
        guard !removed.isEmpty else { return }
        retiredTextures += planner.releaseImages(of: removed, droppedFrom: previous)
        var kept = Set(graphs.layout.frames.flatMap(\.resources).map(\.id))
        var owned: Set<WPEResourceID> = []
        for frame in previous.frames {
            for (index, operation) in frame.operations.enumerated() {
                if frame.owners[index].map(removed.contains) == true {
                    owned.formUnion(Self.touchedResources(operation.kind))
                } else {
                    kept.formUnion(Self.touchedResources(operation.kind))
                }
            }
        }
        for id in owned.subtracting(kept) {
            if let texture = targets.removeValue(forKey: id) {
                retiredTextures.append(texture)
            }
        }
    }

    private static func touchedResources(_ kind: WPERenderOperation.Kind) -> [WPEResourceID] {
        switch kind {
        case let .setTargets(color, depth): (color + [depth].compactMap(\.self)).map(\.resource)
        case let .clearColor(view, _), let .clearDepth(view, _): [view.resource]
        case let .draw(draw): draw.reads.map(\.resource)
        case let .copy(source, destination), let .resolve(source, destination),
             let .swapResources(source, destination): [source, destination]
        case let .resourceScope(_, resources): resources
        case let .generateMips(id): [id]
        }
    }

    /// Equal-layout buffer writes replace only the existing draw's immutable resource version. Membership,
    /// shape count, placement or material/program/layout changes take the ordinary graph transaction above.
    private func refreshModelDataDrawVersions() -> Bool {
        let layout = graphs.layout
        var draws = layout.draws
        var shapes: [Int: WPEParitySceneModelData.Shape] = [:]
        var indices: [String: Set<Int>] = [:]
        for (operation, description) in layout.frames[0].draws {
            guard case let .scene(description) = description,
                  let token = state.object(description.objectID)?.modelDataToken else { continue }
            guard description.geometry == .modelMesh, let model = state.modelData(token),
                  let index = WPEParitySceneModel.meshIndex(description.pass, objectID: description.objectID),
                  model.shapes.indices.contains(index),
                  let prepared = model.shapes[index].prepared as? WPEParityModelDataMetalShape,
                  var draw = draws[operation], case let .modelData(previous) = draw.geometry,
                  prepared.canReplaceDrawVersion(previous),
                  let placement = draw.placement, placement.objectID == description.objectID,
                  placement.kind == .layer, placement.compositeOwnerID == nil, placement.text == nil,
                  let transform = layers.layers[description.objectID], transform.parentID == nil,
                  layout.frames.allSatisfy({ frame in
                      guard case let .scene(other)? = frame.draws[operation] else { return false }
                      return other.pass == description.pass && other.objectID == description.objectID
                          && other.geometry == .modelMesh && other.compositeOwnerID == nil
                  }) else { return false }
            indices[description.objectID, default: []].insert(index)
            draw.geometry = .modelData(prepared)
            draws[operation] = draw
            shapes[operation] = model.shapes[index]
        }
        for id in state.commonOrder {
            guard let token = state.object(id)?.modelDataToken, let model = state.modelData(token) else { continue }
            guard indices[id] == Set(model.shapes.indices) else { return false }
        }
        var planned = layout.planned
        planned.modelDataShapes = shapes
        let replaced = Layout(planned: planned, effects: layout.effects, draws: draws,
                              skipped: layout.skipped, fade: layout.fade)
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        previousGraphs = nil
        planner.use(planned)
        graphs = Graphs(layout: replaced, hidden: graphs.hidden, executors: graphs.executors,
                        operations: graphs.operations, particleDraws: graphs.particleDraws,
                        particleSnapshotSkips: graphs.particleSnapshotSkips)
        return true
    }

    /// Candidate values on the existing renderer. Initialization touches only newly allocated target versions.
    private struct PreparedGraphs {
        let graphs: Graphs
        let targets: [WPEResourceID: MTLTexture]
        let samplers: [ObjectIdentifier: WPEParitySamplerState]
        let initialization: MTLCommandBuffer?
    }

    private func prepareGraphs(_ layout: Layout) throws -> PreparedGraphs {
        var candidateTargets = targets
        let made = try Self.makeGraphs(layout: layout, state: state, device: device, encoder: drawEncoder,
                                       arena: arena, targets: &candidateTargets, resourceBindings: resourceBindings,
                                       snapshotObjects: particleSnapshotObjects)
        let added = candidateTargets.filter { id, texture in
            targets[id].map { ObjectIdentifier($0) != ObjectIdentifier(texture) } ?? true
        }
        let initialization = try Self.clear(Array(added.values), queue: queue,
                                            colors: Self.clearColors(layout, targets: added))
        return PreparedGraphs(graphs: made, targets: candidateTargets,
                              samplers: Self.targetSamplers(layout, targets: candidateTargets),
                              initialization: initialization)
    }

    /// All fallible preparation precedes this same-owner value publication.
    private func publishGraphs(_ prepared: PreparedGraphs, cachePrevious: Bool) {
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        previousGraphs = cachePrevious ? graphs : nil
        graphs = prepared.graphs
        // Named pool history survives graph changes; Metal retains submitted texture versions.
        targets = prepared.targets
        targetSamplers = prepared.samplers
    }

    /// Existing non-text callers use the same preparation and publication, with unchanged clear policy.
    private func installGraphs(_ layout: Layout, cachePrevious: Bool) throws {
        let prepared = try prepareGraphs(layout)
        publishGraphs(prepared, cachePrevious: cachePrevious)
    }

    /// A resized non-unique FBO receives a new physical ID. Preserve the effect's binding permutation by the
    /// authored swap command identity, including effects currently disabled on both sides of the resize.
    private func migratedBindings(from previous: WPEParityFrameRenderer) throws -> WPEParityResourceBindings {
        func swaps(_ plan: WPEParityFramePlan) throws -> [WPEPassIdentity: (WPEResourceID, WPEResourceID)] {
            var result: [WPEPassIdentity: (WPEResourceID, WPEResourceID)] = [:]
            for probe in try plan.probeFrames() {
                for operation in probe.frame.operations {
                    if case let .swapResources(first, second) = operation.kind {
                        result[operation.pass] = (first, second)
                    }
                }
            }
            return result
        }
        let old = try swaps(previous.plan)
        let current = try swaps(plan)
        var ids: [WPEResourceID: WPEResourceID] = [:]
        for (pass, pair) in old {
            guard let next = current[pass] else { continue }
            ids[pair.0] = next.0
            ids[pair.1] = next.1
        }
        return previous.resourceBindings.mapValues { bindings in
            Dictionary(bindings.map { (ids[$0.key] ?? $0.key, ids[$0.value] ?? $0.value) }) { first, _ in first }
        }
    }

    private static func targetSamplers(_ layout: Layout, targets: [WPEResourceID: MTLTexture])
        -> [ObjectIdentifier: WPEParitySamplerState] {
        var result: [ObjectIdentifier: WPEParitySamplerState] = [:]
        for frame in layout.frames {
            for (id, sampler) in frame.samplers {
                guard let texture = targets[id] else { continue }
                result[ObjectIdentifier(texture)] = .wpe(filter: sampler.filter == .point ? .point : .linear,
                                                         address: sampler.address == .wrap ? .wrap : .clamp)
            }
        }
        return result
    }

    /// Post-process constants for `bloom` where they differ from the planned ones; WPE refreshes them on the next
    /// frame (R24 Q5).
    private func repackBloom() {
        postConstants.removeAll()
        let layout = graphs.layout
        guard bloom != layout.post.bloomSettings else { return }
        var config = layout.post
        config.bloomSettings = bloom
        // A State write may precede this frame's selectGraphs. Its new N must first publish an admitted layout;
        // otherwise index-zipping constants could apply to different down/up passes or silently drop the update.
        guard !layout.post.hdrEnabled || !layout.post.bloomEnabled
            || config.hdrBloomLevelCount == layout.post.hdrBloomLevelCount else { return }
        let operations = layout.frames[0].draws.compactMap { index, draw -> Int? in
            if case .post = draw {
                index
            } else {
                nil
            }
        }.sorted()
        let rebuilt = WPEParityPostProcessBuilder.build(config).draws
        guard operations.count == rebuilt.count else { return }
        guard zip(operations, rebuilt).allSatisfy({ operation, draw in
            guard case let .post(planned)? = layout.frames[0].draws[operation] else { return false }
            return planned.shader == draw.shader && planned.material == draw.material && planned.reads == draw.reads
        }) else { return }
        for (operation, draw) in zip(operations, rebuilt) {
            guard case let .post(planned)? = layout.frames[0].draws[operation], planned.constants != draw.constants,
                  let constants = layout.draws[operation]?.constants else { continue }
            let values = draw.constants.mapValues { $0.count == 1 ? WPECBufferValue.float($0[0]) : .vector($0) }
            postConstants[operation] = constants.mapValues { $0.merging(values) { $1 } }
        }
    }

    /// Plans `planned`'s draws in operation order, so the planner's layer images and videos come out the same every
    /// build; a draw `previous` has unchanged keeps its plan.
    private static func makeLayout(_ planned: WPEParityFrameLayout, effects: [Bool],
                                   artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>],
                                   planner: inout WPEParityFrameDrawPlanner, encoder: WPEParityDrawEncoder,
                                   state: WPEParitySceneState, reusing previous: Layout?) throws -> Layout {
        planner.use(planned)
        let names = drawNames(planned.frames[0])
        var earlier: [DrawName: Int] = [:]
        for (index, name) in previous.map({ drawNames($0.frames[0]) }) ?? [:] {
            earlier[name] = index
        }
        // Per frame; the first resource with an id wins, as `first(where:)` would.
        let byID: (WPEParityFrame) -> [WPEResourceID: WPELogicalResource] = { frame in
            Dictionary(frame.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let currentResources = previous == nil ? [] : planned.frames.map(byID)
        let previousResources = previous?.frames.map(byID) ?? []
        var draws: [Int: WPEParityFrameDrawPlan] = [:]
        var skipped = planned.skipped
        for (index, program) in planned.programs.sorted(by: { $0.key < $1.key }) {
            if let previous, previous.frames.count == planned.frames.count,
               let match = names[index].flatMap({ earlier[$0] }), let plan = previous.draws[match],
               Self.sameModelDataVersion(planned.modelDataShapes[index], geometry: plan.geometry),
               planned.frames.indices.allSatisfy({
                   planned.frames[$0].draws[index] == previous.frames[$0].draws[match]
                       && Self.resourcesMatch(planned.frames[$0], currentResources[$0], previous.frames[$0],
                                              previousResources[$0], draw: index)
               }) {
                draws[index] = plan
                continue
            }
            let artifact = artifacts[program.hlsl] ?? .failure(.noShader("\(program.shader): not compiled at load"))
            do throws(WPEParityFrameSkip) {
                let draw = try planner.makePlan(index, artifact: artifact.get(), state: state)
                try Self.prepare(draw, encoder: encoder)
                draws[index] = draw
            } catch {
                skipped[index] = error
            }
        }
        for (index, description) in planned.frames[0].draws {
            if let pass = requiredPost(description), draws[index] == nil {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: pass, reason: skipped[index] ?? .noMaterial
                )
            }
        }
        if let requiredPresentationPass = planned.requiredPresentationPass {
            let terminalIndex = planned.frames[0].draws.first { _, draw in
                guard case let .post(post) = draw else { return false }
                return post.shader == requiredPresentationPass
            }?.key
            guard let index = terminalIndex, draws[index] != nil, let program = planned.programs[index] else {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: requiredPresentationPass, reason: terminalIndex.flatMap { skipped[$0] } ?? .noMaterial
                )
            }
            try validatePresentation(program, pass: requiredPresentationPass, post: planned.post)
        }
        let fade = planned.frames[0].draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "fade"
            } else {
                false
            }
        }?.key
        return Layout(planned: planned, effects: effects, draws: draws, skipped: skipped, fade: fade)
    }

    private static func requiredPost(_ draw: WPEParityFrameDraw) -> String? {
        guard case let .post(post) = draw, post.shader != "fade", post.shader != "ccsimple" else { return nil }
        return post.shader
    }

    private static func validatePresentation(_ program: WPEParityProgram, pass: String,
                                             post: WPEParityPostProcessConfig) throws {
        let expectedShader = pass == "combine_hdr" ? "combine_hdr" : "passthroughsrgb"
        // DISPLAYHDR=1 writes above reference white, which only a half-float backbuffer keeps.
        let displayHDR = pass == "combine_hdr" && post.displayHDREnabled
            && WPEParityFrameDrawPlanner.pixelFormats[post.backbufferFormat] == .rgba16Float
        guard program.shader == expectedShader,
              !program.combos.contains(where: { combo in
                  combo.value == "1" && (combo.name == "LINEAR" || combo.name == "DISPLAYHDR" && !displayHDR)
              }) else {
            throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                pass: pass, reason: .program("Unsupported HDR presentation shader or transfer combo: \(program.shader)")
            )
        }
    }

    private static func sameModelDataVersion(_ shape: WPEParitySceneModelData.Shape?,
                                             geometry: WPEParityFrameDrawPlan.Geometry) -> Bool {
        switch (shape, geometry) {
        case let (shape?, .modelData(previous)):
            (shape.prepared as? WPEParityModelDataMetalShape) === previous
        case (nil, .modelData): false
        case (nil, _): true
        default: false
        }
    }

    /// Resource and sampler creation is validated before the graph promises a draw's writes.
    private static func prepare(_ draw: WPEParityFrameDrawPlan,
                                encoder: WPEParityDrawEncoder) throws(WPEParityFrameSkip) {
        do {
            for textures in draw.textures {
                try encoder.prepare(pipeline: draw.pipeline, depthStencil: draw.depthStencil,
                                    textureNames: Set(textures.keys), samplers: draw.samplers)
            }
        } catch {
            throw .pipeline(String(describing: error))
        }
    }

    private static func resourcesMatch(_ current: WPEParityFrame, _ currentResources: [WPEResourceID: WPELogicalResource],
                                       _ previous: WPEParityFrame,
                                       _ previousResources: [WPEResourceID: WPELogicalResource], draw: Int) -> Bool {
        guard let description = current.draws[draw] else { return false }
        let ids: Set<WPEResourceID> = switch description {
        case let .scene(scene): Set(scene.reads + [scene.target])
        case let .post(post): Set(post.reads)
        }
        for id in ids {
            guard currentResources[id] == previousResources[id],
                  current.samplers[id] == previous.samplers[id] else { return false }
        }
        return true
    }

    private static func drawNames(_ frame: WPEParityFrame) -> [Int: DrawName] {
        var counts: [WPEPassIdentity: Int] = [:]
        var names: [Int: DrawName] = [:]
        for index in frame.draws.keys.sorted() {
            let pass = frame.operations[index].pass
            names[index] = DrawName(pass: pass, occurrence: counts[pass, default: 0])
            counts[pass, default: 0] += 1
        }
        return names
    }

    /// Prepare only the HDR pyramid on the existing target owner, including a reachable cold-off branch.
    /// Declaring unused pooled resources does not give them a graph lifetime, so makeGraphs alone cannot do this.
    private static func prepareHDRBloomTargets(_ post: WPEParityPostProcessConfig, device: MTLDevice,
                                               targets: inout [WPEResourceID: MTLTexture]) throws {
        guard post.hdrEnabled else { return }
        var capacity = post
        capacity.sceneBloomEnabled = true
        capacity.userBloomEnabled = true
        capacity.objectTableNonEmpty = true
        capacity.bloomSettings.hdrIterations = capacity.hdrBloomCapacity
        let ids = Set((1 ... capacity.hdrBloomCapacity).map { WPEResourceID("_rt_\(1 << $0)FrameBuffer") })
        for resource in WPEParityPostProcessBuilder.build(capacity).resources where ids.contains(resource.id) {
            guard resource.lifetime == .pooled else { continue }
            if let texture = targets[resource.id], matches(texture, resource: resource) {
                continue
            }
            targets[resource.id] = try makeTarget(resource, device: device)
        }
    }

    /// Compiles each frame variant of `layout` without the operations of objects `state` hides, allocating the
    /// targets the graphs need that `targets` lacks.
    private static func makeGraphs(layout: Layout, state: WPEParitySceneState, device: MTLDevice,
                                   encoder: WPEParityDrawEncoder, arena: WPEParityFrameArena,
                                   targets: inout [WPEResourceID: MTLTexture],
                                   resourceBindings: WPEParityResourceBindings = [:], snapshotObjects: Set<String>) throws -> Graphs {
        var executors: [WPEParityGraphExecutor] = []
        var operations: [[WPEParityGraphDrawSource]] = []
        var particleDraws: [WPEParityParticleDrawKey: Int] = [:]
        var snapshotSkips: [String: WPEParityFrameSkip] = [:]
        for (index, description) in layout.frames[0].draws {
            if case let .scene(draw) = description, case let .particles(key) = draw.geometry {
                particleDraws[key] = index
            }
        }
        for (variant, frame) in layout.frames.enumerated() {
            let projected = WPEParityParticleGraph(frame: frame, state: state, draws: layout.draws, variant: variant,
                                                   snapshotObjects: snapshotObjects)
            snapshotSkips.merge(projected.snapshotSkips) { first, _ in first }
            let graph = try WPERenderGraphCompiler.compile(resources: frame.resources,
                                                           operations: projected.operations,
                                                           preservingTransfers: projected.preservingTransfers)
            let executor = try WPEParityGraphExecutor(graph: graph, device: device, drawEncoder: encoder, arena: arena,
                                                      pixelFormats: WPEParityFrameDrawPlanner.pixelFormats,
                                                      resourceBindings: resourceBindings)
            // Script functions can use persistent FBOs without any graph draw/read lifetime. They must be
            // allocated before module-global/init execution, while ordinary graph transients remain unchanged.
            let prepared = Set(graph.lifetimes.keys).union(frame.resources.filter { $0.lifetime == .persistent }.map(\.id))
            for id in prepared where executor.transientTextures[id] == nil {
                guard let resource = frame.resources.first(where: { $0.id == id }), resource.lifetime != .imported else { continue }
                if let texture = targets[id], Self.matches(texture, resource: resource) {
                    continue
                }
                targets[id] = try makeTarget(resource, device: device)
            }
            executors.append(executor)
            operations.append(projected.sources)
        }
        return Graphs(layout: layout, hidden: state.objects.indices.map { !state.isVisible(at: $0) },
                      executors: executors, operations: operations, particleDraws: particleDraws,
                      particleSnapshotSkips: snapshotSkips)
    }

    /// One context per visible particle object: scene time, cursor in [0, 1]² y down, the scene camera's
    /// view-projection and the object's world matrix.
    private static func particleFrames(_ objects: [(id: String, index: Int?)], state: WPEParitySceneState,
                                       layers: WPEParityLayerTransformSet, camera: WPEParityCamera, time: Float,
                                       cursor: SIMD2<Float>?, timeOfDay: Float = 0)
        -> [String: WPEParityParticleFrameContext] {
        let viewProjection = camera.projection * camera.view
        var frames: [String: WPEParityParticleFrameContext] = [:]
        for (id, index) in objects where index.map(state.isVisible(at:)) ?? true {
            frames[id] = WPEParityParticleFrameContext(time: time, cursor: cursor, viewProjection: viewProjection,
                                                       objectMatrix: layers.world(id), timeOfDay: timeOfDay)
        }
        return frames
    }

    private static func matches(_ texture: MTLTexture, resource: WPELogicalResource) -> Bool {
        texture.width == resource.width && texture.height == resource.height
            && texture.mipmapLevelCount == resource.mipCount && texture.sampleCount == resource.sampleCount
            && texture.pixelFormat == WPEParityFrameDrawPlanner.pixelFormats[resource.format]
    }

    private static func makeTarget(_ resource: WPELogicalResource, device: MTLDevice) throws -> MTLTexture {
        guard let format = WPEParityFrameDrawPlanner.pixelFormats[resource.format] else {
            throw WPEParityGraphExecutionError.unsupportedFormat(resource.format)
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = resource.sampleCount > 1 ? .type2DMultisample : .type2D
        descriptor.pixelFormat = format
        descriptor.width = resource.width
        descriptor.height = resource.height
        descriptor.mipmapLevelCount = resource.mipCount
        descriptor.sampleCount = resource.sampleCount
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEParityFrameRenderError.allocationFailed(resource.id)
        }
        texture.label = resource.id.rawValue
        return texture
    }

    private static func clearColors(_ layout: Layout, targets: [WPEResourceID: MTLTexture])
        -> [ObjectIdentifier: WPEClearColor] {
        var colors: [ObjectIdentifier: WPEClearColor] = [:]
        for resource in layout.frames.flatMap(\.resources) {
            if let color = resource.initialClear, let texture = targets[resource.id] {
                colors[ObjectIdentifier(texture)] = color
            }
        }
        return colors
    }

    /// Pooled targets can be read before their first write. Initialize every readable mip as a Mac safety policy;
    /// the original quality-enabled first-frame contents remain an evidence boundary.
    @discardableResult
    private static func clear(_ textures: [MTLTexture], queue: MTLCommandQueue,
                              colors: [ObjectIdentifier: WPEClearColor] = [:]) throws -> MTLCommandBuffer? {
        guard !textures.isEmpty else { return nil }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw WPEParityFrameRenderError.encoderUnavailable }
        for texture in textures {
            let pass = MTLRenderPassDescriptor()
            if texture.pixelFormat == .depth32Float {
                pass.depthAttachment.texture = texture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
            } else {
                let color = colors[ObjectIdentifier(texture)] ?? .init(red: 0, green: 0, blue: 0, alpha: 0)
                try WPEParityGraphExecutor.encodeColorClear(texture, color: color, on: commandBuffer)
                continue
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            encoder.endEncoding()
        }
        let mipmapped = textures.filter { $0.mipmapLevelCount > 1 && $0.pixelFormat != .depth32Float }
        if !mipmapped.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            for texture in mipmapped {
                blit.generateMipmaps(for: texture)
            }
            blit.endEncoding()
        }
        commandBuffer.commit()
        return commandBuffer
    }
}
#endif
