#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO


/// `mediaThumbnailChanged`'s event payload. Colours are sRGB, 0...1 — the same
/// space the pixels were sampled in, and the space scene colours are authored in.
/// The Scene-side event carries no bitmap (unlike the Web API); album art
/// reaches scenes as the `$mediaThumbnail` system texture instead.
struct WPESceneMediaThumbnail: Sendable, Equatable {
    var hasThumbnail: Bool
    var primaryColor: SIMD3<Double>
    var secondaryColor: SIMD3<Double>
    var tertiaryColor: SIMD3<Double>
    var textColor: SIMD3<Double>
    var highContrastColor: SIMD3<Double>

    /// No artwork. Black accents with white text: the contrast pairing for a black primary.
    static let absent = WPESceneMediaThumbnail(
        hasThumbnail: false,
        primaryColor: SIMD3(0, 0, 0),
        secondaryColor: SIMD3(0, 0, 0),
        tertiaryColor: SIMD3(0, 0, 0),
        textColor: SIMD3(1, 1, 1),
        highContrastColor: SIMD3(1, 1, 1)
    )
}

enum WPEMediaArtworkPalette {
    /// Analysis resolution: 32² = 1024 samples to settle dominant hues.
    static let analysisSize = 32

    /// Below this saturation a pixel is near-neutral and excluded from the dominant vote unless the image has nothing else.
    private static let neutralSaturation = 0.18
    private static let neutralValueFloor = 0.10
    /// Minimum RGB distance between the three reported dominants, so we never
    /// hand a scene three shades of the same colour.
    private static let minimumSeparation = 0.25

    /// nil when the bytes are not a decodable image.
    static func palette(from artwork: Data) -> WPESceneMediaThumbnail? {
        guard let pixels = samplePixels(artwork) else { return nil }
        let dominants = dominantColors(pixels)
        guard let primary = dominants.first else { return nil }
        let secondary = dominants.count > 1 ? dominants[1] : shifted(primary, by: 0.45)
        let tertiary = dominants.count > 2 ? dominants[2] : shifted(primary, by: 0.75)
        let contrast = highContrastColor(against: primary)
        return WPESceneMediaThumbnail(
            hasThumbnail: true,
            primaryColor: primary,
            secondaryColor: secondary,
            tertiaryColor: tertiary,
            // Black or white maximizes contrast with primary; anything cleverer would be invented.
            textColor: contrast,
            highContrastColor: contrast
        )
    }

    // MARK: - Contrast (the one part that IS specified)

    /// WCAG relative luminance over sRGB components.
    static func relativeLuminance(_ color: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    static func contrastRatio(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func highContrastColor(against primary: SIMD3<Double>) -> SIMD3<Double> {
        let white = SIMD3<Double>(1, 1, 1)
        let black = SIMD3<Double>(0, 0, 0)
        return contrastRatio(primary, white) >= contrastRatio(primary, black) ? white : black
    }

    // MARK: - Dominant colours

    private static func dominantColors(_ pixels: [SIMD4<Double>]) -> [SIMD3<Double>] {
        struct Bucket {
            var weight = 0.0
            var sum = SIMD3<Double>()
        }
        var chromatic: [Int: Bucket] = [:]
        var neutral: [Int: Bucket] = [:]

        for pixel in pixels {
            let rgb = SIMD3(pixel.x, pixel.y, pixel.z)
            let high = max(rgb.x, max(rgb.y, rgb.z))
            let low = min(rgb.x, min(rgb.y, rgb.z))
            let saturation = high > 0 ? (high - low) / high : 0
            // 4 bits per channel: 4096 buckets, coarse enough that a gradient
            // votes as one colour and fine enough to keep hues apart.
            let key = (Int(rgb.x * 15 + 0.5) << 8) | (Int(rgb.y * 15 + 0.5) << 4) | Int(rgb.z * 15 + 0.5)
            let isNeutral = saturation < neutralSaturation || high < neutralValueFloor
            // Squared saturation: a small vivid accent outvotes a large washed-out field.
            let weight = isNeutral ? 1.0 : saturation * saturation
            var bucket = (isNeutral ? neutral[key] : chromatic[key]) ?? Bucket()
            bucket.weight += weight
            bucket.sum += rgb * weight
            if isNeutral { neutral[key] = bucket } else { chromatic[key] = bucket }
        }

        // A genuinely monochrome cover has no chromatic pixels at all; falling
        // back to the neutral vote beats reporting the no-artwork colours.
        let source = chromatic.isEmpty ? neutral : chromatic
        // Tie-break on the bucket key so the ranking is stable, not dictionary order.
        let ranked = source
            .sorted { lhs, rhs in
                lhs.value.weight == rhs.value.weight
                    ? lhs.key < rhs.key
                    : lhs.value.weight > rhs.value.weight
            }
            .map { $0.value.sum / $0.value.weight }

        var picked: [SIMD3<Double>] = []
        for candidate in ranked {
            guard picked.allSatisfy({ distance($0, candidate) >= minimumSeparation }) else { continue }
            picked.append(candidate)
            if picked.count == 3 { break }
        }
        return picked
    }

    private static func distance(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let d = lhs - rhs
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// Stand-in when there is no 2nd/3rd colour: move primary away from its luminance pole so it never collapses to black-on-black.
    private static func shifted(_ primary: SIMD3<Double>, by amount: Double) -> SIMD3<Double> {
        let target: SIMD3<Double> = relativeLuminance(primary) > 0.5
            ? SIMD3(0, 0, 0)
            : SIMD3(1, 1, 1)
        return primary + (target - primary) * amount
    }

    // MARK: - Decode

    /// Straight-alpha sRGB samples, `analysisSize` squared. ImageIO produces the
    /// thumbnail directly so the full-size bitmap is never decoded.
    private static func samplePixels(_ artwork: Data) -> [SIMD4<Double>]? {
        guard let source = CGImageSourceCreateWithData(artwork as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let side = analysisSize
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var pixels: [SIMD4<Double>] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            // Transparent padding is not part of the art; it would otherwise vote
            // as black through the premultiplied buffer.
            guard alpha >= 0.5 else { continue }
            pixels.append(SIMD4(
                Double(bytes[index]) / 255 / alpha,
                Double(bytes[index + 1]) / 255 / alpha,
                Double(bytes[index + 2]) / 255 / alpha,
                alpha
            ))
        }
        return pixels.isEmpty ? nil : pixels
    }
}

/// Keyed on a digest of the bytes: trackID alone is not enough and Data's hash is not stable across launches.
struct WPEMediaArtworkPaletteCache {
    private var key: String?
    private var cached = WPESceneMediaThumbnail.absent

    mutating func thumbnail(for artwork: Data?) -> WPESceneMediaThumbnail {
        guard let artwork, !artwork.isEmpty else {
            key = nil
            cached = .absent
            return .absent
        }
        let identity = Self.identity(of: artwork)
        if identity == key { return cached }
        key = identity
        cached = WPEMediaArtworkPalette.palette(from: artwork) ?? .absent
        return cached
    }

    static func identity(of artwork: Data) -> String {
        SHA256.hash(data: artwork).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
