#if !LITE_BUILD
import AppKit
import ImageIO
import LiveWallpaperCore
import SwiftUI

/// `.pane` is the default because the expensive mistake is silent: decoding too
/// much only wastes work, decoding too little visibly softens.
enum WPEPreviewSize {
    /// Gallery tiles: 220 pt square, `resizeAspectFill` from 16:9, 2×.
    case tile
    case pane

    var maxPixelSize: Int {
        switch self {
        case .tile: 800
        case .pane: 2560
        }
    }
}

/// `@unchecked Sendable`: every stored value is immutable, and `CGImageSource`
/// reads are free-threaded.
final class WPEPreviewDecodedImage: @unchecked Sendable {
    let posterFrame: CGImage
    let frameCount: Int
    let frameDelays: [TimeInterval]
    /// `nil` for stills and for animations that blew the pixel budget.
    private let source: CGImageSource?
    private let decodeOptions: CFDictionary
    let estimatedCost: Int

    fileprivate init(
        posterFrame: CGImage,
        frameCount: Int,
        frameDelays: [TimeInterval],
        source: CGImageSource?,
        decodeOptions: CFDictionary,
        encodedByteCount: Int
    ) {
        self.posterFrame = posterFrame
        self.frameCount = frameCount
        self.frameDelays = frameDelays
        self.source = source
        self.decodeOptions = decodeOptions
        let posterBytes = posterFrame.bytesPerRow * posterFrame.height
        let (total, overflow) = posterBytes.addingReportingOverflow(source == nil ? 0 : encodedByteCount)
        estimatedCost = overflow ? Int.max : total
    }

    func frame(at index: Int) -> CGImage? {
        guard index > 0, index < frameCount, let source else { return posterFrame }
        return CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions)
    }

    static func decode(
        _ data: Data,
        maxPixelSize: Int = WPEPreviewImageDecodeBudget.defaultMaxPixelSize
    ) -> WPEPreviewDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, WPEPreviewImageDecodeBudget.sourceOptions) else {
            return nil
        }
        let options = WPEPreviewImageDecodeBudget.thumbnailOptions(maxPixelSize: maxPixelSize)
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let dimensions = WPEPreviewImageDecodeBudget.imageDimensions(from: source, index: 0),
              WPEPreviewImageDecodeBudget.isWithinPixelBudget(
                  width: dimensions.width, height: dimensions.height, frameCount: 1
              ),
              let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        // Priced against what playback will actually decode (the capped poster), not
        // the source dimensions.
        let animates = count > 1 && WPEPreviewImageDecodeBudget.allowsAnimation(
            width: poster.width,
            height: poster.height,
            frameCount: count
        )
        return WPEPreviewDecodedImage(
            posterFrame: poster,
            frameCount: animates ? count : 1,
            frameDelays: animates ? readFrameDelays(from: source, frameCount: count) : [],
            source: animates ? source : nil,
            decodeOptions: options,
            encodedByteCount: data.count
        )
    }

    private static func readFrameDelays(from source: CGImageSource, frameCount: Int) -> [TimeInterval] {
        (0 ..< frameCount).map { idx in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [String: Any] else {
                return 0.1
            }
            if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return max(unclamped, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            return 0.1
        }
    }
}

enum WPEPreviewImageDecodeBudget {
    static let maxEncodedBytes = WorkshopAnimatedGIF.maxBytes
    static let maxFrameCount = 120
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    static let minFrameDelay: TimeInterval = 0.033
    static let defaultMaxPixelSize = WPEPreviewSize.pane.maxPixelSize
    nonisolated(unsafe) static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    static func acceptsFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size >= 0, size <= maxEncodedBytes else { return false }
        return true
    }

    static func readData(from url: URL) -> Data? {
        guard acceptsFile(at: url),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxEncodedBytes {
            guard !Task.isCancelled else { return nil }
            let count = min(64 * 1024, maxEncodedBytes + 1 - data.count)
            do {
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
                data.append(chunk)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// `ShouldCacheImmediately: true` is what moves the decode off the main thread:
    /// without it Image I/O produces the pixels later, on whichever thread draws.
    static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
    }

    static func allowsAnimation(width: Int, height: Int, frameCount: Int) -> Bool {
        frameCount <= maxFrameCount && isWithinPixelBudget(width: width, height: height, frameCount: frameCount)
    }

    static func isWithinPixelBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0, frameCount > 0 else { return false }
        let w = UInt64(width)
        let h = UInt64(height)
        let n = UInt64(frameCount)
        guard w <= UInt64.max / h else { return false }
        let pixelsPerFrame = w * h
        guard pixelsPerFrame <= UInt64.max / n else { return false }
        let totalPixels = pixelsPerFrame * n
        guard totalPixels <= UInt64.max / 4 else { return false }
        return totalPixels * 4 <= UInt64(maxDecodedPixelBytes)
    }

    static func imageDimensions(from source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }
}

#endif
