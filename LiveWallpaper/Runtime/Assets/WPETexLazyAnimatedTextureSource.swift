#if !LITE_BUILD
import Compression
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os

/// On-demand multi-frame `.tex`: LZ4 in CPU RAM, crop + upload to rotating MTLTexture (BC stays compressed).
/// Not `@MainActor`; prefetch writes Sendable lock-boxes harvested on the render actor.
final class WPETexLazyAnimatedTextureSource: WPEDynamicTextureSource {
    /// Off-thread prefetch result; harvested on the render actor.
    private enum PrefetchOutcome: Sendable {
        case pending
        case done(Data?)
    }

    enum Failure: Error, Equatable, Sendable {
        case missingFrames
        case unsupportedFormat(Int)
        case missingCompressedImage(Int)
        case missingMipmap(Int)
        case decompressionFailed(Int)
        case textureAllocationFailed
        case textureDimensionsExceedDeviceLimit(width: Int, height: Int, limit: Int)
        case truncatedImageBytes
        case subRectNotBlockAligned(CGRect, blockSize: Int)
    }

    private let frames: [WPETexStreamingFrame]
    private let compressedImages: [WPETexCompressedImage]
    private let frameRate: Double
    private let loop: Bool
    private let device: MTLDevice
    private let label: String
    private let mapping: WPEMetalTextureFormatMapping
    private let alphaChannelPriorityRG88: Bool
    private let maximumTextureDimension2D: Int
    private let frameStartTimes: [TimeInterval]
    private let totalDuration: TimeInterval
    /// Off-main LZ4 prefetch (`.userInitiated`) so loop-seam decode stays off the render thread.
    private let prefetchQueue = DispatchQueue(
        label: "com.livewallpaper.wpe.lazy-tex-prefetch",
        qos: .userInitiated
    )

    private struct WorkingTextureSlot {
        var texture: MTLTexture?
        var width = 0
        var height = 0
        var lastUploadedFrameIndex = -1
    }

    /// One upload target per admitted frame — replace(region:) must not overwrite in-flight samples.
    private var workingTextureSlots = Array(
        repeating: WorkingTextureSlot(),
        count: WPEMetalRenderExecutor.maxFramesInFlight
    )
    /// Process-wide decoded-frame byte budget (shared across all lazy sources).
    private let frameByteCache: WPEAnimatedFrameByteCache
    private let cacheToken: WPEAnimatedFrameByteCache.SourceToken
    /// Reusable sub-rect crop target per frame slot — steady state allocates
    /// nothing per frame (the slot's texture.replace copies out synchronously).
    private var cropScratchSlots = Array(
        repeating: Data(),
        count: WPEMetalRenderExecutor.maxFramesInFlight
    )
    /// In-flight prefetch jobs (dedup + bounded backlog; drop when leaving look-ahead).
    private var prefetchJobs: [Int: (item: DispatchWorkItem, box: OSAllocatedUnfairLock<PrefetchOutcome>)] = [:]
    /// Failed image IDs — never re-scheduled (corrupt frame thrash guard).
    private var prefetchFailedImageIDs: Set<Int> = []
    /// Current look-ahead set; completions outside it are stale and dropped.
    private var prefetchWantedImageIDs: Set<Int> = []
    private var lastScheduledFrameIndex = -1
    private var lastErrorDescription: String?
    /// Prefetch completion pump → harvest immediately (renderer installs actor hop).
    var onPrefetchComplete: (@Sendable () -> Void)?

#if DEBUG
    var debugPrefetchDecodeDelay: TimeInterval = 0
    private(set) var debugSynchronousDecodedImageIDs: [Int] = []
    // Probes harvest first so tests without a completion pump see finished decodes.
    var debugDecodedImageCacheIDs: Set<Int> {
        harvestCompletedPrefetches()
        return frameByteCache.imageIDs(for: cacheToken)
    }
    var debugPrefetchInFlightImageIDs: Set<Int> {
        harvestCompletedPrefetches()
        return Set(prefetchJobs.keys)
    }
    var debugPrefetchFailedImageIDs: Set<Int> {
        harvestCompletedPrefetches()
        return prefetchFailedImageIDs
    }
#endif

    /// Distinct upcoming source images to keep warm (wrap-aware, by image not frame).
    private static let decodedImagePrefetchLookahead = 2
        /// Anti-OOM hard cap on `Data(count:)` for an untrusted `decompressedByteCount`; mirrors
        /// the eager path's cap (WPETexDecoder.swift:922, 256 MB).
        private static let maxDecompressedByteCount = 268_435_456

    init(
        payload: WPETexStreamingPayload,
        device: MTLDevice,
        label: String,
        capabilities: WPEMetalTextureCapabilities? = nil,
        maximumTextureDimension2D: Int? = nil,
        frameByteCache: WPEAnimatedFrameByteCache = .shared
    ) throws {
        guard !payload.frames.isEmpty else { throw Failure.missingFrames }
        guard let format = payload.info.format else {
            throw Failure.unsupportedFormat(payload.info.textureFormatCode)
        }
        let caps = capabilities ?? WPEMetalTextureCapabilities(device: device)
        do {
            self.mapping = try WPEMetalTextureFormatMapper.mapping(for: format, capabilities: caps)
        } catch {
            throw Failure.unsupportedFormat(payload.info.textureFormatCode)
        }
        self.alphaChannelPriorityRG88 = WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(
            isLuminanceAlpha: payload.info.isRG88LuminanceAlpha,
            label: label
        )
        self.frames = payload.frames
        self.compressedImages = payload.compressedImages
        self.frameRate = payload.frameRate > 0 ? payload.frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = payload.loop
        self.device = device
        self.label = label
        self.maximumTextureDimension2D = maximumTextureDimension2D
            ?? WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
        self.frameByteCache = frameByteCache
        self.cacheToken = frameByteCache.registerSource()

        var cursor: TimeInterval = 0
        var starts: [TimeInterval] = []
        starts.reserveCapacity(payload.frames.count)
        for frame in payload.frames {
            starts.append(cursor)
            cursor += frame.duration > 0 ? frame.duration : 1.0 / self.frameRate
        }
        self.frameStartTimes = starts
        self.totalDuration = cursor > 0 ? cursor : Double(payload.frames.count) / self.frameRate
    }

    deinit {
        // Return the process-cache lease; entries must not outlive the source.
        frameByteCache.unregisterSource(cacheToken)
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        texture(at: time, frameSlot: 0)
    }

    func texture(at time: TimeInterval, frameSlot: Int) -> MTLTexture? {
        precondition(workingTextureSlots.indices.contains(frameSlot))
        let index = frameIndex(at: time)
        defer { scheduleDecodedImagePrefetch(after: index) }
        if index == workingTextureSlots[frameSlot].lastUploadedFrameIndex {
            return workingTextureSlots[frameSlot].texture
        }

        do {
            let frame = frames[index]
            let image = try decodedImage(for: frame.imageID)
            let cropped = try crop(image: image, frame: frame, frameSlot: frameSlot)
            let texture = try textureForUpload(
                width: cropped.width,
                height: cropped.height,
                frameSlot: frameSlot
            )
            cropped.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, cropped.width, cropped.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: cropped.bytesPerRow
                )
            }
            workingTextureSlots[frameSlot].lastUploadedFrameIndex = index
            return texture
        } catch {
            let message = "\(error)"
            if lastErrorDescription != message {
                lastErrorDescription = message
                Logger.warning("WPE lazy .tex upload failed for \(label): \(message)", category: .screenManager)
            }
            return workingTextureSlots[frameSlot].texture
        }
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
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
        return max(min(lo, frames.count - 1), 0)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        _ = profile
    }

    func invalidate() {
        workingTextureSlots = Array(
            repeating: WorkingTextureSlot(),
            count: WPEMetalRenderExecutor.maxFramesInFlight
        )
        cropScratchSlots = Array(
            repeating: Data(),
            count: WPEMetalRenderExecutor.maxFramesInFlight
        )
        frameByteCache.removeAll(for: cacheToken)
        // Cancel in-flight jobs; orphaned boxes are never harvested.
        for job in prefetchJobs.values { job.item.cancel() }
        prefetchJobs.removeAll(keepingCapacity: false)
        prefetchFailedImageIDs.removeAll(keepingCapacity: false)
        prefetchWantedImageIDs.removeAll(keepingCapacity: false)
        lastScheduledFrameIndex = -1
    }

    // MARK: - Decode + crop

    private func decodedImage(for imageID: Int) throws -> Data {
        // Prefetch may already have completed off-thread.
        harvestCompletedPrefetches()
        if let cached = frameByteCache.lookup(source: cacheToken, imageID: imageID) {
            return cached
        }
        guard compressedImages.indices.contains(imageID) else {
            throw Failure.missingCompressedImage(imageID)
        }
        guard let mipmap = compressedImages[imageID].payloads.first else {
            throw Failure.missingMipmap(imageID)
        }

        // Prefetch miss: cancel in-flight job and decode synchronously (rare).
        cancelPrefetch(for: imageID)
        let decoded: Data
        do {
            decoded = try Self.decodedBytes(from: mipmap)
        } catch {
            prefetchFailedImageIDs.insert(imageID)
            throw error
        }
#if DEBUG
        debugSynchronousDecodedImageIDs.append(imageID)
#endif
        // Pin before store so the concurrent prune from another source's
        // admission cannot evict the frame we are about to upload. Oversize
        // frames stay out of the cache (upload-and-release).
        frameByteCache.pin(source: cacheToken, imageID: imageID)
        frameByteCache.store(decoded, source: cacheToken, imageID: imageID, speculative: false)
        return decoded
    }

    /// Prefetch next distinct images (wrap-aware); cancel jobs that left the window.
    private func scheduleDecodedImagePrefetch(after frameIndex: Int) {
        // Harvest completed decodes every tick (even if frame index unchanged).
        harvestCompletedPrefetches()
        guard frameIndex != lastScheduledFrameIndex else { return }
        lastScheduledFrameIndex = frameIndex

        let wanted = prefetchImageIDs(after: frameIndex)
        prefetchWantedImageIDs = Set(wanted)

        // Cancel jobs outside look-ahead (collect first — don't mutate while iterating).
        let staleImageIDs = prefetchJobs.keys.filter { !prefetchWantedImageIDs.contains($0) }
        for imageID in staleImageIDs {
            prefetchJobs.removeValue(forKey: imageID)?.item.cancel()
        }

        for imageID in wanted {
            guard !frameByteCache.contains(source: cacheToken, imageID: imageID),
                  prefetchJobs[imageID] == nil,
                  !prefetchFailedImageIDs.contains(imageID),
                  compressedImages.indices.contains(imageID),
                  let mipmap = compressedImages[imageID].payloads.first,
                  // Oversize frames never prefetch: they cannot enter the
                  // cache, so a speculative decode would be thrown away.
                  mipmap.decompressedByteCount <= frameByteCache.admissionByteCap
            else { continue }

#if DEBUG
            let delay = debugPrefetchDecodeDelay
#endif
            // Capture only Sendable values (never self); render actor harvests later.
            let box = OSAllocatedUnfairLock<PrefetchOutcome>(initialState: .pending)
            let pump = onPrefetchComplete
            let item = DispatchWorkItem { @Sendable in
#if DEBUG
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
#endif
                let decoded = try? Self.decodedBytes(from: mipmap)
                box.withLock { $0 = .done(decoded) }
                // Harvest now via owner hop (pre-3c contract tests lock).
                pump?()
            }
            prefetchJobs[imageID] = (item, box)
            prefetchQueue.async(execute: item)
        }
    }

    /// Fold completed prefetches into cache; drop stale/failed results.
    func harvestCompletedPrefetches() {
        guard !prefetchJobs.isEmpty else { return }
        for (imageID, job) in prefetchJobs {
            guard case .done(let decoded) = job.box.withLock({ $0 }) else { continue }
            prefetchJobs.removeValue(forKey: imageID)
            guard let decoded else {
                // Record failure so it is never re-scheduled.
                prefetchFailedImageIDs.insert(imageID)
                continue
            }
            // Drop stale results so they can't LRU-evict current/next.
            guard prefetchWantedImageIDs.contains(imageID),
                  !frameByteCache.contains(source: cacheToken, imageID: imageID) else { continue }
            frameByteCache.store(decoded, source: cacheToken, imageID: imageID, speculative: true)
        }
    }

    /// Next distinct uncached image IDs after frameIndex (≤ one full loop).
    private func prefetchImageIDs(after frameIndex: Int) -> [Int] {
        guard !frames.isEmpty, Self.decodedImagePrefetchLookahead > 0 else { return [] }

        var imageIDs: [Int] = []
        var seen: Set<Int> = []
        for offset in 1...frames.count {
            let rawIndex = frameIndex + offset
            let targetIndex: Int
            if rawIndex < frames.count {
                targetIndex = rawIndex
            } else if loop {
                targetIndex = rawIndex % frames.count
            } else {
                break
            }
            let imageID = frames[targetIndex].imageID
            guard seen.insert(imageID).inserted,
                  !frameByteCache.contains(source: cacheToken, imageID: imageID) else { continue }
            imageIDs.append(imageID)
            if imageIDs.count == Self.decodedImagePrefetchLookahead { break }
        }
        return imageIDs
    }

    private func cancelPrefetch(for imageID: Int) {
        prefetchJobs.removeValue(forKey: imageID)?.item.cancel()
    }

    private nonisolated static func decodedBytes(from mipmap: WPETexCompressedMipmap) throws -> Data {
        if mipmap.isCompressed {
            return try inflate(mipmap)
        }
        guard mipmap.compressedBytes.count >= mipmap.decompressedByteCount else {
            throw Failure.truncatedImageBytes
        }
        return mipmap.compressedBytes.prefix(mipmap.decompressedByteCount).materializedData()
    }

    private nonisolated static func inflate(_ mipmap: WPETexCompressedMipmap) throws -> Data {
            // decompressedByteCount is read straight off an untrusted .tex payload. Cap it before
            // allocating, same as the eager path (WPETexDecoder.inflateIfNeeded, 256 MB). That path
            // also clamps to a per-format expected size, but the format mapping isn't in scope for
            // this static helper — the fixed ceiling alone already bounds worst-case allocation.
        let outputCount = mipmap.decompressedByteCount
            guard outputCount > 0, outputCount <= maxDecompressedByteCount else {
                throw Failure.decompressionFailed(mipmap.index)
            }
        var output = Data(count: outputCount)
        let written = output.withUnsafeMutableBytes { outRaw -> Int in
            mipmap.compressedBytes.withUnsafeBytes { srcRaw -> Int in
                guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(
                    dst, outputCount,
                    src, srcRaw.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == outputCount else { throw Failure.decompressionFailed(mipmap.index) }
        return output
    }

    private struct Cropped {
        let bytes: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    /// Crop sub-rect (row copy or 4×4 BC blocks). Non-block-aligned BC rects throw.
    /// A frame covering the whole image uploads the decoded buffer directly —
    /// no second full-frame copy (P1.4); sub-rects reuse a per-slot scratch.
    private func crop(image: Data, frame: WPETexStreamingFrame, frameSlot: Int) throws -> Cropped {
        guard compressedImages.indices.contains(frame.imageID),
              let mipmap = compressedImages[frame.imageID].payloads.first else {
            throw Failure.missingCompressedImage(frame.imageID)
        }
        let rect = pixelRect(frame.subRect, width: mipmap.width, height: mipmap.height)
        try validateTextureDimensions(width: rect.width, height: rect.height)
        let coversFullImage = rect.x == 0 && rect.y == 0
            && rect.width == mipmap.width && rect.height == mipmap.height

        if let bytesPerPixel = mapping.bytesPerPixel {
            let sourceBytesPerRow = mipmap.width * bytesPerPixel
            guard image.count >= sourceBytesPerRow * mipmap.height else {
                throw Failure.truncatedImageBytes
            }
            if coversFullImage {
                return Cropped(bytes: image, width: rect.width, height: rect.height, bytesPerRow: sourceBytesPerRow)
            }
            let outputBytesPerRow = rect.width * bytesPerPixel
            var output = takeCropScratch(slot: frameSlot, byteCount: outputBytesPerRow * rect.height)
            image.withUnsafeBytes { srcRaw in
                output.withUnsafeMutableBytes { dstRaw in
                    guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                          let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for row in 0..<rect.height {
                        let srcOffset = (rect.y + row) * sourceBytesPerRow + rect.x * bytesPerPixel
                        let dstOffset = row * outputBytesPerRow
                        dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerRow)
                    }
                }
            }
            cropScratchSlots[frameSlot] = output
            return Cropped(bytes: output, width: rect.width, height: rect.height, bytesPerRow: outputBytesPerRow)
        }

        guard let bytesPerBlock = mapping.bytesPerBlock else {
            throw Failure.unsupportedFormat(0)
        }
        let blockSize = 4
        guard rect.x % blockSize == 0,
              rect.y % blockSize == 0,
              rect.width % blockSize == 0,
              rect.height % blockSize == 0 else {
            throw Failure.subRectNotBlockAligned(
                CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                blockSize: blockSize
            )
        }
        let sourceBlocksX = max((mipmap.width + blockSize - 1) / blockSize, 1)
        let sourceBlocksY = max((mipmap.height + blockSize - 1) / blockSize, 1)
        let cropBlocksX = rect.width / blockSize
        let cropBlocksY = rect.height / blockSize
        let originBlockX = rect.x / blockSize
        let originBlockY = rect.y / blockSize
        let sourceBytesPerBlockRow = sourceBlocksX * bytesPerBlock
        let outputBytesPerBlockRow = cropBlocksX * bytesPerBlock
        guard image.count >= sourceBytesPerBlockRow * sourceBlocksY else {
            throw Failure.truncatedImageBytes
        }
        if coversFullImage {
            return Cropped(bytes: image, width: rect.width, height: rect.height, bytesPerRow: sourceBytesPerBlockRow)
        }
        var output = takeCropScratch(slot: frameSlot, byteCount: outputBytesPerBlockRow * cropBlocksY)
        image.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for blockRow in 0..<cropBlocksY {
                    let srcOffset = (originBlockY + blockRow) * sourceBytesPerBlockRow + originBlockX * bytesPerBlock
                    let dstOffset = blockRow * outputBytesPerBlockRow
                    dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerBlockRow)
                }
            }
        }
        cropScratchSlots[frameSlot] = output
        return Cropped(bytes: output, width: rect.width, height: rect.height, bytesPerRow: outputBytesPerBlockRow)
    }

    /// Detaches the slot's scratch so the mutation below cannot CoW-copy
    /// (the array would otherwise hold a second reference). Same-size frames
    /// reuse the allocation; a size change (rare) reallocates once.
    private func takeCropScratch(slot: Int, byteCount: Int) -> Data {
        var scratch = cropScratchSlots[slot]
        cropScratchSlots[slot] = Data()
        if scratch.count != byteCount {
            scratch = Data(count: byteCount)
        }
        return scratch
    }

    private struct PixelRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private func pixelRect(_ rect: CGRect, width: Int, height: Int) -> PixelRect {
        // Snap float pixel coords to nearest (2415.9999→2416) before clamp — avoids 1px seams.
        let snappedX = rect.origin.x.rounded(.toNearestOrAwayFromZero)
        let snappedY = rect.origin.y.rounded(.toNearestOrAwayFromZero)
        let snappedW = rect.width.rounded(.toNearestOrAwayFromZero)
        let snappedH = rect.height.rounded(.toNearestOrAwayFromZero)

        let x = min(max(Int(snappedX), 0), max(width - 1, 0))
        let y = min(max(Int(snappedY), 0), max(height - 1, 0))
        let w = min(max(Int(snappedW), 1), max(width - x, 1))
        let h = min(max(Int(snappedH), 1), max(height - y, 1))
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    private func textureForUpload(width: Int, height: Int, frameSlot: Int) throws -> MTLTexture {
        try validateTextureDimensions(width: width, height: height)
        if let texture = workingTextureSlots[frameSlot].texture,
           workingTextureSlots[frameSlot].width == width,
           workingTextureSlots[frameSlot].height == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        // Match the eager loader: RG88 alpha-channel-priority glows sample
        // as (R, R, R, G) so the alpha falloff survives the `.rg8Unorm` upload.
        if alphaChannelPriorityRG88 {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureAllocationFailed
        }
        texture.label = "\(label) lazy frame \(frameSlot)"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        workingTextureSlots[frameSlot] = WorkingTextureSlot(
            texture: texture,
            width: width,
            height: height,
            lastUploadedFrameIndex: -1
        )
        return texture
    }

    private func validateTextureDimensions(width: Int, height: Int) throws {
        guard width <= maximumTextureDimension2D,
              height <= maximumTextureDimension2D else {
            throw Failure.textureDimensionsExceedDeviceLimit(
                width: width,
                height: height,
                limit: maximumTextureDimension2D
            )
        }
    }

}
#endif
