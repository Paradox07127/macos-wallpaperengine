#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Metal

/// The dispatcher publishes immutable uploaded pairs under the lock. The render thread
/// retains each snapshot until its final GPU reader completes; published textures are never rewritten.
final class WPEMediaTextureStore: @unchecked Sendable {
    /// A fully uploaded pair for one parity input.
    struct ParitySnapshot: @unchecked Sendable { // MTLTexture: fully uploaded before paritySnapshot publishes it, never written after
        let revision: UInt64
        let current: (any MTLTexture)?
        let previous: (any MTLTexture)?
        let currentSystemName: String?
        let previousSystemName: String?

        func texture(for kind: WPEMediaSystemTexture) -> (any MTLTexture)? {
            switch kind {
            case .thumbnail: current
            case .previousThumbnail: previous
            }
        }
    }

    private enum UploadFailure: String, Error {
        case undecodable
        case bitmapContextUnavailable
        case textureAllocationFailed
    }

    /// Author guidance is 100×100–256×256; a 4K wallpaper gains nothing from a full-resolution cover.
    static let maximumEdge = 256

    private let device: MTLDevice
    private let lock = NSLock()

    // The dispatcher owns parity artwork identity even without GPU demand. This cache holds at most its pair.
    private var parityCurrentKey: SHA256.Digest?
    private var parityPreviousKey: SHA256.Digest?
    private var parityCurrent: (any MTLTexture)?
    private var parityPrevious: (any MTLTexture)?

    init(device: MTLDevice) {
        self.device = device
    }

    /// Called on the dispatcher's MainActor after it establishes the source observation's identities.
    /// The same bytes reuse uploaded textures across reload; enabling demand can upload both known covers.
    func paritySnapshot(revision: UInt64, currentArtwork: MonitorNowPlayingArtwork?, previousArtwork: MonitorNowPlayingArtwork?,
                        currentSystemName: String?, previousSystemName: String?)
        -> (snapshot: ParitySnapshot, diagnostics: [String]) {
        let currentKey = currentArtwork?.digest
        let previousKey = previousArtwork?.digest
        lock.lock()
        var cached: [SHA256.Digest: any MTLTexture] = [:]
        if let parityCurrentKey, let parityCurrent {
            cached[parityCurrentKey] = parityCurrent
        }
        if let parityPreviousKey, let parityPrevious {
            cached[parityPreviousKey] = parityPrevious
        }
        lock.unlock()
        var diagnostics: [String] = []
        for (key, bytes) in [(previousKey, previousArtwork), (currentKey, currentArtwork)] {
            guard let key, let bytes, cached[key] == nil else { continue }
            do {
                cached[key] = try Self.uploadTexture(from: bytes.data, device: device)
            } catch {
                diagnostics.append("media.artwork-\(error.rawValue)-native-behavior-unverified")
            }
        }
        if currentArtwork != nil || previousArtwork != nil {
            diagnostics.append("media.artwork-native-sizing-unverified:mac-maximum-edge=\(Self.maximumEdge)")
        }
        lock.lock()
        defer { lock.unlock() }
        parityCurrentKey = currentKey
        parityPreviousKey = previousKey
        parityCurrent = currentKey.flatMap { cached[$0] }
        parityPrevious = previousKey.flatMap { cached[$0] }
        return (ParitySnapshot(revision: revision, current: parityCurrent, previous: parityPrevious,
                               currentSystemName: currentSystemName, previousSystemName: previousSystemName), diagnostics)
    }

    // MARK: - Upload

    /// Palette analysis can be empty for a valid transparent image. This fallback decodes no GPU resource.
    static func hasDecodableParityArtwork(_ artwork: Data) -> Bool {
        (try? thumbnailImage(from: artwork, maximumEdge: 1)) != nil
    }

    private static func thumbnailImage(from artwork: Data, maximumEdge: Int) throws(UploadFailure) -> CGImage {
        guard let source = CGImageSourceCreateWithData(artwork as CFData, nil) else { throw .undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .undecodable }
        return image
    }

    private static func uploadTexture(from artwork: Data, device: MTLDevice) throws(UploadFailure) -> MTLTexture {
        let image = try thumbnailImage(from: artwork, maximumEdge: maximumEdge)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw .bitmapContextUnavailable }

        let width = min(image.width, maximumEdge)
        let height = min(image.height, maximumEdge)
        guard width > 0, height > 0 else { throw .undecodable }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .bitmapContextUnavailable }
        // Media slots share the straight external-image contract with authored images.
        WPERasterImageAlpha.unpremultiplyRGBA8(&bytes)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw .textureAllocationFailed }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}

#endif
