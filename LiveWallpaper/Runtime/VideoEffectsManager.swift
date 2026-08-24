@preconcurrency import AVFoundation
import CoreImage
import Foundation
import LiveWallpaperCore

struct FilterParameters: Sendable {
    let blurRadius: Double
    let saturation: Double
    let brightness: Double
    let warmth: Double
    let vignetteIntensity: Double
    let autoTimeTint: Bool

    init(from config: VideoEffectConfig) {
        self.blurRadius = config.blurRadius
        self.saturation = config.saturation
        self.brightness = config.brightness
        self.warmth = config.warmth
        self.vignetteIntensity = config.vignetteIntensity
        self.autoTimeTint = config.autoTimeTint
    }
}

@MainActor
final class VideoEffectsManager {

    // MARK: - Composition Building

    func buildComposition(
        for asset: AVAsset,
        config: VideoEffectConfig,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        let params = FilterParameters(from: config)

        if #available(macOS 26.0, *) {
            return try await Self.buildUsingApplier(
                asset: asset,
                params: params,
                frameDuration: frameDuration
            )
        } else {
            return try await Self.buildUsingHandler(
                asset: asset,
                params: params,
                frameDuration: frameDuration
            )
        }
    }

    // MARK: - macOS 26 path (async applier + Configuration copy)

    @available(macOS 26.0, *)
    private nonisolated static func buildUsingApplier(
        asset: AVAsset,
        params: FilterParameters,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        let chain = VideoFilterChain(params: params)
        let applier: @Sendable (AVCIImageFilteringParameters) async throws -> AVCIImageFilteringResult = { parameters in
            let sourceExtent = parameters.sourceImage.extent
            let filtered = chain.apply(to: parameters.sourceImage.clampedToExtent())
            return AVCIImageFilteringResult(resultImage: filtered.cropped(to: sourceExtent))
        }

        let composition = try await AVVideoComposition(applyingFiltersTo: asset, applier: applier)

        return AVVideoComposition(
            configuration: AVVideoComposition.Configuration(
                animationTool: composition.animationTool,
                colorPrimaries: composition.colorPrimaries,
                colorTransferFunction: composition.colorTransferFunction,
                colorYCbCrMatrix: composition.colorYCbCrMatrix,
                customVideoCompositorClass: composition.customVideoCompositorClass,
                frameDuration: frameDuration,
                instructions: composition.instructions,
                outputBufferDescription: composition.outputBufferDescription,
                perFrameHDRDisplayMetadataPolicy: composition.perFrameHDRDisplayMetadataPolicy,
                renderScale: composition.renderScale,
                renderSize: composition.renderSize,
                sourceSampleDataTrackIDs: composition.sourceSampleDataTrackIDs,
                sourceTrackIDForFrameTiming: composition.sourceTrackIDForFrameTiming,
                spatialVideoConfigurations: composition.spatialVideoConfigurations
            )
        )
    }

    // MARK: - macOS 14/15 path (handler-based init + mutable copy)

    private nonisolated static func buildUsingHandler(
        asset: AVAsset,
        params: FilterParameters,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        let chain = VideoFilterChain(params: params)
        let mutable = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let sourceExtent = request.sourceImage.extent
                let filtered = chain.apply(to: request.sourceImage.clampedToExtent())
                request.finish(with: filtered.cropped(to: sourceExtent), context: nil)
            }
        )
        mutable.frameDuration = frameDuration
        return mutable
    }

    // MARK: - Blur Radius Clamp

    /// Matches the Color Adjustments blur slider's own cap (ColorAdjustmentsView.swift:19,
    /// `0...30`) so an out-of-range or non-finite blurRadius can't demand unbounded
    /// CIGaussianBlur work.
    nonisolated static let maxBlurRadius: Double = 30

    nonisolated static func clampedBlurRadius(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maxBlurRadius)
    }

    // MARK: - Time-of-Day Warmth

    /// Test-only clock seam; production always resolves the real time.
    nonisolated(unsafe) static var currentDateProvider: () -> Date = Date.init

    /// Guards the three `nonisolated(unsafe)` statics below: `warmthForCurrentHour`
    /// runs on AVFoundation's per-frame filtering callback, whose delivery thread
    /// isn't documented as serial, and the cache is shared static state across
    /// every player.
    private nonisolated static let warmthCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedWarmth: Double = 6500
    private nonisolated(unsafe) static var cacheValidFrom: Date = .distantFuture
    private nonisolated(unsafe) static var cacheExpiresAt: Date = .distantPast
    /// Test-only: counts cache misses, so a test can prove the cache itself
    /// (not just the returned value) is doing its job.
    nonisolated(unsafe) static var warmthRecomputeCount = 0

    /// Test-only: forces the next call to recompute, so tests with an injected
    /// clock don't inherit cache state left over from a previous test.
    nonisolated static func resetWarmthCacheForTesting() {
        warmthCacheLock.lock()
        defer { warmthCacheLock.unlock() }
        invalidateWarmthCacheLocked()
        warmthRecomputeCount = 0
    }

    private nonisolated static func invalidateWarmthCacheLocked() {
        cacheValidFrom = .distantFuture
        cacheExpiresAt = .distantPast
    }

    /// A time zone change moves the local hour without moving `Date`, so neither
    /// bound in `warmthForCurrentHour` can see it. Observing the change costs
    /// nothing per frame, unlike re-reading `Calendar.current` to compare.
    /// Registered on first use; `static let` initialisation is one-shot.
    private nonisolated static let timeZoneObserver: NSObjectProtocol = NotificationCenter.default
        .addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in
            warmthCacheLock.lock()
            defer { warmthCacheLock.unlock() }
            invalidateWarmthCacheLocked()
        }

    /// `Calendar.current` was being read on every composited video frame (up to
    /// 216,000 times/hour/player at 60fps) even though the result only changes
    /// on the hour. Cached until the next hour boundary instead.
    nonisolated static func warmthForCurrentHour() -> Double {
        let now = currentDateProvider()
        _ = timeZoneObserver

        warmthCacheLock.lock()
        defer { warmthCacheLock.unlock() }

        // Lower bound as well as upper: an NTP correction moves `now` backwards,
        // and an upper-bound-only check would serve the stale hour until real
        // time caught up. A time zone change moves neither bound — that one
        // arrives through `timeZoneObserver`.
        if now >= cacheValidFrom, now < cacheExpiresAt {
            return cachedWarmth
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        cachedWarmth = Self.warmth(forHour: hour)
        cacheValidFrom = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        cacheExpiresAt = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        warmthRecomputeCount += 1
        return cachedWarmth
    }

    private nonisolated static func warmth(forHour hour: Int) -> Double {
        switch hour {
        case 6..<9:   return 5500
        case 9..<17:  return 6500
        case 17..<20: return 4500
        case 20..<23: return 3500
        default:      return 3000
        }
    }
}

/// Per-composition CIFilter chain, built once and reused across frames instead
/// of reconstructing filters via `CIFilter(name:)` on every decoded frame.
/// AVFoundation does not document serial delivery for the per-frame filtering
/// callbacks and `CIFilter` is not thread-safe, so input mutation is guarded by
/// a lock; `outputImage` snapshots inputs into the returned `CIImage`, so the
/// lock never spans actual rendering.
private final class VideoFilterChain: @unchecked Sendable {
    private let params: FilterParameters
    private let lock = NSLock()
    private let blur: CIFilter?
    private let colorControls: CIFilter?
    private let temperature: CIFilter?
    private let vignette: CIFilter?
    private var appliedWarmth: Double?

    init(params: FilterParameters) {
        self.params = params

        let clampedBlurRadius = VideoEffectsManager.clampedBlurRadius(params.blurRadius)
        if clampedBlurRadius > 0, let f = CIFilter(name: "CIGaussianBlur") {
            f.setValue(clampedBlurRadius, forKey: kCIInputRadiusKey)
            blur = f
        } else {
            blur = nil
        }

        if params.saturation != 1.0 || params.brightness != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(params.saturation, forKey: kCIInputSaturationKey)
            f.setValue(params.brightness, forKey: kCIInputBrightnessKey)
            colorControls = f
        } else {
            colorControls = nil
        }

        // With autoTimeTint the effective warmth changes at hour boundaries, so
        // the filter must exist even when the current hour maps to neutral.
        if params.autoTimeTint || params.warmth != 6500, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature = f
        } else {
            temperature = nil
        }

        if params.vignetteIntensity > 0, let f = CIFilter(name: "CIVignette") {
            f.setValue(params.vignetteIntensity, forKey: kCIInputIntensityKey)
            f.setValue(max(params.vignetteIntensity * 2, 1.0), forKey: kCIInputRadiusKey)
            vignette = f
        } else {
            vignette = nil
        }
    }

    func apply(to source: CIImage) -> CIImage {
        lock.lock()
        defer { lock.unlock() }

        var image = source

        if let f = blur {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        if let f = colorControls {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        if let f = temperature {
            let warmth = params.autoTimeTint ? VideoEffectsManager.warmthForCurrentHour() : params.warmth
            if warmth != 6500 {
                if warmth != appliedWarmth {
                    f.setValue(CIVector(x: CGFloat(warmth), y: 0), forKey: "inputTargetNeutral")
                    appliedWarmth = warmth
                }
                f.setValue(image, forKey: kCIInputImageKey)
                image = f.outputImage ?? image
            }
        }

        if let f = vignette {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        return image
    }
}
