#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO

/// How large a preview has to be decoded. Steam serves one `preview_url` for
/// every surface, so the size is the caller's, not the asset's.
enum WorkshopPreviewSize: String, Sendable {
    /// Library grid tile (184–220 pt) and the paste-flow rows.
    case tile
    /// Detail-sheet hero.
    case hero

    /// Longest-edge cap handed to Image I/O, sized so `scaledToFill` never has
    /// to upscale: the surface is square, so a 16:9 preview must be
    /// `edge × 16/9` wide for its height to cover. Tile = 220 pt
    /// (`LibraryGrid.maximumColumnWidth`) × 2 × 16/9 ≈ 782; hero = 392 pt
    /// (`Inspector.maxWidth`) × 2 × 16/9 ≈ 1394. Still 3–7× fewer pixels than
    /// the 1920×1080 poster Steam actually stores.
    var maxPixelSize: Int {
        switch self {
        case .tile: return 800
        case .hero: return 1400
        }
    }
}

/// Workshop preview still/animation. `@unchecked Sendable`: read-only images.
enum WorkshopPreviewAsset: @unchecked Sendable {
    case staticImage(CGImage)
    case animatedGIF(WorkshopAnimatedGIF)

    var posterFrame: CGImage {
        switch self {
        case .staticImage(let image): return image
        case .animatedGIF(let gif): return gif.posterFrame
        }
    }

    /// Approximate retained bytes supplied to `NSCache`: decoded poster pixels
    /// plus the encoded backing retained by an animated `CGImageSource`.
    var estimatedCacheCost: Int {
        switch self {
        case .staticImage(let image):
            return image.bytesPerRow * image.height
        case .animatedGIF(let gif):
            return gif.estimatedCacheCost
        }
    }
}

/// Budgeted GIF/APNG: eager poster, lazy frames (ImageIO free-threaded).
struct WorkshopAnimatedGIF: @unchecked Sendable {
    let posterFrame: CGImage
    let frameCount: Int
    /// Per-frame display duration, floored at the 30 FPS playback cap.
    let frameDelays: [TimeInterval]

    private let source: CGImageSource
    private let decodeOptions: CFDictionary
    private let encodedByteCount: Int

    /// Byte cap (sync with WorkshopPreviewImageLoader; 32 MiB blanked real previews).
    static let maxBytes = 32 * 1024 * 1024
    /// Animate at most this many frames; longer animations degrade to a static
    /// poster (we never drop the preview entirely just because it's long).
    static let maxFrameCount = 120
    /// Total decoded-pixel budget (RGBA bytes) across all frames before an
    /// animation degrades to its static poster. Measured on the *source*
    /// dimensions, which is what a decompression bomb inflates.
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    /// 30 FPS playback cap to bound CPU on long-running grids.
    static let minFrameDelay: TimeInterval = 0.033

    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        if index == 0 { return posterFrame }
        return CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions)
    }

    var estimatedCacheCost: Int {
        let posterBytes = posterFrame.bytesPerRow * posterFrame.height
        let (total, overflow) = posterBytes.addingReportingOverflow(encodedByteCount)
        return overflow ? Int.max : total
    }
}

extension WorkshopAnimatedGIF {
    /// `kCGImageSourceShouldCache: false` is load-bearing, not hygiene: with the
    /// default (true on 64-bit) ImageIO holds every frame it has decoded inside
    /// the source, so one hovered 120-frame GIF parks its whole decoded self in
    /// a cache entry priced at poster + encoded bytes.
    nonisolated(unsafe) private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    /// Thumbnail rather than full decode: the grid draws these at ~220 pt, and a
    /// 1920×1080 poster costs ~8 MB of RGBA plus a per-frame GPU resample.
    /// `CreateThumbnailAtIndex` composes partial GIF frames before scaling
    /// (verified against a hand-built partial-frame fixture), so animation frames
    /// can take the same path as the poster.
    private static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode here, on this background thread, rather than lazily on
            // whichever thread first draws the image.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
    }

    /// Returns `nil` on decode failure or any budget violation.
    static func make(
        from data: Data,
        size: WorkshopPreviewSize = .tile
    ) -> WorkshopPreviewAsset? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let decodeOptions = thumbnailOptions(maxPixelSize: size.maxPixelSize)
        let count = CGImageSourceGetCount(source)
        // Reject decompression bombs via metadata dims before poster decode.
        guard count > 0,
              let dimensions = imageDimensions(from: source, index: 0),
              isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: 1),
              let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions) else {
            return nil
        }

        // Over budget → static poster (nil used to blank the card).
        guard count > 1,
              count <= maxFrameCount,
              isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: count) else {
            return .staticImage(poster)
        }

        return .animatedGIF(
            WorkshopAnimatedGIF(
                posterFrame: poster,
                frameCount: count,
                frameDelays: readFrameDelays(from: source, frameCount: count),
                source: source,
                decodeOptions: decodeOptions,
                encodedByteCount: data.count
            )
        )
    }

    /// Overflow-safe RGBA footprint via staged UInt64 math.
    static func isWithinPixelBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0, frameCount > 0 else { return false }
        let w = UInt64(width), h = UInt64(height), n = UInt64(frameCount)
        guard w <= UInt64.max / h else { return false }
        let pixelsPerFrame = w * h
        guard pixelsPerFrame <= UInt64.max / n else { return false }
        let totalPixels = pixelsPerFrame * n
        guard totalPixels <= UInt64.max / 4 else { return false }
        return totalPixels * 4 <= UInt64(maxDecodedPixelBytes)
    }

    /// From source metadata — cheap, no full decode.
    static func imageDimensions(from source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }

    static func readFrameDelays(from source: CGImageSource, frameCount: Int) -> [TimeInterval] {
        var delays: [TimeInterval] = []
        delays.reserveCapacity(frameCount)
        // Loop (not map) so bridged property dicts release per frame.
        for index in 0..<frameCount {
            autoreleasepool {
                delays.append(frameDelay(from: source, index: index))
            }
        }
        return delays
    }

    private static func frameDelay(from source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
            return 0.1
        }
        if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                return max(unclamped, minFrameDelay)
            }
            if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                return max(delay, minFrameDelay)
            }
        }
        if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                return max(delay, minFrameDelay)
            }
            if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                return max(delay, minFrameDelay)
            }
        }
        return 0.1
    }
}
#endif
