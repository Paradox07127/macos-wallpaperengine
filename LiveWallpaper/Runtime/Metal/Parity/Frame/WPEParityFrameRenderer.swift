#if !LITE_BUILD
import Foundation
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
    /// Client-area pixels, y down.
    var cursor: SIMD2<Float> = .zero
    var buttonDown = false
    /// 64 linear bins per channel; nil is silence.
    var audio: (left: [Float], right: [Float])?
    /// Local time for g_Daytime.
    var date = Date()
}

enum WPEParityFrameRenderError: Error {
    case missingBackbuffer
    case arenaUnavailable
    case allocationFailed(WPEResourceID)
    case encoderUnavailable
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
        let operations: [[Int]]
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
    private var graphs: Graphs
    /// The graphs before the last visibility change, kept so toggling back does not recompile.
    private var previousGraphs: Graphs?
    /// Dropped draws of graphs no longer kept.
    private var retiredDrops = 0
    private let plan: WPEParityFramePlan
    /// Draws of later effect sets plan here, reusing its images and pipelines.
    private var planner: WPEParityFrameDrawPlanner
    /// Every program the plan can draw with, compiled at load.
    private let artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>]
    private var bloom: WPEParityBloomSettings
    /// Post-process draw constants for `bloom`, by draw operation, where they differ from the planned ones.
    private var postConstants: [Int: [WPEHLSLStage: [String: WPECBufferValue]]] = [:]
    private let device: MTLDevice
    private let drawEncoder: WPEParityDrawEncoder
    private let images: [WPEResourceID: MTLTexture]
    private let videos: WPEParityVideoTextures
    private let queue: MTLCommandQueue
    private let screen: WPEParityUniformScreen
    private let camera: WPEParityCamera
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

    /// The frames of the effects the state shows; draw operation indices refer to them.
    var frames: [WPEParityFrame] {
        graphs.layout.frames
    }

    var skipped: [Int: WPEParityFrameSkip] {
        graphs.layout.skipped
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
        draws[operation]?.frameUniforms(parallax: parallax.smoothed, camera: camera.shaken(time: clock.timeUniform),
                                        layers: layersMoved ? layers : nil)
    }

    var heapBytes: Int {
        graphs.executors.reduce(0) { $0 + ($1.heap?.size ?? 0) }
    }

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
    }

    /// The fixed textures video .tex draws sample.
    var videoTextures: [MTLTexture] {
        videos.textures
    }

    /// The text layers' glyph atlases as last uploaded.
    var textAtlases: [String: WPEParityGlyphAtlasInstance] {
        planner.textAtlases.atlases
    }

    /// `particleArenaBytes` fixes each frame's particle share of the arena. By default the share starts with every
    /// particle draw at full capacity, an event group as one instance, and doubles after each frame that drops
    /// particle batches, up to `maxParticleShare`. `workshopID` keys the video disk cache; nil uses the scene
    /// directory's name.
    init(plan: WPEParityFramePlan, device: MTLDevice, queue: MTLCommandQueue, shaders: WPEParityFrameShaderSource,
         particleSeed: UInt32 = WPEParityParticleScene.productSeed(), particleArenaBytes: Int? = nil,
         workshopID: String? = nil) async throws {
        let factory = WPEParityPipelineFactory(device: device)
        var planner = WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan)
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
        let layout = Self.makeLayout(plan.layout, effects: plan.state.effectVisibility, artifacts: artifacts,
                                     planner: &planner, reusing: nil)
        let probes = try plan.probeFrames()
        for probe in probes {
            for (index, program) in probe.programs {
                guard case let .success(artifact)? = artifacts[program.hlsl] else { continue }
                planner.prewarmPipeline(probe.frame, index, program: program, artifact: artifact)
            }
        }
        let draws = layout.draws

        try planner.fillImportedImages()
        let videos = try await WPEParityVideoTextures(streams: planner.videos,
                                                      workshopID: workshopID
                                                          ?? plan.scene.assets.roots[0].lastPathComponent,
                                                      device: device, queue: queue)

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
        let encoder = WPEParityDrawEncoder(factory: factory)
        var targets: [WPEResourceID: MTLTexture] = [:]
        let graphs = try Self.makeGraphs(layout: layout, state: plan.state, device: device, encoder: encoder,
                                         arena: arena, targets: &targets)
        guard let backbuffer = targets[WPEParitySceneResource.backbuffer] else {
            throw WPEParityFrameRenderError.missingBackbuffer
        }
        try Self.clear(Array(targets.values) + videos.textures, queue: queue)

        self.graphs = graphs
        self.plan = plan
        self.planner = planner
        self.artifacts = artifacts
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
        animations = WPEParitySceneAnimations(document: plan.document, state: plan.state,
                                              constantComponents: constantComponents)
        self.backbuffer = backbuffer
        self.targets = targets
        images = planner.layerImages
        self.videos = videos
        self.queue = queue
        self.arena = arena
        self.baseArenaBytes = baseArenaBytes
        growsParticleShare = particleArenaBytes == nil
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        camera = planner.layers.camera
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
        for object in plan.scene.scene.objects where object.puppet?.skinned == true {
            guard let model = plan.scene.puppetModels[object.id] else { continue }
            let layers = plan.document.imageObjects.first { $0.id == object.id }?.animationLayers ?? []
            puppets[object.id] = WPEParityPuppetAnimator(model: model, layers: layers)
        }
    }

    /// Picks up `previous`'s scene where it stopped, for the same document planned at another size.
    func continueScene(from previous: WPEParityFrameRenderer) {
        clock = previous.clock
        pointer = previous.pointer
        parallax = previous.parallax
        audio = previous.audio
        textureSlots = previous.textureSlots
        renderVars = previous.renderVars
        puppets = previous.puppets
        particles = previous.particles
        arena.capacity = baseArenaBytes + particles.budget
        frameIndex = previous.frameIndex
        state = previous.state
        animations = previous.animations
        cameraParallax = previous.cameraParallax
        // The next frame takes the transforms, visibility and effects over from the copied state.
        seenTransforms = previous.layersMoved ? -1 : 0
        seenVisibility = -1
        seenEffects = -1
        bloom = previous.bloom
        repackBloom()
    }

    /// Writes a user-property change between frames; the next frame reads it like any state write.
    func applyUserProperties(_ update: WPEParityUserPropertyUpdate) {
        update.apply(to: &state)
        cameraParallax = update.cameraParallax
        if update.bloom != bloom {
            bloom = update.bloom
            repackBloom()
        }
    }

    /// Advances the clock by `elapsed` seconds and the engine inputs by one frame, then commits the frame.
    /// `paused` ramps scene time down to a hold, and back up once it is false again.
    func encodeFrame(elapsed: Double, paused: Bool = false,
                     input: WPEParityFrameInput = WPEParityFrameInput()) throws -> WPEParityGraphExecutor.Submission {
        let sceneTime = clock.time
        clock.advance(elapsed: elapsed, ratePercent: 100, paused: paused)
        // Scene time, so a paused clock holds the pose.
        for id in puppets.keys {
            puppets[id]?.advance(dt: clock.time - sceneTime)
        }
        pointer.advance(cursor: input.cursor, screen: screen, buttonDown: input.buttonDown)
        let camera = camera.shaken(time: clock.timeUniform)
        particles.beginFrame()
        particles.scene.advance(dt: clock.frametime, frames: Self.particleFrames(
            particleObjects, state: state, layers: layers, camera: camera, time: clock.timeUniform,
            cursor: pointer.position
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
        let time = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: input.date)
        let daytime = WPEParityClock.daytime(hour: time.hour ?? 0, minute: time.minute ?? 0,
                                             second: time.second ?? 0, millisecond: (time.nanosecond ?? 0) / 1_000_000)
        let uniforms = WPEParityUniformFrame(clock: clock, daytime: daytime, screen: screen, pointer: pointer,
                                             parallax: parallax, eyePosition: camera.eyePosition, view: camera.view,
                                             audio: audio)
        // R24 Q1: animations run after the object update and the camera, and render reads their values.
        animations.advance(dt: clock.frametime, state: &state)
        applyTransforms()
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
        return try graphs.executors[variant].encodeFrame(on: queue, textures: targets.merging(images) { $1 },
                                                         prepare: videos.encode) { step, textures, arena in
            let operation = graphs.operations[variant][step]
            guard let plan = draws[operation] else { return [] }
            let provided: [WPEParityDraw]
            if case .particles = plan.geometry {
                provided = try plan.makeParticleDraws(frame: uniforms, camera: camera, variant: variant,
                                                      textures: textures, arena: arena, textureSlots: &textureSlots,
                                                      renderVars: &renderVars, particles: &particles, layers: live)
            } else {
                renderVars.rv0 = plan.renderVarWrites.rv0 ?? renderVars.rv0
                renderVars.rv1 = plan.renderVarWrites.rv1 ?? renderVars.rv1
                // A colour equal to the loaded one is already in the planned constants.
                let color = plan.layerColor.map { state.layerColor(at: $0.object) }
                provided = try [plan.makeDraw(frame: uniforms, camera: camera, variant: variant, textures: textures,
                                              textureSlots: &textureSlots, puppets: puppets, layers: live,
                                              constants: postConstants[operation] ?? materialConstants(operation, plan),
                                              layerColor: color == plan.layerColor?.loaded ? nil : color)]
            }
            lastFrameDraws += provided.map { (operation, $0) }
            return provided
        }
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

    /// Moves the layer worlds to the state's transforms when any changed.
    private func applyTransforms() {
        guard state.transformGeneration != seenTransforms else { return }
        seenTransforms = state.transformGeneration
        for (index, id) in state.ids.enumerated() {
            let object = state.objects[index]
            layers.setTransform(id, origin: object.origin, angles: object.angles, scale: object.scale)
        }
        layers.refreshWorlds()
        layersMoved = true
    }

    /// Encodes the frame with the effects the state shows and without the operations of hidden objects. A change
    /// recompiles the graphs, and an effect change re-plans the draws it alters, except when it returns to the
    /// previous set.
    private func selectGraphs() throws {
        guard state.visibilityGeneration != seenVisibility || state.effectVisibilityGeneration != seenEffects else {
            return
        }
        seenVisibility = state.visibilityGeneration
        seenEffects = state.effectVisibilityGeneration
        let hidden = state.objects.indices.map { !state.isVisible(at: $0) }
        let effects = state.effectVisibility
        guard hidden != graphs.hidden || effects != graphs.layout.effects else { return }
        // Packs are keyed by operation, and a new layout renumbers them.
        if effects != graphs.layout.effects {
            packedConstants.removeAll()
        }
        defer { repackBloom() }
        if let previous = previousGraphs, previous.hidden == hidden, previous.layout.effects == effects {
            (graphs, previousGraphs) = (previous, graphs)
            return
        }
        var layout = graphs.layout
        if let previous = previousGraphs?.layout, previous.effects == effects {
            layout = previous
        } else if effects != layout.effects {
            layout = try Self.makeLayout(plan.layout(effects: state), effects: effects, artifacts: artifacts,
                                         planner: &planner, reusing: layout)
        }
        let allocated = Set(targets.keys)
        let made = try Self.makeGraphs(layout: layout, state: state, device: device, encoder: drawEncoder,
                                       arena: arena, targets: &targets)
        let added = targets.filter { !allocated.contains($0.key) }.map(\.value)
        if !added.isEmpty {
            try Self.clear(added, queue: queue)
        }
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        (graphs, previousGraphs) = (made, graphs)
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
                                   planner: inout WPEParityFrameDrawPlanner, reusing previous: Layout?) -> Layout {
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
               planned.frames.indices.allSatisfy({ planned.frames[$0].draws[index] == previous.frames[$0].draws[match] }) {
                draws[index] = plan
                continue
            }
            let artifact = artifacts[program.hlsl] ?? .failure(.noShader("\(program.shader): not compiled at load"))
            do throws(WPEParityFrameSkip) {
                draws[index] = try planner.makePlan(index, artifact: artifact.get())
            } catch {
                skipped[index] = error
            }
        }
        return Layout(effects: effects, frames: planned.frames, draws: draws, skipped: skipped)
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
                                   targets: inout [WPEResourceID: MTLTexture]) throws -> Graphs {
        var executors: [WPEParityGraphExecutor] = []
        var operations: [[Int]] = []
        for frame in layout.frames {
            let kept = frame.operations.indices.filter { index in
                frame.owners[index].flatMap(state.index(of:)).map(state.isVisible(at:)) ?? true
            }
            let graph = try WPERenderGraphCompiler.compile(resources: frame.resources,
                                                           operations: kept.map { frame.operations[$0] })
            let executor = try WPEParityGraphExecutor(graph: graph, device: device, drawEncoder: encoder, arena: arena,
                                                      pixelFormats: WPEParityFrameDrawPlanner.pixelFormats)
            for id in graph.lifetimes.keys where executor.transientTextures[id] == nil && targets[id] == nil {
                guard let resource = graph.resources[id], resource.lifetime != .imported else { continue }
                targets[id] = try makeTarget(resource, device: device)
            }
            executors.append(executor)
            operations.append(kept)
        }
        return Graphs(layout: layout, hidden: state.objects.indices.map { !state.isVisible(at: $0) },
                      executors: executors, operations: operations)
    }

    /// One context per visible particle object: scene time, cursor in [0, 1]² y down, the scene camera's
    /// view-projection and the object's world matrix.
    private static func particleFrames(_ objects: [(id: String, index: Int?)], state: WPEParitySceneState,
                                       layers: WPEParityLayerTransformSet, camera: WPEParityCamera, time: Float,
                                       cursor: SIMD2<Float>?) -> [String: WPEParityParticleFrameContext] {
        let viewProjection = camera.projection * camera.view
        var frames: [String: WPEParityParticleFrameContext] = [:]
        for (id, index) in objects where index.map(state.isVisible(at:)) ?? true {
            frames[id] = WPEParityParticleFrameContext(time: time, cursor: cursor, viewProjection: viewProjection,
                                                       objectMatrix: layers.world(id))
        }
        return frames
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

    /// Pooled targets can be read before their first write; start them from zero instead of stale memory.
    private static func clear(_ textures: [MTLTexture], queue: MTLCommandQueue) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw WPEParityFrameRenderError.encoderUnavailable }
        for texture in textures {
            let pass = MTLRenderPassDescriptor()
            if texture.pixelFormat == .depth32Float {
                pass.depthAttachment.texture = texture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
            } else {
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            encoder.endEncoding()
        }
        commandBuffer.commit()
    }
}
#endif
