import SwiftUI
import ImageIO
import CoreGraphics

// MARK: - Accent extraction (pure)

/// Dominant-color result in display sRGB; components stay inspectable for tests.
struct NowPlayingAccentColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

enum NowPlayingAccent {
    /// Downsample → saturation-weighted hue histogram → readability floor.
    /// Returns nil for effectively monochrome artwork (caller falls back).
    nonisolated static func dominantColor(in data: Data) -> NowPlayingAccentColor? {
        guard let pixels = downsampledRGBA(data, side: 32) else { return nil }

        let bucketCount = 12
        var weight = [Double](repeating: 0, count: bucketCount)
        var sumR = [Double](repeating: 0, count: bucketCount)
        var sumG = [Double](repeating: 0, count: bucketCount)
        var sumB = [Double](repeating: 0, count: bucketCount)
        var pixelCount = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            pixelCount += 1
            let v = max(r, g, b)
            let delta = v - min(r, g, b)
            guard v > 0.08, delta > 0.001 else { continue }  // black / pure gray carry no hue
            let s = delta / v
            let bucket = Int(hue(r: r, g: g, b: b, v: v, delta: delta) / 360 * Double(bucketCount)) % bucketCount
            // Saturation-weighted so vivid regions beat large washed-out ones.
            let w = s * s * (0.25 + 0.75 * v)
            weight[bucket] += w
            sumR[bucket] += r * w
            sumG[bucket] += g * w
            sumB[bucket] += b * w
        }

        guard pixelCount > 0,
              let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > pixelCount * 0.015   // grayscale art: no bucket accumulates weight
        else { return nil }

        var r = sumR[best] / weight[best]
        var g = sumG[best] / weight[best]
        var b = sumB[best] / weight[best]

        // Readability floor against arbitrary wallpapers: lift dark picks.
        let brightness = max(r, g, b)
        if brightness < 0.55, brightness > 0 {
            let lift = 0.55 / brightness
            r = min(r * lift, 1)
            g = min(g * lift, 1)
            b = min(b * lift, 1)
        }
        return NowPlayingAccentColor(red: r, green: g, blue: b)
    }

    private nonisolated static func hue(r: Double, g: Double, b: Double, v: Double, delta: Double) -> Double {
        var h: Double
        if v == r { h = (g - b) / delta }
        else if v == g { h = 2 + (b - r) / delta }
        else { h = 4 + (r - g) / delta }
        h *= 60
        if h < 0 { h += 360 }
        return h.isFinite ? min(h, 359.999) : 0
    }

    private nonisolated static func downsampledRGBA(_ data: Data, side: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let w = min(image.width, side), h = min(image.height, side)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }
}

// MARK: - Accent store (per-track cache; misses cached too)

@MainActor
final class NowPlayingAccentStore {
    static let shared = NowPlayingAccentStore()

    private let extract: @Sendable (Data) -> NowPlayingAccentColor?
    private var cache: [String: NowPlayingAccentColor?] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<NowPlayingAccentColor?, Never>] = [:]
    private let capacity = 16
    /// Test seam: how many times the extractor actually ran (cache hits must not add).
    private(set) var extractionCount = 0

    init(extract: @escaping @Sendable (Data) -> NowPlayingAccentColor? = NowPlayingAccent.dominantColor(in:)) {
        self.extract = extract
    }

    func accent(for key: String, data: Data) async -> NowPlayingAccentColor? {
        if let hit = cache[key] { return hit }
        if let pending = inFlight[key] { return await pending.value }
        extractionCount += 1
        let extract = self.extract
        let task = Task.detached(priority: .utility) { extract(data) }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        store(value, for: key)
        return value
    }

    private func store(_ value: NowPlayingAccentColor?, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = value
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}
