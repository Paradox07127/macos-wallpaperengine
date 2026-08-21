#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal
import MetalFX
import os

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

    static var isExperimentEnabled: Bool { renderScale < 1.0 }

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

    static func makeIfEnabled(device: MTLDevice) -> WPEMetalFXSpatialUpscaler? {
        guard isExperimentEnabled else { return nil }
        return WPEMetalFXSpatialUpscaler(device: device)
    }

    // MARK: - Eligibility

    enum FallbackReason: String, Equatable {
        case fitMode
        case sourceExceedsDrawable
        case aspectMismatch
        case deviceUnsupported
        case scalerCreationFailed
        case usageMismatch
    }

    /// Rejections decidable before a scaler exists (pure, testable). The usage
    /// checks need the scaler's required-usage properties and happen later.
    static func preScalerRejection(
        fitMode: WPEPresentFitMode,
        sourceWidth: Int,
        sourceHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) -> FallbackReason? {
        // The scaler is a fixed rect→rect scale with no aspect transform, so only
        // stretch (and matching aspects) reproduce the present pass's mapping.
        guard fitMode == .stretch else { return .fitMode }
        // Strictly smaller: an equal-size "upscale" would replace the cheap
        // fullscreen blit with a pointless scaler pass.
        guard sourceWidth <= drawableWidth, sourceHeight <= drawableHeight,
              sourceWidth < drawableWidth || sourceHeight < drawableHeight,
              sourceWidth > 0, sourceHeight > 0, drawableWidth > 0, drawableHeight > 0
        else { return .sourceExceedsDrawable }
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let drawableAspect = Double(drawableWidth) / Double(drawableHeight)
        guard abs(sourceAspect - drawableAspect) / drawableAspect < 0.005 else {
            return .aspectMismatch
        }
        return nil
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
    private let deviceSupported: Bool
    private var cachedScaler: (key: ScalerKey, scaler: MTLFXSpatialScaler)?
    /// Keys whose creation already failed; never retried (creation is expensive
    /// and a failing (size, format) combination stays failing).
    private var failedKeys: Set<ScalerKey> = []
    private var didLogActivation = false
    private var didLogFallback = false

    init(device: MTLDevice) {
        self.device = device
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
        let key = ScalerKey(
            inputWidth: source.width,
            inputHeight: source.height,
            outputWidth: drawableTexture.width,
            outputHeight: drawableTexture.height,
            inputFormat: source.pixelFormat.rawValue,
            outputFormat: drawableTexture.pixelFormat.rawValue
        )
        guard !failedKeys.contains(key) else { return false }
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
                failedKeys.insert(key)
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
        scaler.colorTexture = source
        scaler.inputContentWidth = source.width
        scaler.inputContentHeight = source.height
        scaler.outputTexture = drawableTexture
        scaler.encode(commandBuffer: commandBuffer)
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
