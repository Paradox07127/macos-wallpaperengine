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
    private var clock = WPEParityClock()
    private var pointer = WPEParityUniformPointer()
    private var parallax = WPEParityUniformParallax()
    private var audio = WPEParityAudioSpectrum()
    /// Last TEXS rotation and translation per slot, which draws without a sprite frame upload again.
    private var textureSlots: [String: WPECBufferValue] = [:]
    private var frameIndex = 0

    var executedDrawCount: Int {
        draws.count
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
        draws[operation]?.frameUniforms(parallax: parallax.smoothed)
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

    init(plan: WPEParityFramePlan, device: MTLDevice, queue: MTLCommandQueue,
         shaders: WPEParityFrameShaderSource) async throws {
        let factory = WPEParityPipelineFactory(device: device)
        var planner = WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan)
        var skipped = plan.skipped
        var draws: [Int: WPEParityFrameDrawPlan] = [:]
        for (index, program) in plan.programs.sorted(by: { $0.key < $1.key }) {
            do {
                let artifact = try await shaders.artifact(for: program)
                draws[index] = try planner.makePlan(index, artifact: artifact)
            } catch let skip as WPEParityFrameSkip {
                skipped[index] = skip
            } catch {
                skipped[index] = .noShader("\(program.shader): \(error)")
            }
        }

        try planner.fillImportedImages()
        let videos = try await WPEParityVideoTextures(streams: planner.videos,
                                                      workshopID: plan.scene.assets.roots[0].lastPathComponent,
                                                      device: device, queue: queue)

        // Each draw needs at most two argument tables and a few cbuffers, all 256-byte aligned.
        guard let arena = WPEParityFrameArena(device: device, capacity: max(1 << 16, draws.count * 16 * 1024)) else {
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
        self.draws = draws
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        camera = planner.layers.camera
        cameraParallax = plan.document.general.cameraParallax
    }

    /// Advances the clock by `elapsed` seconds and the engine inputs by one frame, then commits the frame.
    func encodeFrame(elapsed: Double,
                     input: WPEParityFrameInput = WPEParityFrameInput()) throws -> WPEParityGraphExecutor.Submission {
        clock.advance(elapsed: elapsed, ratePercent: 100, paused: false)
        pointer.advance(cursor: input.cursor, screen: screen, buttonDown: input.buttonDown)
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
        defer { videos.finishFrame() }
        return try executors[variant].encodeFrame(on: queue, textures: targets.merging(images) { $1 },
                                                  prepare: videos.encode) { operation, textures in
            try draws[operation]?.makeDraw(frame: uniforms, variant: variant, textures: textures,
                                           textureSlots: &textureSlots)
        }
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
