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

enum WPEParityFrameRenderError: Error {
    case missingBackbuffer
    case arenaUnavailable
    case allocationFailed(WPEResourceID)
    case encoderUnavailable
}

/// Renders a plan's frames on Metal: one compiled graph per frame variant, renderer-owned dedicated and pooled
/// targets, executor-owned heap and memoryless transients. Skipped draws are removed from the graph, not replaced.
final class WPEParityFrameRenderer {
    private struct Variant {
        let executor: WPEParityGraphExecutor
        /// Compiled operation index → plan operation index.
        let operations: [Int]
    }

    let skipped: [Int: WPEParityFrameSkip]
    let drawCount: Int
    let backbuffer: MTLTexture
    /// Render targets the renderer allocates; layer images are not among them.
    let targets: [WPEResourceID: MTLTexture]
    private let images: [WPEResourceID: MTLTexture]
    private let queue: MTLCommandQueue
    private let variants: [Variant]
    private let draws: [Int: WPEParityFrameDrawPlan]
    private let screen: WPEParityUniformScreen
    private let view: simd_float4x4
    private let eyePosition: SIMD3<Float>
    private var clock = WPEParityClock()
    private var frameIndex = 0

    var executedDrawCount: Int {
        variants[0].executor.graph.operations.count {
            if case .draw = $0.kind {
                true
            } else {
                false
            }
        }
    }

    var heapBytes: Int {
        variants.reduce(0) { $0 + ($1.executor.heap?.size ?? 0) }
    }

    var dedicatedTextureBytes: Int {
        targets.values.reduce(0) { $0 + $1.allocatedSize }
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

        let first = plan.frames[0]
        let kept = first.operations.indices.filter { index in
            guard case .draw = first.operations[index].kind else { return true }
            return draws[index] != nil
        }
        // Each draw needs at most two argument tables and a few cbuffers, all 256-byte aligned.
        guard let arena = WPEParityFrameArena(device: device, capacity: max(1 << 16, draws.count * 16 * 1024)) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        let encoder = WPEParityDrawEncoder(factory: factory)
        var variants: [Variant] = []
        var targets: [WPEResourceID: MTLTexture] = [:]
        for frame in plan.frames {
            let graph = try WPERenderGraphCompiler.compile(resources: frame.resources,
                                                           operations: kept.map { frame.operations[$0] })
            let executor = try WPEParityGraphExecutor(graph: graph, device: device, drawEncoder: encoder, arena: arena,
                                                      pixelFormats: WPEParityFrameDrawPlanner.pixelFormats)
            for id in graph.lifetimes.keys where executor.transientTextures[id] == nil && targets[id] == nil {
                guard let resource = graph.resources[id], resource.lifetime != .imported else { continue }
                targets[id] = try Self.makeTarget(resource, device: device)
            }
            variants.append(Variant(executor: executor, operations: kept))
        }
        guard let backbuffer = targets[WPEParitySceneResource.backbuffer] else {
            throw WPEParityFrameRenderError.missingBackbuffer
        }
        try Self.clear(Array(targets.values), queue: queue)

        self.skipped = skipped
        drawCount = first.operations.count {
            if case .draw = $0.kind {
                true
            } else {
                false
            }
        }
        self.backbuffer = backbuffer
        self.targets = targets
        images = planner.layerImages
        self.queue = queue
        self.variants = variants
        self.draws = draws
        screen = WPEParityUniformScreen(clientWidth: backbuffer.width, clientHeight: backbuffer.height)
        view = planner.view
        eyePosition = planner.eyePosition
    }

    /// Advances the clock by `elapsed` seconds and commits one frame.
    func encodeFrame(elapsed: Double) throws -> WPEParityGraphExecutor.Submission {
        clock.advance(elapsed: elapsed, ratePercent: 100, paused: false)
        let uniforms = WPEParityUniformFrame(clock: clock, daytime: 0, screen: screen,
                                             pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                             eyePosition: eyePosition, view: view)
        let variant = variants[frameIndex % variants.count]
        frameIndex += 1
        return try variant.executor.encodeFrame(on: queue, textures: targets.merging(images) { $1 }) { operation, textures in
            let index = variant.operations[operation]
            guard let draw = draws[index] else { throw WPEParityFrameSkip.pipeline("operation \(index) has no draw") }
            return try draw.makeDraw(frame: uniforms, textures: textures)
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
