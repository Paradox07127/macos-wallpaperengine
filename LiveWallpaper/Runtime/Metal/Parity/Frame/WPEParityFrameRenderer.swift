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
    case requiredPostProcessUnavailable(pass: String, reason: WPEParityFrameSkip)

    var errorDescription: String? {
        switch self {
        case .missingBackbuffer: "The WPE frame has no backbuffer"
        case .arenaUnavailable: "The WPE frame arena is unavailable"
        case let .allocationFailed(resource): "The WPE frame could not allocate \(resource)"
        case .encoderUnavailable: "The WPE frame encoder is unavailable"
        case let .requiredPostProcessUnavailable(pass, reason): "Required WPE postprocess \(pass) unavailable: \(reason)"
        }
    }
}

/// Renders a plan's frames on Metal: one compiled graph per frame variant, renderer-owned dedicated and pooled
/// targets, executor-owned heap and memoryless transients. A skipped draw stays in the graph and encodes nothing.
final class WPEParityFrameRenderer {
    /// The frames of one set of shown effects and the plans of their draws (R24 Q2 "effect").
    private struct Layout {
        /// The state's effect visible bits the frames were composed with.
        let effects: [Bool]
        let frames: [WPEParityFrame]
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
    private let artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>]
    private let mipMappedFrameBufferRequested: Bool
    private var bloom: WPEParityBloomSettings
    /// Post-process draw constants for `bloom`, by draw operation, where they differ from the planned ones.
    private var postConstants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] = [:]
    private let device: MTLDevice
    private let drawEncoder: WPEParityDrawEncoder
    private let images: [WPEResourceID: MTLTexture]
    private let videos: WPEParityVideoTextures
    private let queue: MTLCommandQueue
    private let screen: WPEParityUniformScreen
    /// The scene camera; a camera path pose replaces it for the frame.
    private let rootCamera: WPEParityCamera
    private var camera: WPEParityCamera
    private var activeCameraID: String?
    /// The scene's SceneScript engine; nil for a scene without property scripts.
    private(set) var script: WPEParitySceneScript?
    private var media: WPESceneMediaEventMailbox?
    private var mediaGeneration = 0
    private(set) var mediaTextures: WPEMediaTextureStore.ParitySnapshot?
    private(set) var mediaDiagnostics: [String] = []
    var hasMediaTextureDemand: Bool {
        graphs.layout.draws.values.contains { !$0.mediaSlots.isEmpty }
    }

    private var seenScriptBloom = 0
    private var seenScriptSound = 0
    private var seenSoundVisibility = -1
    private var seenScriptLighting = -1
    private var seenLightTransforms = -1
    private var seenLightVisibility = -1
    private var seenLayerFields = -1
    private var lights: WPEParityUniformLights
    private let generalZoom: Float
    private var cameraPaths: WPEParityCameraPaths
    private var cameraPose: WPEParityCameraPose?
    /// The fade draw's planned constants with this frame's g_Alpha.
    private var fadeConstants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
    /// Only delay and mouse influence change after load; enabling or the amount is baked into the camera.
    private var cameraParallax: WPESceneCameraParallaxSettings
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
    private var textsNeedFrameRebuild = false
    private struct MaterialClear {
        let texture: MTLTexture
        let color: WPEClearColor
    }
    /// Calls retain the actual texture version and order until its clear has been encoded on a committed buffer.
    private var materialClears: [MaterialClear] = []
    private(set) var materialFunctionFailure: (any Error)?

    /// The frames of the effects the state shows; draw operation indices refer to them.
    var frames: [WPEParityFrame] {
        graphs.layout.frames
    }

    #if DEBUG
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

    /// Per encoded draw and stage, the declared constants that fall back to zero.
    var zeroConstants: [Int: [WPEHLSLStage: [String]]] {
        draws.mapValues(\.zeroConstants)
    }

    /// Per encoded draw and stage, the binding description's constants.
    var constants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] {
        draws.mapValues(\.constants)
    }

    /// The engine matrices draw `operation` packs for the current frame.
    func uniforms(_ operation: Int) -> WPEParityUniformDraw? {
        draws[operation]?.frameUniforms(parallax: parallax.smoothed, camera: pathCamera.shaken(time: clock.timeUniform),
                                        layers: layersMoved ? layers : nil)
    }

    /// The camera before the shake: the last frame's path pose, or the scene camera.
    var pathCamera: WPEParityCamera {
        camera
    }

    var heapBytes: Int {
        graphs.executors.reduce(0) { $0 + ($1.heap?.size ?? 0) }
    }

    var arenaBytes: Int {
        arena.capacity * WPEParityFrameArena.slotCount
    }

    /// Nothing the scene loaded changes its frame: no keyframe animation, particle, video, puppet, camera path,
    /// camera shake or parallax, multi-frame sprite sheet, script, audio processing, or program reading a per-frame engine input.
    let isStatic: Bool

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
    }

    /// The fixed textures video .tex draws sample.
    var videoTextures: [MTLTexture] {
        videos.textures
    }

    /// A resize reuses the video collection. Keeping that collection as the command target avoids retaining or
    /// calling the old renderer through a SceneScript engine that continues into the new frame plan.
    var scriptVideoPause: (String) -> Bool {
        { [weak videos] ownerID in videos?.pause(ownerID: ownerID) ?? false }
    }

    var scriptMaterialFunction: (WPEParitySceneState.EffectKey, String) -> Void {
        { [weak self] key, name in self?.executeMaterialFunction(key, name: name) }
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
            materialFunctionFailure = error
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
    /// Text layers re-laid since their draws were last planned.
    private var relaidTexts: Set<String> = []

    /// `particleArenaBytes` fixes each frame's particle share of the arena. By default the share starts with every
    /// particle draw at full capacity, an event group as one instance, and doubles after each frame that drops
    /// particle batches, up to `maxParticleShare`. `workshopID` keys the video disk cache; nil uses the scene
    /// directory's name.
    nonisolated(nonsending) init(plan: WPEParityFramePlan, device: MTLDevice, queue: MTLCommandQueue, shaders: WPEParityFrameShaderSource,
                                 particleSeed: UInt32 = WPEParityParticleScene.productSeed(), particleArenaBytes: Int? = nil,
                                 workshopID: String? = nil, continuing previous: WPEParityFrameRenderer? = nil) async throws {
        let factory = WPEParityPipelineFactory(device: device)
        let encoder = WPEParityDrawEncoder(factory: factory)
        var planner = WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan,
                                                preservingVideoImages: previous?.planner.videoImages ?? [:])
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
        let planned = mipRequested ? try plan.layout(effects: plan.state, mipMappedFrameBufferRequested: true) : plan.layout
        let layout = try Self.makeLayout(planned, effects: plan.state.effectVisibility, artifacts: artifacts,
                                         planner: &planner, encoder: encoder,
                                         requiredPresentationPass: plan.requiredPresentationPass, reusing: nil)
        for probe in probes {
            for (index, program) in probe.programs {
                guard case let .success(artifact)? = artifacts[program.hlsl] else { continue }
                planner.prewarmPipeline(probe.frame, index, program: program, artifact: artifact)
            }
        }
        let draws = layout.draws

        try planner.fillImportedImages()
        let videos: WPEParityVideoTextures = if let previous {
            previous.videos
        } else {
            try await WPEParityVideoTextures(streams: planner.videos,
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
        let snapshotObjects = Set(particleFacts.filter { $0.value.values.contains(true) }.map(\.key))
        let graphs = try Self.makeGraphs(layout: layout, state: plan.state, device: device, encoder: encoder,
                                         arena: arena, targets: &targets, snapshotObjects: snapshotObjects)
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
        images = planner.layerImages
        self.videos = videos
        self.queue = queue
        self.arena = arena
        self.baseArenaBytes = baseArenaBytes
        growsParticleShare = particleArenaBytes == nil
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        rootCamera = WPEParityCamera.root(document: plan.document,
                                          renderTargetSize: SIMD2(Float(plan.width), Float(plan.height)),
                                          alignment: plan.alignment)
        camera = rootCamera
        generalZoom = Float(plan.document.general.zoom)
        cameraPaths = plan.scene.cameraPaths
        layers = planner.layers
        cameraParallax = plan.document.general.cameraParallax
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
        particles = WPEParityParticleFrame(
            scene: WPEParityParticleScene(document: plan.document, assets: plan.scene.assets,
                                          engineFlags: plan.scene.engineFlags, seed: particleSeed, frames: prewarm),
            budget: particleBytes
        )
        let skinned = plan.scene.scene.objects.filter {
            $0.puppet?.skinned == true && plan.scene.puppetModels[$0.id] != nil
        }
        let document = plan.document
        isStatic = animations.isEmpty && particleObjects.isEmpty
            && !(mipRequested && plan.post.qualityMipMappedFrameBufferEnabled)
            && videos.textures.isEmpty && skinned.isEmpty && planner.layers.camera.shake == nil
            && plan.scene.cameraPaths.paths.isEmpty && !document.general.cameraParallax.enabled && !document.general.supportsAudioProcessing
            && !draws.values.contains { $0.sprites.values.contains { $0.count > 1 } }
            && !plan.loadPrograms.contains(where: Self.readsFrameInputs)
            && !([document.resolvedGeneralJSON] + document.resolvedObjectsJSON).contains(where: Self.hasScript)
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

    private static func hasScript(_ value: WPESceneJSONValue) -> Bool {
        switch value {
        case let .object(members): members["script"] != nil || members.values.contains(where: hasScript)
        case let .array(elements): elements.contains(where: hasScript)
        default: false
        }
    }

    /// Picks up `previous`'s scene where it stopped, for the same document planned at another size.
    func continueScene(from previous: WPEParityFrameRenderer) throws {
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
        particles = previous.particles
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
        cameraParallax = previous.cameraParallax
        camera.perspectiveFOV = previous.camera.perspectiveFOV
        camera.zoom = previous.camera.zoom
        script = previous.script
        materialFunctionFailure = previous.materialFunctionFailure
        media = previous.media
        mediaGeneration = previous.mediaGeneration
        mediaTextures = previous.mediaTextures
        mediaDiagnostics = previous.mediaDiagnostics
        seenScriptSound = previous.seenScriptSound
        seenScriptLighting = previous.seenScriptLighting
        lights = previous.lights
        // A script's bloom write reaches `bloom` below; the generation only marks it consumed.
        seenScriptBloom = previous.seenScriptBloom
        // The next frame takes the transforms, visibility and effects over from the copied state.
        seenTransforms = previous.layersMoved ? -1 : 0
        seenVisibility = -1
        seenEffects = -1
        seenMembership = -1
        bloom = previous.bloom
        for text in previous.planner.texts.values {
            recordTextDelta(textPipeline.relayoutWithDelta(text.object, effectCount: text.effectCount))
        }
        // Resize handlers may call material functions on dynamically relaid text FBOs. Prepare those actual
        // targets first, and only replace the engine callback after all throwing adoption work succeeds.
        try replanRelaidTexts()
        script?.engine.materialFunctionHandler = scriptMaterialFunction
        script?.resize(canvasSize: camera.size, screenResolution: logicalSize,
                       state: &state)
        repackBloom()
    }

    /// Writes a user-property change between frames; changed text layers are re-laid now. `changedJSON` holds the
    /// changed project properties, `mergedJSON` all of them (1401731d0.c:143-840).
    func applyUserProperties(_ update: WPEParityUserPropertyUpdate, changedJSON: String = "{}",
                             mergedJSON: String = "{}") {
        update.apply(to: &state)
        cameraParallax = update.cameraParallax
        if update.bloom != bloom {
            bloom = update.bloom
            repackBloom()
        }
        for text in update.texts {
            recordTextDelta(textPipeline.relayoutWithDelta(text))
            for (name, value) in WPEParityTextFields.seed(text) {
                state.setScriptField(name, of: text.id, to: value, invalidating: .textLayout)
            }
        }
        script?.applyUserProperties(changedJSON: changedJSON, mergedJSON: mergedJSON, state: &state)
    }

    /// Runs `script`'s init against the loaded state; its events and update then run inside every frame.
    func attachScript(_ script: WPEParitySceneScript) {
        self.script = script
        script.engine.materialFunctionHandler = scriptMaterialFunction
        script.start(state: &state)
    }

    /// Warm leaf images use the common post-update removal path. Other class destructors and dependent
    /// owners need their original resource contract before the product admits them.
    var scriptLayerRemovalAdmission: (String) -> Bool {
        // The engine continues through renderer replacement. Capture immutable loaded-class metadata,
        // without keeping the old renderer/Metal owners alive or consulting a dead weak renderer.
        let objects = plan.scene.scene.objects
        let parents = plan.document.objectParentByID
        let videoIDs = objects.filter { videos.hasOwner($0.id) }.map(\.id)
        return { id in
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
        if let active {
            selected = selected.applyingObject(world: layers.world(active), objectID: active, document: plan.document,
                                               state: state, generalZoom: generalZoom)
        } else {
            cameraPose = cameraPaths.advance(dt: dt)
            if let pose = cameraPose {
                selected = selected.posed(pose, generalZoom: generalZoom)
            }
        }
        if camera != selected || activeCameraID != active {
            layersMoved = true
        }
        camera = selected
        activeCameraID = active
    }

    private func applyLayerFields() {
        guard seenLayerFields != state.scriptFieldsGeneration else { return }
        if layers.applyFields(state: state) {
            layersMoved = true
        }
        seenLayerFields = state.scriptFieldsGeneration
    }

    /// Bloom strength and threshold scripts wrote, rebuilt after the tick (14017fa70.c:478-481).
    private func applyScriptBloom() {
        guard state.generation(.bloom) != seenScriptBloom else { return }
        seenScriptBloom = state.generation(.bloom)
        var settings = bloom
        if case let .vector(strength)? = state.scriptField("bloomstrength", of: "") {
            settings.strength = strength.x
        }
        if case let .vector(threshold)? = state.scriptField("bloomthreshold", of: "") {
            settings.threshold = threshold.x
        }
        guard settings != bloom else { return }
        bloom = settings
        repackBloom()
    }

    /// Scene colour terms are consumed after the script tick, before this frame's lighting constants are packed.
    private func applyScriptLighting() {
        guard seenScriptLighting != state.generation(.lighting)
            || seenLightTransforms != state.transformGeneration || seenLightVisibility != state.visibilityGeneration
            || layers.hasAttachments else { return }
        lights = WPEParityUniformLights(document: plan.document, transforms: layers, state: state)
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
        }
        defaults.merge(videos.scriptFieldDefaults) { _, actual in actual }
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

    /// The cursor pass and the queued media events of the frame, before the animations (14017fa70.c:473-476).
    private func runScriptEvents(_ script: WPEParitySceneScript, camera: WPEParityCamera, cursor: SIMD2<Float>,
                                 buttonDown: Bool, timeOfDay: Float) {
        let world = cursorWorld(camera: camera)
        script.updateCursorTargets(state: state, quad: { cursorQuad($0, camera: camera) })
        script.cursor(at: cursor, world: world, leftDown: buttonDown, timeOfDay: timeOfDay, state: &state)
        script.dispatchMedia(state: &state)
    }

    /// Native viewport-depth .5 unprojection; only an orthographic scene drops the returned Z.
    private func cursorWorld(camera: WPEParityCamera) -> SIMD3<Float> {
        camera.cursorWorld(normalizedPointer: pointer.position)
    }

    /// A layer's mesh corners in client pixels, y down, with its frame's parallax (140189e10.c:124-156).
    func cursorQuad(_ id: String,
                    camera: WPEParityCamera) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? {
        guard let size = layers.layers[id]?.size, size.x > 0, size.y > 0 else { return nil }
        var placed = layers
        placed.camera = camera
        let matrix = placed.projection(id) * placed.view(id, parallax: parallax.smoothed) * placed.model(id)
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

    private func recordTextDelta(_ delta: WPEParityTextRelayoutDelta) {
        for change in delta.changes {
            relaidTexts.insert(change.current.object.id)
            textsNeedFrameRebuild = textsNeedFrameRebuild || change.requiresFrameRebuild
        }
    }

    /// The native text dirty hook is consumed once; unchanged frames perform no layout or atlas upload.
    private func applyScriptText() {
        let changed = state.generation(.textLayout) != seenScriptText
        let effectsChanged = state.effectVisibilityGeneration != seenEffects
        guard changed || effectsChanged else { return }
        for current in textPipeline.texts.values {
            var object = current.object
            if changed {
                object = WPEParityTextFields.applying(to: object, state: state)
            }
            let effects = state.effects.indices.count {
                state.effects[$0].objectID == object.id && state.effectVisibility[$0]
            }
            recordTextDelta(textPipeline.relayoutWithDelta(object, effectCount: effects))
        }
        seenScriptText = state.generation(.textLayout)
    }

    /// Re-plans only changed text geometry. Every shared atlas reader takes its new immutable texture version.
    private func replanRelaidTexts() throws {
        guard !relaidTexts.isEmpty else { return }
        let pipeline = textPipeline
        guard planner.updateTexts(relaidTexts.compactMap { pipeline.texts[$0] }, atlases: pipeline.atlases) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        pipeline.atlases = planner.textAtlases.atlases
        for id in relaidTexts {
            guard let text = pipeline.texts[id] else { continue }
            layers.setSize(id, size: SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))
        }
        layersMoved = true
        let current = graphs.layout
        let planned = try plan.layout(effects: state, texts: pipeline.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let kept = current.draws.filter { index, _ in
            guard case let .scene(draw)? = current.frames[0].draws[index] else { return true }
            return !relaidTexts.contains(draw.objectID)
        }
        let reuse = Layout(effects: current.effects, frames: current.frames, draws: kept,
                           skipped: current.skipped, fade: current.fade)
        var layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                         planner: &planner, encoder: drawEncoder,
                                         requiredPresentationPass: plan.requiredPresentationPass, reusing: reuse)
        var rebound = layout.draws
        for index in rebound.keys {
            planner.refreshAtlasBindings(&rebound[index]!, operation: index)
        }
        layout = Layout(effects: layout.effects, frames: layout.frames, draws: rebound,
                        skipped: layout.skipped, fade: layout.fade)
        let readinessChanged = Set(layout.draws.keys) != Set(current.draws.keys)
        if textsNeedFrameRebuild || readinessChanged || layout.effects != current.effects {
            try installGraphs(layout, cachePrevious: false)
        } else {
            graphs = Graphs(layout: layout, hidden: graphs.hidden, executors: graphs.executors,
                            operations: graphs.operations, particleDraws: graphs.particleDraws,
                            particleSnapshotSkips: graphs.particleSnapshotSkips)
            retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
            previousGraphs = nil
        }
        packedConstants.removeAll()
        fadeConstants.removeAll()
        relaidTexts.removeAll()
        textsNeedFrameRebuild = false
        repackBloom()
    }

    /// Advances the clock by `elapsed` seconds and the engine inputs by one frame, then commits the frame.
    /// `paused` ramps scene time down to a hold, and back up once it is false again.
    func encodeFrame(elapsed: Double, paused: Bool = false,
                     input: WPEParityFrameInput = WPEParityFrameInput()) throws -> WPEParityGraphExecutor.Submission {
        clock.advance(elapsed: elapsed, ratePercent: 100, paused: paused)
        let time = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: input.date)
        let daytime = WPEParityClock.daytime(hour: time.hour ?? 0, minute: time.minute ?? 0,
                                             second: time.second ?? 0, millisecond: (time.nanosecond ?? 0) / 1_000_000)
        // Scene time, so a paused clock holds the pose.
        for id in puppets.keys {
            puppets[id]?.advance(dt: Double(clock.frametime))
        }
        pointer.advance(cursor: input.cursor, screen: screen, buttonDown: input.buttonDown)
        let scriptCursor = input.cursor * logicalSize / SIMD2(Float(backbuffer.width), Float(backbuffer.height))
        applyTransforms()
        applyLayerFields()
        selectCamera(dt: clock.frametime)
        let fadeAlpha = cameraPaths.fadeAlpha
        let camera = pathCamera.shaken(time: clock.timeUniform)
        particles.beginFrame()
        _ = particles.scene.applyScriptInstanceFields(state: state)
        particles.scene.advance(dt: clock.frametime, frames: Self.particleFrames(
            particleObjects, state: state, layers: layers, camera: camera, time: clock.timeUniform,
            cursor: pointer.position, timeOfDay: daytime
        ))
        // 1401891a0.c:288: the smoothed parallax only moves while camera parallax is on.
        if cameraParallax.enabled {
            parallax.advance(pointer: pointer.position, mouseInfluence: Float(cameraParallax.mouseInfluence),
                             delay: Float(cameraParallax.delay), eye: SIMD2(camera.eye.x, camera.eye.y),
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
            runScriptEvents(script, camera: camera, cursor: scriptCursor, buttonDown: input.buttonDown, timeOfDay: daytime)
        }
        consumeMediaInputs()
        // R24 Q1: animations run after the object update and the camera, and render reads their values.
        animations.advance(dt: clock.frametime, state: &state)
        if let script {
            for event in animations.firedEvents {
                script.engine.dispatch(.animationEvent, payloadJSON: event.name, target: event.objectID, state: &state)
            }
            // 140171440.c:888-896: the tick after the animations, so update sees this frame's animated values.
            script.tick(dt: clock.frametime, cursor: scriptCursor, world: cursorWorld(camera: camera),
                        leftDown: input.buttonDown, timeOfDay: daytime, state: &state)
        }
        videos.applyScriptFields(state: &state)
        applyTransforms()
        applyLayerFields()
        applyScriptBloom()
        applyScriptLighting()
        uniforms.lights = lights
        applyScriptText()
        try replanRelaidTexts()
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
        return try executor.encodeFrame(on: queue, textures: targets.merging(images) { $1 },
                                        prepare: { commandBuffer in
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
                                                    if let provided = try plan.makeParticleDraw(batch, frame: uniforms, camera: camera, variant: variant,
                                                                                                textures: textures, arena: arena, textureSlots: &textureSlots,
                                                                                                renderVars: &renderVars, particles: &particles, layers: live,
                                                                                                mediaTexture: { mediaTextures?.texture(for: $0) }) {
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
                                                let provided = try plan.makeDraw(frame: uniforms, camera: camera, variant: variant, textures: textures,
                                                                                 textureSlots: &textureSlots, puppets: puppets, layers: live,
                                                                                 constants: fade ? fadeConstants : postConstants[operation] ?? materialConstants(operation, plan),
                                                                                 layerColor: color == plan.layerColor?.loaded ? nil : color,
                                                                                 renderVar0: plan.clipMaskInverted == nil ? nil : renderVars.rv0,
                                                                                 mediaTexture: { mediaTextures?.texture(for: $0) })
                                                try encode(provided, operation: operation)
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
        if state.membershipGeneration != seenMembership {
            let planned = try plan.layout(effects: state, texts: planner.texts,
                                          mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
            let layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                             planner: &planner, encoder: drawEncoder,
                                             requiredPresentationPass: plan.requiredPresentationPass,
                                             reusing: graphs.layout)
            // Removed owners cannot return through the visibility cache. Existing command buffers retain
            // their submitted resource versions; this drops the renderer's obsolete draw/graph references.
            try installGraphs(layout, cachePrevious: false)
            packedConstants.removeAll()
            fadeConstants.removeAll()
            seenMembership = state.membershipGeneration
            repackBloom()
        }
        guard state.visibilityGeneration != seenVisibility || state.effectVisibilityGeneration != seenEffects else {
            return
        }
        let hidden = state.objects.indices.map { !state.isVisible(at: $0) }
        let effects = state.effectVisibility
        if hidden != graphs.hidden || effects != graphs.layout.effects {
            if let previous = previousGraphs, previous.hidden == hidden, previous.layout.effects == effects,
               previous.executors.allSatisfy({ executor in
                   executor.graph.resources.values.allSatisfy { resource in
                       resource.lifetime == .imported || executor.transientTextures[resource.id] != nil
                           || targets[resource.id].map { Self.matches($0, resource: resource) } == true
                   }
               }) {
                (graphs, previousGraphs) = (previous, graphs)
                targetSamplers = Self.targetSamplers(graphs.layout, targets: targets)
            } else {
                var layout = graphs.layout
                if effects != layout.effects {
                    layout = try Self.makeLayout(plan.layout(effects: state, texts: planner.texts,
                                                             mipMappedFrameBufferRequested: mipMappedFrameBufferRequested), effects: effects,
                                                 artifacts: artifacts, planner: &planner, encoder: drawEncoder,
                                                 requiredPresentationPass: plan.requiredPresentationPass,
                                                 reusing: layout)
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

    /// Allocation and initialization form one transaction; a failed attempt leaves the previous graphs retryable.
    private func installGraphs(_ layout: Layout, cachePrevious: Bool) throws {
        var candidateTargets = targets
        let made = try Self.makeGraphs(layout: layout, state: state, device: device, encoder: drawEncoder,
                                       arena: arena, targets: &candidateTargets, resourceBindings: resourceBindings,
                                       snapshotObjects: particleSnapshotObjects)
        let added = candidateTargets.filter { id, texture in
            targets[id].map { ObjectIdentifier($0) != ObjectIdentifier(texture) } ?? true
        }
        try Self.clear(Array(added.values), queue: queue, colors: Self.clearColors(layout, targets: added))
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        previousGraphs = cachePrevious ? graphs : nil
        graphs = made
        // Named pool history outlives effect/visibility toggles. IDs are bounded by this loaded document;
        // resizing replaces a value at its existing ID, and Metal retains the submitted texture version.
        targets = candidateTargets
        targetSamplers = Self.targetSamplers(layout, targets: targets)
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
        guard bloom != plan.post.bloomSettings else { return }
        var config = plan.post
        config.bloomSettings = bloom
        let layout = graphs.layout
        let operations = layout.frames[0].draws.compactMap { index, draw -> Int? in
            if case .post = draw {
                index
            } else {
                nil
            }
        }.sorted()
        let rebuilt = WPEParityPostProcessBuilder.build(config).draws
        guard operations.count == rebuilt.count else { return }
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
                                   requiredPresentationPass: String?, reusing previous: Layout?) throws -> Layout {
        planner.use(planned)
        let names = drawNames(planned.frames[0])
        var earlier: [DrawName: Int] = [:]
        for (index, name) in previous.map({ drawNames($0.frames[0]) }) ?? [:] {
            earlier[name] = index
        }
        var draws: [Int: WPEParityFrameDrawPlan] = [:]
        var skipped = planned.skipped
        for (index, program) in planned.programs.sorted(by: { $0.key < $1.key }) {
            if let previous, previous.frames.count == planned.frames.count,
               let match = names[index].flatMap({ earlier[$0] }), let plan = previous.draws[match],
               planned.frames.indices.allSatisfy({
                   planned.frames[$0].draws[index] == previous.frames[$0].draws[match]
                       && Self.resourcesMatch(planned.frames[$0], previous.frames[$0], draw: index)
               }) {
                draws[index] = plan
                continue
            }
            let artifact = artifacts[program.hlsl] ?? .failure(.noShader("\(program.shader): not compiled at load"))
            do throws(WPEParityFrameSkip) {
                let draw = try planner.makePlan(index, artifact: artifact.get())
                try Self.prepare(draw, encoder: encoder)
                draws[index] = draw
            } catch {
                skipped[index] = error
            }
        }
        if let requiredPresentationPass {
            let terminalIndex = planned.frames[0].draws.first { _, draw in
                guard case let .post(post) = draw else { return false }
                return post.shader == requiredPresentationPass
            }?.key
            guard let index = terminalIndex, draws[index] != nil, let program = planned.programs[index] else {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: requiredPresentationPass, reason: terminalIndex.flatMap { skipped[$0] } ?? .noMaterial
                )
            }
            let expectedShader = requiredPresentationPass == "combine_hdr" ? "combine_hdr" : "passthroughsrgb"
            guard program.shader == expectedShader,
                  !program.combos.contains(where: { ($0.name == "LINEAR" || $0.name == "DISPLAYHDR") && $0.value == "1" }) else {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: requiredPresentationPass,
                    reason: .program("Unsupported HDR presentation shader or transfer combo: \(program.shader)")
                )
            }
        }
        let fade = planned.frames[0].draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "fade"
            } else {
                false
            }
        }?.key
        return Layout(effects: effects, frames: planned.frames, draws: draws, skipped: skipped, fade: fade)
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

    private static func resourcesMatch(_ current: WPEParityFrame, _ previous: WPEParityFrame, draw: Int) -> Bool {
        guard let description = current.draws[draw] else { return false }
        let ids: Set<WPEResourceID> = switch description {
        case let .scene(scene): Set(scene.reads + [scene.target])
        case let .post(post): Set(post.reads)
        }
        for id in ids {
            guard current.resources.first(where: { $0.id == id }) == previous.resources.first(where: { $0.id == id }),
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
    private static func clear(_ textures: [MTLTexture], queue: MTLCommandQueue,
                              colors: [ObjectIdentifier: WPEClearColor] = [:]) throws {
        guard !textures.isEmpty else { return }
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
    }
}
#endif
