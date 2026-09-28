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

/// Narrow submission boundary for failure tests; Screen remains the transition owner.
@MainActor
protocol WallpaperTransitionRendering: AnyObject {
    var device: MTLDevice { get }
    func prepare(_ effect: WallpaperRevealEffect) -> Bool
    func draw(
        _ pass: WallpaperTransitionRenderer.Pass,
        effect: WallpaperRevealEffect,
        uniforms: WallpaperTransitionUniforms,
        in layer: CAMetalLayer,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) -> Bool
}

@MainActor
final class WallpaperTransitionRenderer: WallpaperTransitionRendering {
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
    private var failedPipelines: Set<String> = []

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

    /// Resolve every required PSO before attaching any mask. A failed immutable
    /// library/PSO stays a known fallback, rather than retrying on every tick.
    func prepare(_ effect: WallpaperRevealEffect) -> Bool {
        guard pipeline(named: effect.maskFunctionName) != nil else { return false }
        if let light = effect.lightFunctionName {
            return pipeline(named: light) != nil
        }
        return true
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
    @discardableResult
    func draw(
        _ pass: Pass,
        effect: WallpaperRevealEffect,
        uniforms: WallpaperTransitionUniforms,
        in layer: CAMetalLayer,
        onFailure: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        let commandBuffer = render(pass, effect: effect, uniforms: uniforms, to: drawable.texture) { buffer in
            buffer.addCompletedHandler { completed in
                guard completed.status == .error else { return }
                Logger.warning("Wallpaper transition GPU failure: \(completed.error?.localizedDescription ?? "unknown")", category: .ui)
                Task { @MainActor in onFailure() }
            }
            if !layer.presentsWithTransaction {
                buffer.present(drawable)
            }
        }
        guard let commandBuffer else { return false }
        if layer.presentsWithTransaction {
            // Required by CAMetalLayer's transaction presentation contract.
            commandBuffer.waitUntilScheduled()
            guard commandBuffer.status != .error else { return false }
            drawable.present()
        }
        return true
    }

    private func pipeline(named name: String) -> MTLRenderPipelineState? {
        if let cached = pipelines[name] {
            return cached
        }
        guard !failedPipelines.contains(name) else { return nil }
        guard let vertex = library.makeFunction(name: "wallpaperTransitionVertex"),
              let fragment = library.makeFunction(name: name) else {
            failedPipelines.insert(name)
            Logger.warning("Wallpaper transition function \(name) unavailable; using crossfade", category: .ui)
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[name] = pipeline
            return pipeline
        } catch {
            failedPipelines.insert(name)
            Logger.warning("Wallpaper transition pipeline \(name) failed: \(error.localizedDescription)", category: .ui)
            return nil
        }
    }
}
