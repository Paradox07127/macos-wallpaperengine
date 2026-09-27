import LiveWallpaperCore
import Metal
import QuartzCore

/// Layout matches `WallpaperTransitionUniforms` in WallpaperTransitions.metal.
struct WallpaperTransitionUniforms {
    var progress: Float
    var time: Float
    var aspect: Float
    var seed: Float
    var origin: SIMD2<Float>
}

@MainActor
final class WallpaperTransitionRenderer {
    enum Pass {
        case mask
        case light
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// nil when the app has no Metal device or its shader library lacks the transition functions.
    static let shared: WallpaperTransitionRenderer? = MTLCreateSystemDefaultDevice().flatMap { WallpaperTransitionRenderer(device: $0) }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              library.functionNames.contains("wallpaperTransitionVertex") else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
    }

    func functionName(for pass: Pass, effect: WallpaperRevealEffect) -> String? {
        switch pass {
        case .mask: effect.maskFunctionName
        case .light: effect.lightFunctionName
        }
    }

    /// Encodes and commits one full-target draw; the caller decides whether to wait or present.
    @discardableResult
    func render(
        _ pass: Pass,
        effect: WallpaperRevealEffect,
        uniforms: WallpaperTransitionUniforms,
        to texture: MTLTexture,
        beforeCommit: (MTLCommandBuffer) -> Void = { _ in }
    ) -> MTLCommandBuffer? {
        guard let name = functionName(for: pass, effect: effect),
              let pipeline = pipeline(named: name),
              let commandBuffer = queue.makeCommandBuffer() else {
            return nil
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperTransitionUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        beforeCommit(commandBuffer)
        commandBuffer.commit()
        return commandBuffer
    }

    /// With `presentsWithTransaction` the drawable lands in the same Core Animation commit as
    /// the caller's layer changes, so a freshly attached mask never shows a frame without content.
    func draw(
        _ pass: Pass,
        effect: WallpaperRevealEffect,
        uniforms: WallpaperTransitionUniforms,
        in layer: CAMetalLayer
    ) {
        guard let drawable = layer.nextDrawable() else { return }
        let commandBuffer = render(pass, effect: effect, uniforms: uniforms, to: drawable.texture) { buffer in
            if !layer.presentsWithTransaction {
                buffer.present(drawable)
            }
        }
        guard let commandBuffer, layer.presentsWithTransaction else { return }
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }

    private func pipeline(named name: String) -> MTLRenderPipelineState? {
        if let cached = pipelines[name] {
            return cached
        }
        guard let vertex = library.makeFunction(name: "wallpaperTransitionVertex"),
              let fragment = library.makeFunction(name: name) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            Logger.warning("Wallpaper transition pipeline \(name) failed to build", category: .ui)
            return nil
        }
        pipelines[name] = pipeline
        return pipeline
    }
}
