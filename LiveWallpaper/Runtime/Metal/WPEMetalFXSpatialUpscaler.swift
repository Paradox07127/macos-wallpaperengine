#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal
import MetalFX

/// Present-time MetalFX spatial upscale. Scene renders at `WPEMetalFXRenderScale` < 1
/// and `MTLFXSpatialScaler` writes the drawable, replacing the fullscreen blit.
/// Any rejection falls back to the existing present pass.
///
/// Not thread-safe: the owning executor's present path is a single render thread.
final class WPEMetalFXSpatialUpscaler {

    static let renderScaleDefaultsKey = "WPEMetalFXRenderScale"

    /// Missing/unset = 1.0 (off). Clamped to [0.25, 1.0]. Read live (not
    /// process-frozen) so the settings picker takes effect on the next session
    /// rebuild; consumers capture it at load/executor init, never per frame, so
    /// one live instance keeps one consistent value for its whole life.
    static var renderScale: Double {
        // Test/preview processes read ONLY the isolated store: this machine's
        // real `com.loomscreen.pro` domain must not leak a render scale into
        // headless render tests or oracle captures (every RT would silently
        // shrink and per-pass hashes stop matching Windows).
        let scoped = UserDefaults.appScoped()
        if scoped !== UserDefaults.standard {
            return scoped.object(forKey: renderScaleDefaultsKey) != nil
                ? renderScale(fromRaw: scoped.double(forKey: renderScaleDefaultsKey))
                : 1.0
        }
        for suite in [UserDefaults.appSuite, UserDefaults.standard]
        where suite.object(forKey: renderScaleDefaultsKey) != nil {
            return renderScale(fromRaw: suite.double(forKey: renderScaleDefaultsKey))
        }
        return 1.0
    }

    /// Cached per process — the device itself cannot change.
    static let deviceSupportsSpatialScaler: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }()

    /// Off when scale is 1 or the device cannot serve a spatial scaler — shrinking
    /// the RT for a bilinear stretch would be strictly worse than doing nothing.
    static var isExperimentEnabled: Bool {
        renderScale < 1.0 && deviceSupportsSpatialScaler
    }

    static func renderScale(fromRaw raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return 1.0 }
        return min(max(raw, 0.25), 1.0)
    }

    /// Lower bound for a SCALER INPUT edge. Not a limit for ordinary render
    /// targets: applying it to an authored thin FBO (a 128x16 gradient strip)
    /// would inflate the short edge and change its aspect, which the effect
    /// sampling it reads as distortion.
    static let minimumScalerInputEdge: CGFloat = 64

    /// `floor(value × scale)`, aligned down to even, floored at `minimumEdge`.
    static func scaledDimension(
        _ value: CGFloat,
        scale: Double,
        minimumEdge: CGFloat = minimumScalerInputEdge
    ) -> CGFloat {
        let scaled = (value * CGFloat(scale)).rounded(.down)
        let even = scaled - scaled.truncatingRemainder(dividingBy: 2)
        return max(even, minimumEdge)
    }

    /// Scale 1 returns `size` unchanged. Below 1, each edge goes through
    /// `scaledDimension`. `minimumEdge` defaults to the scaler-input floor;
    /// pooled targets pass 1 so a thin authored FBO keeps its proportions.
    static func scaledCanvasSize(
        _ size: CGSize,
        pixelScale: Double,
        minimumEdge: CGFloat = minimumScalerInputEdge
    ) -> CGSize {
        guard pixelScale < 1 else { return size }
        return CGSize(
            width: scaledDimension(size.width, scale: pixelScale, minimumEdge: minimumEdge),
            height: scaledDimension(size.height, scale: pixelScale, minimumEdge: minimumEdge)
        )
    }

    static func makeIfEnabled(device: MTLDevice, library: MTLLibrary) -> WPEMetalFXSpatialUpscaler? {
        guard isExperimentEnabled else { return nil }
        return WPEMetalFXSpatialUpscaler(device: device, library: library)
    }

    enum FallbackReason: String, Equatable {
        case fitMode
        case sourceExceedsDrawable
        case aspectMismatch
        case hdrInput
        case scalerCreationFailed
        case usageMismatch
    }

    /// 8-bit LDR only. HDR (`rgba16Float`) is linear >1 and needs `.hdr` mode — not this experiment.
    static func isPerceptualInput(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
            return true
        default:
            return false
        }
    }

    /// Rejections decidable without a scaler. Usage checks happen after creation.
    static func preScalerRejection(
        fitMode: WPEPresentFitMode,
        sourceWidth: Int,
        sourceHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) -> FallbackReason? {
        guard sourceWidth <= drawableWidth, sourceHeight <= drawableHeight,
              sourceWidth < drawableWidth || sourceHeight < drawableHeight,
              sourceWidth > 0, sourceHeight > 0, drawableWidth > 0, drawableHeight > 0
        else { return .sourceExceedsDrawable }
        // Scaler is a full-rect → full-rect map (stretch). contain/cover match
        // that only at exact aspect (cross-multiply, no tolerance). center is 1:1.
        switch fitMode {
        case .stretch:
            return nil
        case .contain, .cover:
            return sourceWidth * drawableHeight == sourceHeight * drawableWidth
                ? nil : .aspectMismatch
        case .center:
            return .fitMode
        }
    }

    private struct ScalerKey: Hashable {
        var inputWidth: Int
        var inputHeight: Int
        var outputWidth: Int
        var outputHeight: Int
        var inputFormat: UInt
        var outputFormat: UInt
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private var cachedScaler: (key: ScalerKey, scaler: MTLFXSpatialScaler)?
    /// Capped, not one-shot: a nil from `makeSpatialScaler` can be transient
    /// resource pressure, so a key gets a few tries before it is written off.
    private var failedAttempts: [ScalerKey: Int] = [:]
    private static let maxCreationAttempts = 3
    private var alphaFixPipelines: [UInt: MTLRenderPipelineState] = [:]
    private var didLogActivation = false
    /// Reasons already reported. A session can hit several distinct ones and
    /// each is worth a line; repeats are not.
    private var reportedFallbacks: Set<FallbackReason> = []

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    /// Drops the cached scaler and its internal working textures (4K-class once
    /// the drawable is). The cache is keyed by input/output pixel size, so a
    /// render-scale change or a demote to native never overwrites it — nothing
    /// asks for the old key again and `encodeIfEligible` returns at
    /// `preScalerRejection` before it could. `failedAttempts` and
    /// `alphaFixPipelines` stay: both are tiny and expensive to relearn.
    func releaseCachedScaler() { cachedScaler = nil }

    /// Returns false (encoded nothing) on any rejection so the caller runs the present pass.
    func encodeIfEligible(
        source: MTLTexture,
        drawableTexture: MTLTexture,
        fitMode: WPEPresentFitMode,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if let rejection = Self.preScalerRejection(
            fitMode: fitMode,
            sourceWidth: source.width,
            sourceHeight: source.height,
            drawableWidth: drawableTexture.width,
            drawableHeight: drawableTexture.height
        ) {
            noteFallback(rejection, source: source, drawable: drawableTexture)
            return false
        }
        guard Self.isPerceptualInput(source.pixelFormat) else {
            noteFallback(.hdrInput, source: source, drawable: drawableTexture)
            return false
        }
        let key = ScalerKey(
            inputWidth: source.width,
            inputHeight: source.height,
            outputWidth: drawableTexture.width,
            outputHeight: drawableTexture.height,
            inputFormat: source.pixelFormat.rawValue,
            outputFormat: drawableTexture.pixelFormat.rawValue
        )
        guard failedAttempts[key, default: 0] < Self.maxCreationAttempts else {
            // Still counted: a key written off after 3 tries would otherwise go
            // silent forever and never reach the periodic summary.
            noteFallback(.scalerCreationFailed, source: source, drawable: drawableTexture)
            return false
        }
        let scaler: MTLFXSpatialScaler
        if let cached = cachedScaler, cached.key == key {
            scaler = cached.scaler
        } else {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = source.width
            descriptor.inputHeight = source.height
            descriptor.outputWidth = drawableTexture.width
            descriptor.outputHeight = drawableTexture.height
            descriptor.colorTextureFormat = source.pixelFormat
            descriptor.outputTextureFormat = drawableTexture.pixelFormat
            descriptor.colorProcessingMode = .perceptual
            guard let made = descriptor.makeSpatialScaler(device: device) else {
                failedAttempts[key, default: 0] += 1
                noteFallback(.scalerCreationFailed, source: source, drawable: drawableTexture)
                return false
            }
            cachedScaler = (key, made)
            scaler = made
        }
        guard drawableTexture.usage.isSuperset(of: scaler.outputTextureUsage),
              source.usage.isSuperset(of: scaler.colorTextureUsage)
        else {
            noteFallback(.usageMismatch, source: source, drawable: drawableTexture)
            return false
        }
        // Wallpaper window is transparent; present fragment writes A=1. Resolve
        // the alpha-fix pipeline before encoding so a miss falls back cleanly.
        guard let alphaFix = alphaFixPipeline(for: drawableTexture.pixelFormat) else {
            noteFallback(.scalerCreationFailed, source: source, drawable: drawableTexture)
            return false
        }
        scaler.colorTexture = source
        scaler.inputContentWidth = source.width
        scaler.inputContentHeight = source.height
        scaler.outputTexture = drawableTexture
        scaler.encode(commandBuffer: commandBuffer)
        encodeAlphaFix(pipeline: alphaFix, drawableTexture: drawableTexture, commandBuffer: commandBuffer)
        scaler.colorTexture = nil
        scaler.outputTexture = nil
        if !didLogActivation {
            didLogActivation = true
            Logger.notice(
                "[metalfx] spatial active \(source.width)x\(source.height) -> "
                    + "\(drawableTexture.width)x\(drawableTexture.height) "
                    + "(fmt \(source.pixelFormat.rawValue)->\(drawableTexture.pixelFormat.rawValue))",
                category: .wpeRender
            )
        }
        return true
    }

    /// Alpha-only write of A=1 after the scaler, matching the present fragment's terminal opacity.
    private func alphaFixPipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = alphaFixPipelines[format.rawValue] { return cached }
        guard let vertex = library.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = library.makeFunction(name: "wpe_solidcolor_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.colorAttachments[0].writeMask = .alpha
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        alphaFixPipelines[format.rawValue] = state
        return state
    }

    private func encodeAlphaFix(
        pipeline: MTLRenderPipelineState,
        drawableTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawableTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        WPEFrameOccupancyMeter.count(.presentEncoder)
        encoder.setRenderPipelineState(pipeline)
        var uniforms = WPESolidUniforms(color: SIMD4<Float>(0, 0, 0, 1))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func noteFallback(_ reason: FallbackReason, source: MTLTexture, drawable: MTLTexture) {
        guard reportedFallbacks.insert(reason).inserted else { return }
        Logger.notice(
            "[metalfx] spatial fallback (\(reason.rawValue)) \(source.width)x\(source.height) -> "
                + "\(drawable.width)x\(drawable.height) "
                + "(fmt \(source.pixelFormat.rawValue)->\(drawable.pixelFormat.rawValue))",
            category: .wpeRender
        )
    }

}
#endif
