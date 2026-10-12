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
    let skipped: [Int: WPEParityFrameSkip]
    let drawCount: Int
    let backbuffer: MTLTexture
    /// Render targets the renderer allocates; layer images are not among them.
    let targets: [WPEResourceID: MTLTexture]
    private let images: [WPEResourceID: MTLTexture]
    private let videos: WPEParityVideoTextures
    private let queue: MTLCommandQueue
    private let executors: [WPEParityGraphExecutor]
    private let draws: [Int: WPEParityFrameDrawPlan]
    private let screen: WPEParityUniformScreen
    private let camera: WPEParityCamera
    private let cameraParallax: WPESceneCameraParallaxSettings
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
    private let layers: WPEParityLayerTransformSet
    /// Visible particle objects; the others are not stepped (R16 Q5).
    private let particleObjects: [String]
    /// The draws the last frame encoded, by draw operation, in encode order.
    private(set) var lastFrameDraws: [(operation: Int, draw: WPEParityDraw)] = []
    private var frameIndex = 0

    var executedDrawCount: Int {
        draws.count
    }

    /// Particle batches dropped because a frame's particle draws outgrew their arena share or the arena.
    var droppedParticleBatches: Int {
        executors.reduce(particles.dropped) { $0 + $1.droppedDraws }
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
        draws[operation]?.frameUniforms(parallax: parallax.smoothed, camera: camera.shaken(time: clock.timeUniform))
    }

    var heapBytes: Int {
        executors.reduce(0) { $0 + ($1.heap?.size ?? 0) }
    }

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
    }

    /// The fixed textures video .tex draws sample.
    var videoTextures: [MTLTexture] {
        videos.textures
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
        var skipped = plan.skipped
        var draws: [Int: WPEParityFrameDrawPlan] = [:]
        // The store shares one compile between draws with the same program.
        let artifacts = await withTaskGroup(of: (Int, Result<WPEParityShaderArtifact, WPEParityFrameSkip>).self) { group in
            for (index, program) in plan.programs {
                group.addTask {
                    do {
                        return try await (index, .success(shaders.artifact(for: program)))
                    } catch {
                        return (index, .failure(.noShader("\(program.shader): \(error)")))
                    }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        // Planned in operation order so the planner's layer images and videos come out the same every build.
        for (index, artifact) in artifacts.sorted(by: { $0.key < $1.key }) {
            do throws(WPEParityFrameSkip) {
                draws[index] = try planner.makePlan(index, artifact: artifact.get())
            } catch {
                skipped[index] = error
            }
        }

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
        let baseArenaBytes = max(1 << 16, draws.count * 16 * 1024)
        guard let arena = WPEParityFrameArena(device: device, capacity: baseArenaBytes + particleBytes) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        let encoder = WPEParityDrawEncoder(factory: factory)
        var executors: [WPEParityGraphExecutor] = []
        var targets: [WPEResourceID: MTLTexture] = [:]
        for frame in plan.frames {
            let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
            let executor = try WPEParityGraphExecutor(graph: graph, device: device, drawEncoder: encoder, arena: arena,
                                                      pixelFormats: WPEParityFrameDrawPlanner.pixelFormats)
            for id in graph.lifetimes.keys where executor.transientTextures[id] == nil && targets[id] == nil {
                guard let resource = graph.resources[id], resource.lifetime != .imported else { continue }
                targets[id] = try Self.makeTarget(resource, device: device)
            }
            executors.append(executor)
        }
        guard let backbuffer = targets[WPEParitySceneResource.backbuffer] else {
            throw WPEParityFrameRenderError.missingBackbuffer
        }
        try Self.clear(Array(targets.values) + videos.textures, queue: queue)

        self.skipped = skipped
        drawCount = plan.frames[0].operations.count {
            if case .draw = $0.kind {
                true
            } else {
                false
            }
        }
        self.backbuffer = backbuffer
        self.targets = targets
        images = planner.layerImages
        self.videos = videos
        self.queue = queue
        self.executors = executors
        self.arena = arena
        self.baseArenaBytes = baseArenaBytes
        growsParticleShare = particleArenaBytes == nil
        self.draws = draws
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        camera = planner.layers.camera
        layers = planner.layers
        cameraParallax = plan.document.general.cameraParallax
        let particleObjects = plan.scene.scene.objects.compactMap { object in
            if case .particle = object.kind, object.visible {
                object.id
            } else {
                nil
            }
        }
        self.particleObjects = particleObjects
        let prewarm = Self.particleFrames(particleObjects, layers: planner.layers, camera: planner.layers.camera,
                                          time: 0, cursor: nil)
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
            particleObjects, layers: layers, camera: camera, time: clock.timeUniform, cursor: pointer.position
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
        let variant = frameIndex % executors.count
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
        return try executors[variant].encodeFrame(on: queue, textures: targets.merging(images) { $1 },
                                                  prepare: videos.encode) { operation, textures, arena in
            guard let plan = draws[operation] else { return [] }
            let provided: [WPEParityDraw]
            if case .particles = plan.geometry {
                provided = try plan.makeParticleDraws(frame: uniforms, camera: camera, variant: variant,
                                                      textures: textures, arena: arena, textureSlots: &textureSlots,
                                                      renderVars: &renderVars, particles: &particles)
            } else {
                renderVars.rv0 = plan.renderVarWrites.rv0 ?? renderVars.rv0
                renderVars.rv1 = plan.renderVarWrites.rv1 ?? renderVars.rv1
                provided = try [plan.makeDraw(frame: uniforms, camera: camera, variant: variant, textures: textures,
                                              textureSlots: &textureSlots, puppets: puppets)]
            }
            lastFrameDraws += provided.map { (operation, $0) }
            return provided
        }
    }

    /// One context per visible particle object: scene time, cursor in [0, 1]² y down, the scene camera's
    /// view-projection and the object's world matrix.
    private static func particleFrames(_ ids: [String], layers: WPEParityLayerTransformSet, camera: WPEParityCamera,
                                       time: Float, cursor: SIMD2<Float>?) -> [String: WPEParityParticleFrameContext] {
        let viewProjection = camera.projection * camera.view
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, WPEParityParticleFrameContext(time: time, cursor: cursor, viewProjection: viewProjection,
                                               objectMatrix: layers.world(id)))
        })
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
