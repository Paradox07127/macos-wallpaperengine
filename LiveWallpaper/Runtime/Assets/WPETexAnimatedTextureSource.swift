#if !LITE_BUILD
import Compression
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

struct WPETexAnimatedFrame {
    let texture: MTLTexture
    let sourceSubRect: CGRect?
    let duration: TimeInterval
    let samplingDescriptor: WPETexSpriteSamplingDescriptor?

    init(
        texture: MTLTexture,
        sourceSubRect: CGRect?,
        duration: TimeInterval,
        samplingDescriptor: WPETexSpriteSamplingDescriptor? = nil
    ) {
        self.texture = texture
        self.sourceSubRect = sourceSubRect
        self.duration = duration
        self.samplingDescriptor = samplingDescriptor
    }
}

/// Rebuild source for a suspended eager animation. Without one, atlases are the only copy of the frames and must never be released.
struct WPETexAnimatedAtlasProvider {
    enum Failure: Error, Equatable {
        case missingImage(Int)
        case missingMipmap(Int)
        case decompressionFailed(Int)
        case truncatedImageBytes(Int)
        case textureAllocationFailed
    }

    let payload: WPETexStreamingPayload
    private let device: MTLDevice
    private let label: String
    private let format: WPETexFormat
    private let colorSpace: WPEMetalColorSpace

    init?(
        payload: WPETexStreamingPayload, device: MTLDevice, label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) {
        guard let format = payload.info.format,
              (try? WPEMetalTextureFormatMapper.mapping(
                  for: format,
                  capabilities: WPEMetalTextureCapabilities(device: device),
                  colorSpace: colorSpace
              )) != nil else { return nil }
        self.payload = payload
        self.device = device
        self.label = label
        self.format = format
        self.colorSpace = colorSpace
    }

    func atlasDimensions(imageID: Int) -> (width: Int, height: Int)? {
        guard payload.compressedImages.indices.contains(imageID),
              let mipmap = payload.compressedImages[imageID].payloads.first else { return nil }
        return (mipmap.width, mipmap.height)
    }

    func makeAtlas(imageID: Int) throws -> MTLTexture {
        guard payload.compressedImages.indices.contains(imageID) else {
            throw Failure.missingImage(imageID)
        }
        try WPETexMipValidation.streamingImage(payload.compressedImages[imageID])
        let sourceMipmaps = payload.compressedImages[imageID].payloads
        guard !sourceMipmaps.isEmpty else { throw Failure.missingMipmap(imageID) }
        let mipmaps = try sourceMipmaps.map { mipmap in
            let bytes = try WPETexMipValidation.decodedBytes(mipmap, format: format)
            return WPETexTextureMipmap(index: mipmap.index, width: mipmap.width,
                                       height: mipmap.height, bytes: bytes)
        }
        return try WPEMetalTextureLoader.makeTextureSynchronously(
            from: WPETexTexturePayload(info: payload.info, mipmaps: mipmaps, hasAnimationFrames: false),
            label: "\(label) image \(imageID)", device: device,
            capabilities: WPEMetalTextureCapabilities(device: device),
            colorSpace: colorSpace, preserveMipmaps: true
        )
    }


}

extension WPETexCompressedMipmap {
    /// Anti-OOM cap on an untrusted `decompressedByteCount`; same 256 MB ceiling as
    /// `WPETexDecoder.inflateIfNeeded`, without its per-format `expectedByteCount` clamp.
    static let maxDecompressedByteCount = 268_435_456

    /// LZ4-raw inflate to exactly `decompressedByteCount` bytes; nil on an out-of-range
    /// size or a short decode.
    func lz4Inflated() -> Data? {
        let outputCount = decompressedByteCount
        guard outputCount > 0, outputCount <= Self.maxDecompressedByteCount else { return nil }
        var output = Data(count: outputCount)
        let written = output.withUnsafeMutableBytes { outRaw -> Int in
            compressedBytes.withUnsafeBytes { srcRaw -> Int in
                guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(dst, outputCount, src, srcRaw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == outputCount ? output : nil
    }
}

enum WPETexFrameTimeline {
    static func frameIndex(
        at time: TimeInterval,
        frameCount: Int,
        frameStartTimes: [TimeInterval],
        totalDuration: TimeInterval,
        loop: Bool
    ) -> Int {
        guard frameCount > 0 else { return 0 }
        let bounded: TimeInterval
        if loop {
            let positive = max(time, 0)
            bounded = totalDuration > 0 ? positive.truncatingRemainder(dividingBy: totalDuration) : 0
        } else {
            bounded = min(max(time, 0), max(totalDuration - .ulpOfOne, 0))
        }

        var lo = 0
        var hi = frameStartTimes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let start = frameStartTimes[mid]
            let next = mid + 1 < frameStartTimes.count ? frameStartTimes[mid + 1] : totalDuration
            if bounded < start {
                hi = mid - 1
            } else if bounded >= next {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return max(min(lo, frameCount - 1), 0)
    }
}

final class WPETexAnimatedTextureSource: WPEDynamicTextureSource {
    private struct FrameMetadata {
        let atlasSlot: Int
        let sourceSubRect: CGRect?
        let samplingDescriptor: WPETexSpriteSamplingDescriptor?
    }

    /// One entry per unique atlas texture. Dimensions are captured at init so
    /// sprite-sheet UVs stay computable while the texture is released.
    private struct AtlasSlot {
        var texture: MTLTexture?
        let width: Int
        let height: Int
        var imageID: Int?
    }

    private let frameMetadata: [FrameMetadata]
    private var atlasSlots: [AtlasSlot]
    private let frameStartTimes: [TimeInterval]
    private let totalDuration: TimeInterval
    private let frameRate: Double
    private let loop: Bool
    private var atlasProvider: WPETexAnimatedAtlasProvider?
    private var atlasesReleased = false
    private var restoreFailureLogged = false
    private var externallyHeldSlots: Set<Int> = []

    init(frames: [WPETexAnimatedFrame], frameRate: Double, loop: Bool) {
        self.frameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = loop

        // The eager loader uploads one texture per unique imageID and hands the
        // same instance to every frame that shares it, so identity recovers the
        // atlas partition without the loader passing image IDs down.
        var slots: [AtlasSlot] = []
        var slotByTexture: [ObjectIdentifier: Int] = [:]
        var metadata: [FrameMetadata] = []
        metadata.reserveCapacity(frames.count)
        for frame in frames {
            let key = ObjectIdentifier(frame.texture as AnyObject)
            let slot: Int
            if let existing = slotByTexture[key] {
                slot = existing
            } else {
                slot = slots.count
                slots.append(AtlasSlot(
                    texture: frame.texture,
                    width: frame.texture.width,
                    height: frame.texture.height,
                    imageID: nil
                ))
                slotByTexture[key] = slot
            }
            metadata.append(FrameMetadata(
                atlasSlot: slot,
                sourceSubRect: frame.sourceSubRect,
                samplingDescriptor: frame.samplingDescriptor
            ))
        }
        self.atlasSlots = slots
        self.frameMetadata = metadata

        let fallbackDuration = 1.0 / self.frameRate
        var cursor: TimeInterval = 0
        var starts: [TimeInterval] = []
        starts.reserveCapacity(frames.count)
        for frame in frames {
            starts.append(cursor)
            cursor += frame.duration > 0 ? frame.duration : fallbackDuration
        }
        self.frameStartTimes = starts
        self.totalDuration = cursor > 0
            ? cursor
            : Double(frames.count) * fallbackDuration
    }

    convenience init(frames: [MTLTexture], frameRate: Double, loop: Bool) {
        let safeFrameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        let duration = 1.0 / safeFrameRate
        self.init(
            frames: frames.map { texture in
                WPETexAnimatedFrame(texture: texture, sourceSubRect: nil, duration: duration)
            },
            frameRate: safeFrameRate,
            loop: loop
        )
    }

    // MARK: - Suspend / restore

    /// Attaches the rebuild source. Rejected — and release therefore stays off —
    /// unless the streaming schedule lines up one-to-one with the eager frames
    /// and each atlas maps to exactly one image: a mismatch would silently
    /// restore the wrong image for a frame.
    @discardableResult
    func attachAtlasProvider(_ provider: WPETexAnimatedAtlasProvider) -> Bool {
        let streamingFrames = provider.payload.frames
        guard !atlasSlots.isEmpty, streamingFrames.count == frameMetadata.count else { return false }
        var imageIDBySlot: [Int: Int] = [:]
        for (index, metadata) in frameMetadata.enumerated() {
            let imageID = streamingFrames[index].imageID
            if let existing = imageIDBySlot[metadata.atlasSlot] {
                guard existing == imageID else { return false }
            } else {
                guard provider.payload.compressedImages.indices.contains(imageID) else { return false }
                imageIDBySlot[metadata.atlasSlot] = imageID
            }
        }
        guard imageIDBySlot.count == atlasSlots.count,
              Set(imageIDBySlot.values).count == imageIDBySlot.count else { return false }
        for (slot, imageID) in imageIDBySlot {
            guard let dimensions = provider.atlasDimensions(imageID: imageID),
                  dimensions.width == atlasSlots[slot].width,
                  dimensions.height == atlasSlots[slot].height else { return false }
        }
        for (slot, imageID) in imageIDBySlot {
            atlasSlots[slot].imageID = imageID
        }
        atlasProvider = provider
        return true
    }

    /// True between `.suspended` and the next `texture(at:)`. The renderer uses
    /// it to drop its own binding — the atlas is not freed while `loadedTextures`
    /// still holds the last one this source handed out.
    var hasReleasedAtlases: Bool { atlasesReleased }

    var residentAtlasGPUBytes: Int {
        atlasSlots.reduce(0) { total, slot in
            guard let texture = slot.texture else { return total }
            return total + WPEMetalTextureByteEstimator.estimatedBytes(of: texture)
        }
    }

    /// Pinned slots are never released: nilling our reference would not free an external holder and restore would allocate a second copy.
    func pinSlotHoldingExternally(textureFor time: TimeInterval) {
        guard !frameMetadata.isEmpty else { return }
        externallyHeldSlots.insert(frameMetadata[frameIndex(at: time)].atlasSlot)
    }

    private func releaseAtlases() {
        guard atlasProvider != nil, !atlasesReleased else { return }
        for index in atlasSlots.indices where !externallyHeldSlots.contains(index) {
            atlasSlots[index].texture = nil
        }
        atlasesReleased = true
    }

    private func restoreAtlases() {
        guard let provider = atlasProvider else {
            atlasesReleased = false
            return
        }
        var allSucceeded = true
        defer {
            // Only a complete rebuild clears the flag: clearing it up front would latch a transient allocation failure and never retry.
            atlasesReleased = !allSucceeded
        }
        for index in atlasSlots.indices {
            guard atlasSlots[index].texture == nil,
                  let imageID = atlasSlots[index].imageID else { continue }
            do {
                atlasSlots[index].texture = try provider.makeAtlas(imageID: imageID)
            } catch {
                allSucceeded = false
                if !restoreFailureLogged {
                    restoreFailureLogged = true
                    Logger.warning(
                        "WPE eager .tex atlas restore failed for image \(imageID): \(error)",
                        category: .screenManager
                    )
                }
            }
        }
    }

    // MARK: - Playback

    func texture(at time: TimeInterval) -> MTLTexture? {
        guard !frameMetadata.isEmpty else { return nil }
        if atlasesReleased { restoreAtlases() }
        return atlasSlots[frameMetadata[frameIndex(at: time)].atlasSlot].texture
    }

    func samplingDescriptor(
        at time: TimeInterval,
        frameSlot _: Int
    ) -> WPETexSpriteSamplingDescriptor? {
        guard !frameMetadata.isEmpty else { return nil }
        return frameMetadata[frameIndex(at: time)].samplingDescriptor
    }

    /// TEXS frame rate for particle sprite sheets without a .tex-json sidecar.
    var spriteSheetFrameRate: Double { frameRate }

    /// Per-frame UV sub-rects for particle sprite sheets; [] if any frame lacks one.
    func spriteSheetFrameRectsNormalized() -> [SIMD4<Float>] {
        guard !frameMetadata.isEmpty else { return [] }
        var rects: [SIMD4<Float>] = []
        rects.reserveCapacity(frameMetadata.count)
        for metadata in frameMetadata {
            guard let rect = metadata.sourceSubRect else { return [] }
            let slot = atlasSlots[metadata.atlasSlot]
            let atlasWidth = CGFloat(max(slot.width, 1))
            let atlasHeight = CGFloat(max(slot.height, 1))
            rects.append(SIMD4<Float>(
                Float(rect.minX / atlasWidth), Float(rect.minY / atlasHeight),
                Float(rect.maxX / atlasWidth), Float(rect.maxY / atlasHeight)
            ))
        }
        return rects
    }

    func frameIndex(at time: TimeInterval) -> Int {
        WPETexFrameTimeline.frameIndex(
            at: time,
            frameCount: frameMetadata.count,
            frameStartTimes: frameStartTimes,
            totalDuration: totalDuration,
            loop: loop
        )
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .suspended:
            releaseAtlases()
        case .quality:
            // Restore is lazy: the first frame after resume re-uploads before it
            // binds, so there is never a window where `texture(at:)` is nil.
            break
        }
    }

    func invalidate() {
        releaseAtlases()
    }
}
#endif
