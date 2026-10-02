import LiveWallpaperCore
import Metal

enum WallpaperDistortionEffect: String, CaseIterable, Sendable {
    case ripple
    case blinds
    case crystal

    var fragmentFunctionName: String {
        switch self {
        case .ripple: "wallpaperDistortionRipple"
        case .blinds: "wallpaperDistortionBlinds"
        case .crystal: "wallpaperDistortionCrystal"
        }
    }

    /// Once-per-transition pass whose output the frame fragment reads at texture(2); nil = none.
    var precompute: (functionName: String, pixelFormat: MTLPixelFormat)? {
        switch self {
        case .crystal: ("wallpaperDistortionCrystalCells", .rgba8Uint)
        case .ripple, .blinds: nil
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
    }

    /// nil when the app has no Metal device or its shader library lacks the distortion functions.
    static let shared: WallpaperDistortionRenderer? = MTLCreateSystemDefaultDevice().flatMap { WallpaperDistortionRenderer(device: $0) }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var failedPipelines: Set<String> = []

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              library.functionNames.contains("wallpaperDistortionVertex") else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
    }

    /// `from` and `to` must share size and `pixelFormat` (`.bgra8Unorm` or `.rgba16Float`), top-left origin.
    /// `origin` is in uv with y up. nil means the caller should fall back to a crossfade.
    func prepare(
        _ effect: WallpaperDistortionEffect,
        from: MTLTexture,
        to: MTLTexture,
        seed: Float,
        origin: SIMD2<Float>,
        pixelFormat: MTLPixelFormat
    ) -> Prepared? {
        guard let pipeline = pipeline(named: effect.fragmentFunctionName, pixelFormat: pixelFormat) else { return nil }
        var precomputed: MTLTexture?
        if let precompute = effect.precompute {
            precomputed = runPrecompute(precompute, width: from.width, height: from.height, seed: seed, origin: origin)
            guard precomputed != nil else { return nil }
        }
        return Prepared(
            effect: effect,
            pixelFormat: pixelFormat,
            from: from,
            to: to,
            precomputed: precomputed,
            seed: seed,
            origin: origin,
            pipeline: pipeline
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
        guard let encoder = Self.makeEncoder(commandBuffer, target: target) else { return false }
        encoder.setRenderPipelineState(prepared.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(prepared.from, index: 0)
        encoder.setFragmentTexture(prepared.to, index: 1)
        encoder.setFragmentTexture(prepared.precomputed, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: precompute.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let pipeline = pipeline(named: precompute.functionName, pixelFormat: precompute.pixelFormat),
              let texture = device.makeTexture(descriptor: descriptor),
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

    private func pipeline(named name: String, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(name)@\(pixelFormat.rawValue)"
        if let cached = pipelines[key] {
            return cached
        }
        guard !failedPipelines.contains(key) else { return nil }
        guard let vertex = library.makeFunction(name: "wallpaperDistortionVertex"),
              let fragment = library.makeFunction(name: name) else {
            failedPipelines.insert(key)
            Logger.warning("Wallpaper distortion function \(name) unavailable; using crossfade", category: .ui)
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            failedPipelines.insert(key)
            Logger.warning("Wallpaper distortion pipeline \(name) failed: \(error.localizedDescription)", category: .ui)
            return nil
        }
    }
}
