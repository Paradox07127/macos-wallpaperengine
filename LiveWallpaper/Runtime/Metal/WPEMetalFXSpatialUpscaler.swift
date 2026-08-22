#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal
import MetalFX

/// Experimental MetalFX spatial upscale at present time: the scene renders at a
/// reduced resolution (`WPEMetalFXRenderScale` < 1.0) and an `MTLFXSpatialScaler`
/// writes the drawable directly, replacing the fullscreen present blit. Any
/// ineligibility falls back to the existing present pass — never fatal.
///
/// Not thread-safe by design, same reason as `frameUniformContext`: the owning
/// executor's present path is driven by a single render thread, so `encodePresent`
/// never runs concurrently on one instance and the caches below need no lock.
final class WPEMetalFXSpatialUpscaler {

    // MARK: - Experiment flag

    /// `WPEMetalFXRenderScale` (Double): read once, appSuite first, then standard;
    /// clamped to [0.25, 1.0]. Missing/unset means 1.0 = experiment off.
    static let renderScale: Double = {
        for suite in [UserDefaults.appSuite, UserDefaults.standard]
        where suite.object(forKey: "WPEMetalFXRenderScale") != nil {
            return renderScale(fromRaw: suite.double(forKey: "WPEMetalFXRenderScale"))
        }
        return 1.0
    }()

    /// Device support folds into the master predicate: on a device MetalFX
    /// cannot serve, rendering below the drawable would trade resolution for a
    /// plain bilinear stretch — strictly worse than doing nothing.
    static let isExperimentEnabled: Bool = {
        guard renderScale < 1.0 else { return false }
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return false }
        return true
    }()

    /// Pure raw-value → effective-scale mapping, split out so tests can inject
    /// raw values without touching UserDefaults.
    static func renderScale(fromRaw raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return 1.0 }
        return min(max(raw, 0.25), 1.0)
    }

    /// `floor(value × scale)`, aligned down to an even number, floored at 64.
    /// Callers must gate on `isExperimentEnabled`; this always multiplies.
    static func scaledDimension(_ value: CGFloat, scale: Double = renderScale) -> CGFloat {
        let scaled = (value * CGFloat(scale)).rounded(.down)
        let even = scaled - scaled.truncatingRemainder(dividingBy: 2)
        return max(even, 64)
    }

    static func makeIfEnabled(device: MTLDevice, library: MTLLibrary) -> WPEMetalFXSpatialUpscaler? {
        guard isExperimentEnabled else { return nil }
        return WPEMetalFXSpatialUpscaler(device: device, library: library)
    }

    // MARK: - Eligibility

    enum FallbackReason: String, Equatable {
        case fitMode
        case sourceExceedsDrawable
        case aspectMismatch
        case hdrInput
        case deviceUnsupported
        case scalerCreationFailed
        case usageMismatch
    }

    /// Inputs the scaler is allowed to see under `.perceptual`: Apple's contract
    /// is tone-mapped 0-1 sRGB, which our 8-bit scene outputs satisfy. HDR
    /// (`rgba16Float`) scenes carry linear >1 values and need the `.hdr` mode —
    /// future work, fall back for now.
    static let perceptualInputFormats: Set<UInt> = [
        MTLPixelFormat.rgba8Unorm.rawValue,
        MTLPixelFormat.rgba8Unorm_srgb.rawValue,
        MTLPixelFormat.bgra8Unorm.rawValue,
        MTLPixelFormat.bgra8Unorm_srgb.rawValue,
    ]

    /// Rejections decidable before a scaler exists (pure, testable). The usage
    /// checks need the scaler's required-usage properties and happen later.
    static func preScalerRejection(
        fitMode: WPEPresentFitMode,
        sourceWidth: Int,
        sourceHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) -> FallbackReason? {
        // Strictly smaller: an equal-size "upscale" would replace the cheap
        // fullscreen blit with a pointless scaler pass.
        guard sourceWidth <= drawableWidth, sourceHeight <= drawableHeight,
              sourceWidth < drawableWidth || sourceHeight < drawableHeight,
              sourceWidth > 0, sourceHeight > 0, drawableWidth > 0, drawableHeight > 0
        else { return .sourceExceedsDrawable }
        // The scaler is a full-rect → full-rect map, exactly what stretch does,
        // at any aspect. contain/cover degenerate to it ONLY at an exactly
        // equal aspect (cross-multiplied, no tolerance: a 1px letterbox the
        // scaler stretched away is still wrong). center never matches — it
        // keeps source pixels 1:1 in the middle of the drawable.
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

    // MARK: - Scaler cache

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
    private let deviceSupported: Bool
    private var cachedScaler: (key: ScalerKey, scaler: MTLFXSpatialScaler)?
    /// Creation attempts per failing key. Capped rather than one-shot: a nil
    /// from `makeSpatialScaler` can be transient resource pressure, so a key
    /// gets `maxCreationAttempts` tries before it is written off for the session.
    private var failedAttempts: [ScalerKey: Int] = [:]
    private static let maxCreationAttempts = 3
    /// Alpha-fix pipeline per drawable pixel format (in practice one entry).
    private var alphaFixPipelines: [UInt: MTLRenderPipelineState] = [:]
    private var didLogActivation = false
    private var didLogFallback = false

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
        deviceSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    // MARK: - Encode

    /// Encodes source → drawable through the spatial scaler when eligible.
    /// Returns false (having encoded nothing) on any rejection so the caller
    /// runs the existing present pass instead.
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
        guard deviceSupported else {
            noteFallback(.deviceUnsupported, source: source, drawable: drawableTexture)
            return false
        }
        guard Self.perceptualInputFormats.contains(source.pixelFormat.rawValue) else {
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
        guard failedAttempts[key, default: 0] < Self.maxCreationAttempts else { return false }
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
        // No intermediate textures in this experiment: both endpoints must already
        // carry the scaler's required usage, or we fall back.
        guard drawableTexture.usage.isSuperset(of: scaler.outputTextureUsage),
              source.usage.isSuperset(of: scaler.colorTextureUsage)
        else {
            noteFallback(.usageMismatch, source: source, drawable: drawableTexture)
            return false
        }
        // The wallpaper window is transparent; the classic present fragment
        // writes alpha=1 to keep the drawable terminal-opaque, and the scaler
        // gives no such guarantee. Resolve the alpha-fix pipeline BEFORE
        // encoding, so a pipeline failure falls back to the classic path
        // instead of presenting an un-fixed frame.
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
        // Don't let the idle scaler retain a drawable/RT between frames.
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

    /// Fullscreen draw with an alpha-only write mask forcing A=1 across the
    /// drawable after the scaler pass, restoring the present fragment's
    /// terminal-opacity contract at negligible bandwidth (RGB lanes masked off).
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
        encoder.setRenderPipelineState(pipeline)
        var uniforms = WPESolidUniforms(color: SIMD4<Float>(0, 0, 0, 1))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func noteFallback(_ reason: FallbackReason, source: MTLTexture, drawable: MTLTexture) {
        guard !didLogFallback else { return }
        didLogFallback = true
        Logger.notice(
            "[metalfx] spatial fallback (\(reason.rawValue)) \(source.width)x\(source.height) -> "
                + "\(drawable.width)x\(drawable.height) "
                + "(fmt \(source.pixelFormat.rawValue)->\(drawable.pixelFormat.rawValue))",
            category: .wpeRender
        )
    }
}
#endif
