#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO

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
    private let encodedByteCount: Int

    /// Byte cap (sync with WorkshopPreviewImageLoader; 8 MiB blanked real previews).
    static let maxBytes = 32 * 1024 * 1024
    /// Animate at most this many frames; longer animations degrade to a static
    /// poster (we never drop the preview entirely just because it's long).
    static let maxFrameCount = 120
    /// Total decoded-pixel budget (RGBA bytes) across all frames before an
    /// animation degrades to its static poster.
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    /// 30 FPS playback cap to bound CPU on long-running grids.
    static let minFrameDelay: TimeInterval = 0.033

    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        if index == 0 { return posterFrame }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    var estimatedCacheCost: Int {
        let posterBytes = posterFrame.bytesPerRow * posterFrame.height
        let (total, overflow) = posterBytes.addingReportingOverflow(encodedByteCount)
        return overflow ? Int.max : total
    }
}

extension WorkshopAnimatedGIF {
    /// Returns `nil` on decode failure or any budget violation.
    static func make(from data: Data) -> WorkshopPreviewAsset? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        // Reject decompression bombs via metadata dims before poster decode.
        guard count > 0,
              let dimensions = imageDimensions(from: source, index: 0),
              isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: 1),
              let poster = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
