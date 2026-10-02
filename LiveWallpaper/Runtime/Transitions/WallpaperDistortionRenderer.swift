import LiveWallpaperCore
import Metal

enum WallpaperDistortionEffect: String, CaseIterable, Sendable {
    case ripple
    case blinds
    case crystal
    case bokeh
    case dust

    var duration: TimeInterval {
        switch self {
        case .ripple: 1.3
        case .bokeh: 1.5
        case .crystal: 1.7
        case .blinds: 1.3
        case .dust: 1.8
        }
    }

    var fragmentFunctionName: String {
        switch self {
        case .ripple: "wallpaperDistortionRipple"
        case .blinds: "wallpaperDistortionBlinds"
        case .crystal: "wallpaperDistortionCrystal"
        case .bokeh: "wallpaperDistortionBokeh"
        case .dust: "wallpaperDistortionDust"
        }
    }

    /// Once-per-transition pass whose output the frame fragment reads at texture(2); nil = none.
    var precompute: (functionName: String, pixelFormat: MTLPixelFormat)? {
        switch self {
        case .crystal: ("wallpaperDistortionCrystalCells", .rgba8Uint)
        case .ripple, .blinds, .bokeh, .dust: nil
        }
    }
}

/// Draws distortion transitions that warp both frozen frames into one opaque frame per tick.
@MainActor
final class WallpaperDistortionRenderer {
    /// Everything a transition needs per frame; built once by `prepare`.
    struct Prepared {
        let effect: WallpaperDistortionEffect
        let pixelFormat: MTLPixelFormat
        let from: MTLTexture
        let to: MTLTexture
        /// Output of the effect's precompute pass; nil when the effect has none.
        let precomputed: MTLTexture?
        let seed: Float
        let origin: SIMD2<Float>
        fileprivate let pipeline: MTLRenderPipelineState
        fileprivate let extraPass: ExtraPass?
    }

    /// Per-frame work around the effect's full-screen draw.
    fileprivate enum ExtraPass {
        case bokeh(Bokeh)
        /// Instanced quads blended over the full-screen draw; both read `particles` at buffer(1) and `grid` at buffer(2).
        case particles(pipeline: MTLRenderPipelineState, particles: MTLBuffer, grid: SIMD2<UInt32>)
    }

    /// Half-resolution mix then blur before the composite, which reads `blurred` at texture(2) and `discs` at buffer(1).
    fileprivate struct Bokeh {
        let mixPipeline: MTLRenderPipelineState
        let blurPipeline: MTLRenderPipelineState
        let mixed: MTLTexture
        let blurred: MTLTexture
        /// (centre uv with y up, radius in screen heights at full blur, unused) per highlight.
        let discs: [SIMD4<Float>]
    }

    /// nil when the app has no Metal device or its shader library lacks the distortion functions.
    static let shared: WallpaperDistortionRenderer? = MTLCreateSystemDefaultDevice().flatMap { WallpaperDistortionRenderer(device: $0) }

    /// Dust blocks per screen height; one particle per block.
    private static let dustRows = 64
    private static let vertexFunctionName = "wallpaperDistortionVertex"

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var failedPipelines: Set<String> = []

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              library.functionNames.contains(Self.vertexFunctionName) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
    }

    /// `from` and `to` must share size and `pixelFormat` (`.bgra8Unorm`, `.rgba8Unorm_srgb` or `.rgba16Float`), top-left
    /// origin; frames come out in that same format. `origin` is in uv with y up. nil means fall back to a crossfade.
    func prepare(
        _ effect: WallpaperDistortionEffect,
        from: MTLTexture,
        to: MTLTexture,
        seed: Float,
        origin: SIMD2<Float>,
        pixelFormat: MTLPixelFormat
    ) -> Prepared? {
        guard let pipeline = pipeline(fragment: effect.fragmentFunctionName, pixelFormat: pixelFormat) else { return nil }
        var precomputed: MTLTexture?
        if let precompute = effect.precompute {
            precomputed = runPrecompute(precompute, width: from.width, height: from.height, seed: seed, origin: origin)
            guard precomputed != nil else { return nil }
        }
        var extraPass: ExtraPass?
        switch effect {
        case .bokeh:
            let width = (from.width + 1) / 2
            let height = (from.height + 1) / 2
            guard let mixPipeline = self.pipeline(fragment: "wallpaperDistortionBokehMix", pixelFormat: pixelFormat),
                  let blurPipeline = self.pipeline(fragment: "wallpaperDistortionBokehBlur", pixelFormat: pixelFormat),
                  let mixed = makeIntermediate(width: width, height: height, pixelFormat: pixelFormat),
                  let blurred = makeIntermediate(width: width, height: height, pixelFormat: pixelFormat) else {
                return nil
            }
            extraPass = .bokeh(Bokeh(
                mixPipeline: mixPipeline,
                blurPipeline: blurPipeline,
                mixed: mixed,
                blurred: blurred,
                discs: Self.bokehDiscs(seed: seed)
            ))
        case .dust:
            let specks = self.pipeline(
                vertex: "wallpaperDistortionDustParticle",
                fragment: "wallpaperDistortionDustSpeck",
                pixelFormat: pixelFormat,
                blended: true
            )
            guard let specks, let dust = makeDustParticles(width: from.width, height: from.height) else { return nil }
            extraPass = .particles(pipeline: specks, particles: dust.buffer, grid: dust.grid)
        case .ripple, .blinds, .crystal:
            break
        }
        return Prepared(
            effect: effect,
            pixelFormat: pixelFormat,
            from: from,
            to: to,
            precomputed: precomputed,
            seed: seed,
            origin: origin,
            pipeline: pipeline,
            extraPass: extraPass
        )
    }

    /// Encodes one frame into `target` (same size and format as the prepared inputs); never presents.
    func encode(
        _ prepared: Prepared,
        progress: Float,
        time: Float,
        into commandBuffer: MTLCommandBuffer,
        target: MTLTexture
    ) -> Bool {
        var uniforms = Self.uniforms(
            width: prepared.from.width,
            height: prepared.from.height,
            progress: progress,
            time: time,
            seed: prepared.seed,
            origin: prepared.origin
        )
        // Both extra passes draw nothing at the endpoints, which the shaders render from the inputs alone.
        let midway = progress > 0 && progress < 1
        if case let .bokeh(bokeh) = prepared.extraPass, midway {
            let passes: [(MTLRenderPipelineState, [MTLTexture?], MTLTexture)] = [
                (bokeh.mixPipeline, [prepared.from, prepared.to], bokeh.mixed),
                (bokeh.blurPipeline, [bokeh.mixed], bokeh.blurred),
            ]
            for (pipeline, inputs, output) in passes {
                guard let encoder = Self.makeEncoder(commandBuffer, target: output) else { return false }
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
                encoder.setFragmentTextures(inputs, range: 0 ..< inputs.count)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }
        guard let encoder = Self.makeEncoder(commandBuffer, target: target) else { return false }
        encoder.setRenderPipelineState(prepared.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(prepared.from, index: 0)
        encoder.setFragmentTexture(prepared.to, index: 1)
        switch prepared.extraPass {
        case let .bokeh(bokeh):
            var discCount = UInt32(bokeh.discs.count)
            encoder.setFragmentTexture(bokeh.blurred, index: 2)
            encoder.setFragmentBytes(bokeh.discs, length: MemoryLayout<SIMD4<Float>>.stride * bokeh.discs.count, index: 1)
            encoder.setFragmentBytes(&discCount, length: MemoryLayout<UInt32>.stride, index: 2)
        case let .particles(_, particles, grid):
            var grid = grid
            encoder.setFragmentBuffer(particles, offset: 0, index: 1)
            encoder.setFragmentBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        case nil:
            encoder.setFragmentTexture(prepared.precomputed, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if case .particles(let pipeline, let particles, var grid) = prepared.extraPass, midway {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
            encoder.setVertexBuffer(particles, offset: 0, index: 1)
            encoder.setVertexBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
            encoder.setVertexTexture(prepared.from, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Int(grid.x * grid.y))
        }
        encoder.endEncoding()
        return true
    }

    private func runPrecompute(
        _ precompute: (functionName: String, pixelFormat: MTLPixelFormat),
        width: Int,
        height: Int,
        seed: Float,
        origin: SIMD2<Float>
    ) -> MTLTexture? {
        guard let pipeline = pipeline(fragment: precompute.functionName, pixelFormat: precompute.pixelFormat),
              let texture = makeIntermediate(width: width, height: height, pixelFormat: precompute.pixelFormat),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = Self.makeEncoder(commandBuffer, target: texture) else {
            return nil
        }
        var uniforms = Self.uniforms(width: width, height: height, progress: 0, time: 0, seed: seed, origin: origin)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        // Waiting turns a GPU failure into a nil prepare instead of a broken first frame.
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            Logger.warning("Wallpaper distortion precompute \(precompute.functionName) failed: \(commandBuffer.error?.localizedDescription ?? "unknown")", category: .ui)
            return nil
        }
        return texture
    }

    private func makeIntermediate(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// One particle per block, laid out row-major from the bottom-left block; matches `wallpaperDistortionDust`'s lookup.
    private func makeDustParticles(width: Int, height: Int) -> (buffer: MTLBuffer, grid: SIMD2<UInt32>)? {
        let rows = Self.dustRows
        let columns = Int((Float(width) / Float(height) * Float(rows)).rounded(.up))
        var particles: [SIMD4<Float>] = []
        particles.reserveCapacity(columns * rows)
        for y in 0 ..< rows {
            for x in 0 ..< columns {
                let block = SIMD2(Float(x), Float(y))
                let center = (block + 0.5) / Float(rows)
                particles.append(SIMD4(center.x, center.y, Self.hash(block), Self.hash(block + 7)))
            }
        }
        let buffer = particles.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }
        return buffer.map { (buffer: $0, grid: SIMD2(UInt32(columns), UInt32(rows))) }
    }

    /// Eighteen out-of-focus highlights scattered by `seed`.
    private static func bokehDiscs(seed: Float) -> [SIMD4<Float>] {
        (0 ..< 18).map { index in
            let i = Float(index)
            let point = SIMD2(i * 1.7, seed + i)
            let x = hash(point)
            let center = SIMD2(x, hash(point + x))
            return SIMD4(center.x, center.y, 0.025 + 0.05 * hash(SIMD2(i, 2.3)), 0)
        }
    }

    /// Same formula as the shaders' `distortionHash`, but rounding makes its values differ from the GPU's:
    /// never derive one quantity from both.
    private static func hash(_ point: SIMD2<Float>) -> Float {
        var p = point * SIMD2(123.34, 456.21)
        p -= p.rounded(.down)
        p += (p * (p + 45.32)).sum()
        let product = p.x * p.y
        return product - product.rounded(.down)
    }

    private static func uniforms(
        width: Int,
        height: Int,
        progress: Float,
        time: Float,
        seed: Float,
        origin: SIMD2<Float>
    ) -> WallpaperTransitionUniforms {
        WallpaperTransitionUniforms(
            progress: progress,
            time: time,
            aspect: Float(width) / Float(height),
            seed: seed,
            origin: origin
        )
    }

    private static func makeEncoder(_ commandBuffer: MTLCommandBuffer, target: MTLTexture) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    }

    private func pipeline(
        vertex: String = WallpaperDistortionRenderer.vertexFunctionName,
        fragment: String,
        pixelFormat: MTLPixelFormat,
        blended: Bool = false
    ) -> MTLRenderPipelineState? {
        let key = "\(vertex)+\(fragment)\(blended ? "+blend" : "")@\(pixelFormat.rawValue)"
        if let cached = pipelines[key] {
            return cached
        }
        guard !failedPipelines.contains(key) else { return nil }
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment) else {
            failedPipelines.insert(key)
            Logger.warning("Wallpaper distortion function \(vertex) or \(fragment) unavailable; using crossfade", category: .ui)
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        if blended, let attachment = descriptor.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            // Keeps the frame underneath opaque.
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        }
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            failedPipelines.insert(key)
            Logger.warning("Wallpaper distortion pipeline \(fragment) failed: \(error.localizedDescription)", category: .ui)
            return nil
        }
    }
}
