#if !LITE_BUILD
import Compression
import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperProWPE

/// Skipped levels keep index/width/height (for `uploadMipStartIndex`) and carry empty `bytes`.
struct WPETexMipInflateScope: Sendable, Equatable {
    /// Longest-edge cap the consumer renders at; nil = no render-scale cap.
    let maxSourceEdge: Int?
    /// Consumer uploads every level from the start level down, not just one.
    let uploadsChain: Bool

    /// Historical behavior: inflate everything. Every caller that does math on
    /// physical mip dimensions (particles, animation atlases) needs this.
    static let fullChain = WPETexMipInflateScope(maxSourceEdge: nil, uploadsChain: true)

    /// MUST mirror `WPEMetalTextureLoader.makeTextureSynchronously`; that function degrades to a single level rather than throwing if the two disagree.
    func selectedLevels(levelSizes: [(width: Int, height: Int)], noInterpolation: Bool) -> Range<Int> {
        guard let level0 = levelSizes.first else { return 0 ..< 0 }
        // Data textures index by texel (nearest sampling, or a 4096×1 LUT
        // strip); minifying them collapses distinct entries, so they pin to 0.
        let isDataTexture = noInterpolation || min(level0.width, level0.height) <= 64
        let start = isDataTexture ? 0 : Self.startLevel(levelSizes: levelSizes, maxEdge: maxSourceEdge)
        guard uploadsChain, levelSizes.count - start > 1 else { return start ..< (start + 1) }
        return start ..< levelSizes.count
    }

    /// The SMALLEST level that still covers `maxEdge` on its longest side.
    /// Never scales UP; nil/degenerate caps keep level 0.
    static func startLevel(levelSizes: [(width: Int, height: Int)], maxEdge: Int?) -> Int {
        guard let maxEdge, maxEdge > 0, levelSizes.count > 1 else { return 0 }
        var start = 0
        for (index, level) in levelSizes.enumerated() {
            if max(level.width, level.height) >= maxEdge {
                start = index
            } else {
                break
            }
        }
        return start
    }
}

#if DEBUG
/// Test-only meter for the mip-inflate scope; task-local so a parallel suite's decodes
/// cannot leak into the count. `@unchecked Sendable` because `total` is only ever touched under `lock`.
final class WPETexInflateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var materializedMipBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    func record(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        total += count
    }
}
#endif

struct WPETexDecoder: Sendable {
    #if DEBUG
    @TaskLocal static var inflateMeter: WPETexInflateMeter?
    #endif

    func probe(span: WPEMappedByteSpan) -> Result<WPETexInfo, WPETexDecodeError> {
        do {
            return try .success(parseHeader(span: span))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    /// Metadata only: no mip inflation or GPU upload. Animated atlases cannot
    /// establish a fixed composite extent from their container dimensions.
    func probeStaticImage(span: WPEMappedByteSpan) throws -> WPETexInfo? {
        let parsed = try parse(span: span)
        guard !parsed.info.isVolume, !parsed.bitmap.isVideoPayload, parsed.bitmap.frames.count == 1,
              parsed.frameInfo == nil, !parsed.bitmap.usesEncodedImagePayload else { return nil }
        return parsed.info
    }

    #if DEBUG
    func decode(data: Data) -> Result<CGImage, WPETexDecodeError> {
        decode(span: WPEMappedByteSpan(data: data))
    }
    #endif

    func decode(span: WPEMappedByteSpan) -> Result<CGImage, WPETexDecodeError> {
        do {
            let parsed = try parse(span: span)
            return try .success(makeCGImage(from: parsed))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    #if DEBUG
    func extractStreamingPayload(data: Data) -> Result<WPETexStreamingPayload, WPETexDecodeError> {
        extractStreamingPayload(span: WPEMappedByteSpan(data: data))
    }
    #endif

    func extractStreamingPayload(span: WPEMappedByteSpan) -> Result<WPETexStreamingPayload, WPETexDecodeError> {
        do {
            let parsed = try parse(span: span)
            return try .success(makeStreamingPayload(from: parsed))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    func extractRawMetadata(data: Data) -> Result<WPETexRawMetadata, WPETexDecodeError> {
        extractRawMetadata(span: WPEMappedByteSpan(data: data))
    }

    func extractRawMetadata(span: WPEMappedByteSpan) -> Result<WPETexRawMetadata, WPETexDecodeError> {
        do {
            let parsed = try parse(span: span)
            return .success(WPETexRawMetadata(info: parsed.info, bitmap: parsed.bitmap))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    /// `scope` narrows 2D mip inflation. `allowRawVolume` opts a 3D-capable consumer into static volumes:
    /// raw non-BC payloads keep every authored mip; a single-mip encoded image unfolds to one RGBA8 level.
    func extractTexturePayload(
        data: Data,
        scope: WPETexMipInflateScope = .fullChain,
        allowRawVolume: Bool = false,
        conditionalProperties: WPESceneJSONValue? = nil
    ) -> Result<WPETexTexturePayload, WPETexDecodeError> {
        extractTexturePayload(span: WPEMappedByteSpan(data: data), scope: scope, allowRawVolume: allowRawVolume,
                              conditionalProperties: conditionalProperties)
    }

    func extractTexturePayload(
        span: WPEMappedByteSpan,
        scope: WPETexMipInflateScope = .fullChain,
        allowRawVolume: Bool = false,
        conditionalProperties: WPESceneJSONValue? = nil
    ) -> Result<WPETexTexturePayload, WPETexDecodeError> {
        do {
            let parsed = try parse(span: span)

            if parsed.info.isVolume {
                // Existing 2D consumers keep rejecting volumes. Only the native parity uploader opts in.
                guard allowRawVolume else {
                    throw WPETexDecodeError.unsupportedTextureDimension(depth: parsed.info.depth)
                }
                guard let format = parsed.info.format, format.bytesPerPixel != nil else {
                    throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
                }
                guard !parsed.bitmap.isVideoPayload, parsed.info.flags & 0x24 == 0,
                      !parsed.hasAnimationFrames, parsed.bitmap.conditionalVariants.isEmpty else {
                    throw WPETexDecodeError.unsupportedTextureDimension(depth: parsed.info.depth)
                }
                if parsed.bitmap.usesEncodedImagePayload {
                    guard parsed.bitmap.frames.count == 1, parsed.bitmap.mipmaps.count == 1 else {
                        throw WPETexDecodeError.unsupportedTextureDimension(depth: parsed.info.depth)
                    }
                } else {
                    try WPETexMipValidation.rawVolume(parsed.bitmap.mipmaps, info: parsed.info, format: format)
                }
            }
            if !parsed.bitmap.conditionalVariants.isEmpty, let conditionalProperties {
                let selection = try WPETexConditionalSelection(variants: parsed.bitmap.conditionalVariants,
                                                               properties: conditionalProperties)
                let images = try WPETexConditionalMaterializer.images(
                    info: parsed.info, bitmap: parsed.bitmap, selection: selection,
                    decode: { try normalizedBytes(for: $0, format: parsed.info.format,
                                                  textureFormatCode: parsed.info.textureFormatCode) },
                    inflatePatch: { record, mip in
                        let count = try WPETexMipValidation.layout(format: parsed.info.format!, width: record.width,
                                                                   height: record.height).byteCount
                        if mip.isCompressed {
                            // 15df24..15df73 uses a four-byte-per-pixel scratch capacity even for R/RG.
                            // Unlike base mips, the native patch decoder accepts shorter successful output.
                            let capacity = try WPETexMipValidation.layout(format: .rgba8888, width: record.width,
                                                                          height: record.height).byteCount
                            guard capacity <= WPETexCompressedMipmap.maxDecompressedByteCount else {
                                throw WPETexDecodeError.decompressionFailed(mipmap: mip.index)
                            }
                            return try lz4Inflate(payload: record.payload, outputCount: capacity, mipmap: mip.index,
                                                  minimumOutputCount: count)
                        }
                        return try inflateIfNeeded(payload: record.payload, expectedByteCount: count,
                                                   decompressedByteCount: count, isCompressed: false, mipmap: mip.index)
                    }
                )
                let first = images.first ?? []
                return try .success(WPETexTexturePayload(
                    info: parsed.info, mipmaps: first, hasAnimationFrames: parsed.hasAnimationFrames,
                    animationTrack: makeAnimationTrack(from: parsed, firstImageMipmaps: first, imageMipmaps: images),
                    hasConditionalVariants: true, conditionalSelection: selection
                ))
            }
            if parsed.info.format?.requiresRawPayload == true,
               (parsed.bitmap.sourceImageFormatCode ?? -1) != -1 {
                throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
            }
            if !parsed.info.isVolume, let videoPayload = makeVideoPayload(from: parsed) {
                return .success(WPETexTexturePayload(
                    info: parsed.info,
                    mipmaps: [],
                    hasAnimationFrames: false,
                    videoPayload: videoPayload
                ))
            }

            if parsed.bitmap.usesEncodedImagePayload {
                let bridgedPayload = try parsed.info.isVolume
                    ? decodeEncodedVolume(parsed) : bridgeEncodedImagePayload(parsed)
                return .success(bridgedPayload)
            }

            let firstFrameMipmaps = try normalizedTextureMipmaps(
                parsed.bitmap.mipmaps,
                info: parsed.info,
                scope: scope
            )
            let animationTrack = try makeAnimationTrack(from: parsed,
                                                        firstImageMipmaps: scope == .fullChain ? firstFrameMipmaps : nil)

            return .success(WPETexTexturePayload(
                info: parsed.info,
                mipmaps: firstFrameMipmaps,
                hasAnimationFrames: parsed.hasAnimationFrames,
                animationTrack: animationTrack,
                hasConditionalVariants: !parsed.bitmap.conditionalVariants.isEmpty
            ))
        } catch let error as WPETexDecodeError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
        }
    }

    /// `scope` defaults to the whole chain; only the static scene-layer upload
    /// path narrows it (the animation track deliberately keeps every level).
    private func normalizedTextureMipmaps(
        _ mipmaps: [WPETexMipmap],
        info: WPETexInfo,
        scope: WPETexMipInflateScope = .fullChain
    ) throws -> [WPETexTextureMipmap] {
        let selected = info.isVolume ? mipmaps.indices : scope.selectedLevels(
            levelSizes: mipmaps.map { (width: $0.width, height: $0.height) },
            noInterpolation: info.noInterpolation
        )
        return try mipmaps.enumerated().map { position, mipmap in
            try WPETexTextureMipmap(
                index: mipmap.index,
                width: mipmap.width,
                height: mipmap.height,
                depth: mipmap.depth,
                bytes: selected.contains(position)
                    ? normalizedBytes(
                        for: mipmap,
                        format: info.format,
                        textureFormatCode: info.textureFormatCode
                    )
                    : Data()
            )
        }
    }

    private func makeAnimationTrack(from parsed: ParsedTex,
                                    firstImageMipmaps: [WPETexTextureMipmap]? = nil,
                                    imageMipmaps: [[WPETexTextureMipmap]]? = nil) throws -> WPETexAnimationTrack? {
        let texsFrames = parsed.frameInfo?.frames ?? []
        guard parsed.bitmap.frames.count > 1 || !texsFrames.isEmpty else { return nil }

        let defaultDuration = 1.0 / WPETexAnimationTrack.defaultFrameRate
        let info = parsed.info

        struct Descriptor {
            let fallbackIndex: Int
            let frameInfo: WPETexFrameInfo?
        }
        let descriptors: [Descriptor] = if texsFrames.isEmpty {
            parsed.bitmap.frames.indices.map { Descriptor(fallbackIndex: $0, frameInfo: nil) }
        } else {
            texsFrames.enumerated().map { Descriptor(fallbackIndex: $0.offset, frameInfo: $0.element) }
        }

        // Share decompressed images across TEXS frames (avoids multi-GB OOM).
        var mipmapsByImageID: [Int: [WPETexTextureMipmap]] = firstImageMipmaps.map { [0: $0] } ?? [:]
        if let imageMipmaps {
            mipmapsByImageID = Dictionary(uniqueKeysWithValues: imageMipmaps.enumerated().map { ($0.offset, $0.element) })
        }
        func mipmaps(for sourceIndex: Int) throws -> [WPETexTextureMipmap] {
            if let cached = mipmapsByImageID[sourceIndex] {
                return cached
            }
            let materialized = try normalizedTextureMipmaps(parsed.bitmap.frames[sourceIndex], info: info)
            mipmapsByImageID[sourceIndex] = materialized
            return materialized
        }

        let frames = try descriptors.map { descriptor -> WPETexAnimationFrame in
            let frameInfo = descriptor.frameInfo
            let requestedID = frameInfo?.imageID ?? descriptor.fallbackIndex
            let sourceIndex = parsed.bitmap.frames.indices.contains(requestedID)
                ? requestedID
                : min(descriptor.fallbackIndex, max(parsed.bitmap.frames.count - 1, 0))
            let frameTime = frameInfo?.frameTime ?? 0
            let duration = frameTime > 0 ? frameTime : defaultDuration
            let frameMipmaps = try mipmaps(for: sourceIndex)
            let sourceWidth = frameMipmaps.first?.width ?? info.width
            let sourceHeight = frameMipmaps.first?.height ?? info.height
            return WPETexAnimationFrame(
                imageID: sourceIndex,
                duration: duration,
                mipmaps: frameMipmaps,
                subRect: frameInfo?.subRect(textureWidth: sourceWidth, textureHeight: sourceHeight),
                samplingDescriptor: frameInfo?.samplingDescriptor(
                    textureWidth: sourceWidth,
                    textureHeight: sourceHeight
                )
            )
        }

        let frameRate = computeFrameRate(fromDurations: frames.map(\.duration), defaultDuration: defaultDuration)

        return WPETexAnimationTrack(
            frames: frames,
            frameRate: frameRate,
            loop: true
        )
    }

    private func computeFrameRate(fromDurations durations: [TimeInterval], defaultDuration: TimeInterval) -> Double {
        let validDurations = durations.filter { $0 > 0 }
        let averageDuration = validDurations.isEmpty
            ? defaultDuration
            : validDurations.reduce(0, +) / Double(validDurations.count)
        return averageDuration > 0 ? 1.0 / averageDuration : WPETexAnimationTrack.defaultFrameRate
    }

    private func makeVideoPayload(from parsed: ParsedTex) -> WPETexVideoPayload? {
        guard let mip = parsed.bitmap.largestMipmap else { return nil }
        guard parsed.bitmap.isVideoPayload || looksLikeMP4Payload(mip.payload) else {
            return nil
        }
        return WPETexVideoPayload(bytes: mip.payload.materializedData())
    }

    private func makeStreamingPayload(from parsed: ParsedTex) throws -> WPETexStreamingPayload {
        guard !parsed.info.isVolume else {
            throw WPETexDecodeError.unsupportedTextureDimension(depth: parsed.info.depth)
        }
        guard !parsed.bitmap.isVideoPayload else {
            throw WPETexDecodeError.unsupportedAnimation
        }
        // Native Metal-sampleable formats stay compressed until GPU upload.
        guard let format = parsed.info.format else {
            throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
        }
        switch format {
        case .rgba8888, .r8, .rg88, .dxt1, .dxt3, .dxt5, .bc7:
            break
        case .rgba1010102, .rg16Float, .r16Float, .rgba16Float, .rgba16Float15, .r32Float,
             .rgba16Unorm, .rgba16Unorm18, .rgba16Snorm, .rgba16Snorm20:
            throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
        }
        let texsFrames = parsed.frameInfo?.frames ?? []
        guard parsed.bitmap.frames.count > 1 || !texsFrames.isEmpty else {
            throw WPETexDecodeError.unsupportedAnimation
        }

        let compressedImages: [WPETexCompressedImage] = try parsed.bitmap.frames.map { mipmaps in
            guard let largest = mipmaps.first else {
                throw WPETexDecodeError.missingBitmapBlock
            }
            let payloads = mipmaps.map { mipmap in
                WPETexCompressedMipmap(
                    index: mipmap.index,
                    width: mipmap.width,
                    height: mipmap.height,
                    depth: mipmap.depth,
                    isCompressed: mipmap.isCompressed,
                    compressedBytes: mipmap.payload,
                    decompressedByteCount: mipmap.decompressedByteCount
                        ?? format.expectedByteCount(width: mipmap.width, height: mipmap.height)
                )
            }
            return WPETexCompressedImage(
                width: largest.width,
                height: largest.height,
                payloads: payloads
            )
        }

        let defaultDuration = 1.0 / WPETexAnimationTrack.defaultFrameRate
        let info = parsed.info
        let frames: [WPETexStreamingFrame] = if texsFrames.isEmpty {
            parsed.bitmap.frames.indices.map { imageID in
                WPETexStreamingFrame(
                    imageID: imageID,
                    subRect: CGRect(x: 0, y: 0, width: info.width, height: info.height),
                    duration: defaultDuration
                )
            }
        } else {
            texsFrames.enumerated().map { offset, frameInfo in
                let imageID = parsed.bitmap.frames.indices.contains(frameInfo.imageID)
                    ? frameInfo.imageID
                    : min(offset, max(parsed.bitmap.frames.count - 1, 0))
                let duration = frameInfo.frameTime > 0 ? frameInfo.frameTime : defaultDuration
                let sourceImage = compressedImages[imageID]
                return WPETexStreamingFrame(
                    imageID: imageID,
                    subRect: frameInfo.subRect(
                        textureWidth: sourceImage.width,
                        textureHeight: sourceImage.height
                    ),
                    duration: duration,
                    samplingDescriptor: frameInfo.samplingDescriptor(
                        textureWidth: sourceImage.width,
                        textureHeight: sourceImage.height
                    )
                )
            }
        }

        let frameRate = computeFrameRate(fromDurations: frames.map(\.duration), defaultDuration: defaultDuration)

        return WPETexStreamingPayload(
            info: info,
            compressedImages: compressedImages,
            frames: frames,
            frameRate: frameRate,
            loop: true
        )
    }

    // MARK: - Parsing

    private struct ParsedTex {
        let info: WPETexInfo
        let bitmap: WPETexBitmapBlock
        let frameInfo: WPETexFrameInfoBlock?
        let hasAnimationFrames: Bool
    }

    private struct WPETexFrameInfoBlock {
        let version: Int
        let gifWidth: Int?
        let gifHeight: Int?
        let frames: [WPETexFrameInfo]
    }

    private struct WPETexFrameInfo {
        let imageID: Int
        let frameTime: TimeInterval
        let x: Float
        let y: Float
        let width: Float
        let widthY: Float
        let heightX: Float
        let height: Float

        /// Clamp TEXS sub-rect (published zero size / edge overflow).
        func subRect(textureWidth: Int, textureHeight: Int) -> CGRect {
            let maxW = CGFloat(max(textureWidth, 1))
            let maxH = CGFloat(max(textureHeight, 1))
            let originX = min(max(CGFloat(x), 0), maxW - 1)
            let originY = min(max(CGFloat(y), 0), maxH - 1)
            let rawW = width > 0 ? CGFloat(width) : maxW
            let rawH = height > 0 ? CGFloat(height) : maxH
            let clampedW = min(max(rawW, 1), maxW - originX)
            let clampedH = min(max(rawH, 1), maxH - originY)
            return CGRect(x: originX, y: originY, width: clampedW, height: clampedH)
        }

        /// 14015e1d0:181-192: x-coordinate lanes divide by width; y-coordinate lanes divide by height.
        func samplingDescriptor(
            textureWidth: Int,
            textureHeight: Int
        ) -> WPETexSpriteSamplingDescriptor {
            let normalizedWidth = Float(max(textureWidth, 1))
            let normalizedHeight = Float(max(textureHeight, 1))
            return WPETexSpriteSamplingDescriptor(
                rotation: SIMD4<Float>(
                    width / normalizedWidth,
                    widthY / normalizedHeight,
                    heightX / normalizedWidth,
                    height / normalizedHeight
                ),
                translation: SIMD2<Float>(
                    x / normalizedWidth,
                    y / normalizedHeight
                )
            )
        }
    }

    private func parseHeader(span: WPEMappedByteSpan) throws -> WPETexInfo {
        var reader = WPETexByteReader(span: span)
        let containerMagic = try reader.readMagic()
        guard let containerVersion = WPEParityProgramTextureHeader.containerVersion(for: containerMagic) else {
            throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
        }
        if containerVersion == 4 {
            return try parseInfoBlock(versionedMagic: "TEXI0000", containerVersion: containerVersion, reader: &reader)
        }

        let infoMagic = try reader.readMagic()
        guard WPEParityProgramTextureHeader.infoVersion(for: infoMagic) != nil else {
            throw WPETexDecodeError.unsupportedBlock(magic: infoMagic)
        }
        return try parseInfoBlock(
            versionedMagic: infoMagic,
            containerVersion: containerVersion,
            reader: &reader
        )
    }

    private func parse(span: WPEMappedByteSpan) throws -> ParsedTex {
        var reader = WPETexByteReader(span: span)
        let containerMagic = try reader.readMagic()
        guard let containerVersion = WPEParityProgramTextureHeader.containerVersion(for: containerMagic) else {
            throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
        }
        var info: WPETexInfo?
        var bitmap: WPETexBitmapBlock?
        var frameInfo: WPETexFrameInfoBlock?

        // 14015e580:161-163: TEXV4 embeds version-zero info and bitmap records, without TEXI/TEXB tags.
        if containerVersion == 4 {
            let legacyInfo = try parseInfoBlock(versionedMagic: "TEXI0000", containerVersion: containerVersion,
                                                reader: &reader)
            info = legacyInfo
            bitmap = try parseBitmapBlock(versionedMagic: "TEXB0000", info: legacyInfo, reader: &reader)
        }

        while !reader.isAtEnd {
            let blockMagic = try reader.readMagic()
            switch blockMagic.prefix(4) {
            case "TEXI":
                info = try parseInfoBlock(
                    versionedMagic: blockMagic,
                    containerVersion: containerVersion,
                    reader: &reader
                )

            case "TEXB":
                guard let parsedInfo = info else {
                    throw WPETexDecodeError.missingInfoBlock
                }
                bitmap = try parseBitmapBlock(
                    versionedMagic: blockMagic,
                    info: parsedInfo,
                    reader: &reader
                )

            case "TEXS":
                frameInfo = try parseFrameInfoBlock(
                    versionedMagic: blockMagic,
                    reader: &reader
                )

            default:
                throw WPETexDecodeError.unsupportedBlock(magic: blockMagic)
            }
        }

        guard let parsedInfo = info else { throw WPETexDecodeError.missingInfoBlock }
        guard let parsedBitmap = bitmap else { throw WPETexDecodeError.missingBitmapBlock }

        let hasAnimation = parsedBitmap.frames.count > 1 || frameInfo != nil
        return ParsedTex(
            info: parsedInfo,
            bitmap: parsedBitmap,
            frameInfo: frameInfo,
            hasAnimationFrames: hasAnimation
        )
    }

    private func parseFrameInfoBlock(
        versionedMagic: String,
        reader: inout WPETexByteReader
    ) throws -> WPETexFrameInfoBlock {
        let version = parseTrailingVersion(versionedMagic)
        let frameCount = try Int(reader.readInt32(blockName: "TEXS.frameCount"))
        guard frameCount > 0, frameCount <= 4096 else {
            throw WPETexDecodeError.mipmapOutOfBounds(index: frameCount)
        }

        let gifWidth: Int?
        let gifHeight: Int?
        if version == 3 {
            gifWidth = try Int(reader.readInt32(blockName: "TEXS.gifWidth"))
            gifHeight = try Int(reader.readInt32(blockName: "TEXS.gifHeight"))
        } else {
            gifWidth = nil
            gifHeight = nil
        }

        var frames: [WPETexFrameInfo] = []
        frames.reserveCapacity(frameCount)

        for _ in 0 ..< frameCount {
            let imageID = try Int(reader.readInt32(blockName: "TEXS.imageID"))
            let frameTime = try TimeInterval(reader.readFloat32(blockName: "TEXS.frameTime"))

            if version == 1 {
                try frames.append(WPETexFrameInfo(
                    imageID: imageID,
                    frameTime: frameTime,
                    x: Float(reader.readInt32(blockName: "TEXS.x")),
                    y: Float(reader.readInt32(blockName: "TEXS.y")),
                    width: Float(reader.readInt32(blockName: "TEXS.width")),
                    widthY: Float(reader.readInt32(blockName: "TEXS.widthY")),
                    heightX: Float(reader.readInt32(blockName: "TEXS.heightX")),
                    height: Float(reader.readInt32(blockName: "TEXS.height"))
                ))
            } else if version == 2 || version == 3 {
                try frames.append(WPETexFrameInfo(
                    imageID: imageID,
                    frameTime: frameTime,
                    x: reader.readFloat32(blockName: "TEXS.x"),
                    y: reader.readFloat32(blockName: "TEXS.y"),
                    width: reader.readFloat32(blockName: "TEXS.width"),
                    widthY: reader.readFloat32(blockName: "TEXS.widthY"),
                    heightX: reader.readFloat32(blockName: "TEXS.heightX"),
                    height: reader.readFloat32(blockName: "TEXS.height")
                ))
            } else {
                throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
            }
            // Geometry reaches both GPU sampling descriptors and CPU Int crop
            // coordinates. Reject nonfinite file values before either path.
            if let frame = frames.last,
               ![frame.x, frame.y, frame.width, frame.widthY, frame.heightX, frame.height].allSatisfy(\.isFinite)
               || !frame.frameTime.isFinite {
                throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "Nonfinite TEXS geometry or duration")
            }
        }

        return WPETexFrameInfoBlock(
            version: version,
            gifWidth: gifWidth,
            gifHeight: gifHeight,
            frames: frames
        )
    }

    // MARK: - TEXI

    private func parseInfoBlock(
        versionedMagic: String,
        containerVersion: Int,
        reader: inout WPETexByteReader
    ) throws -> WPETexInfo {
        guard let infoVersion = WPEParityProgramTextureHeader.infoVersion(for: versionedMagic) else {
            throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
        }
        let header = try WPEParityProgramTextureHeader(readUInt32: {
            try reader.readUInt32(blockName: "TEXI.header")
        })
        let formatCode = Int(header.format)
        let flags = header.flags
        let textureWidth = Int(Int32(bitPattern: header.textureWidth))
        let textureHeight = Int(Int32(bitPattern: header.textureHeight))
        let imageWidth = Int(Int32(bitPattern: header.imageWidth))
        let imageHeight = Int(Int32(bitPattern: header.imageHeight))
        let flag0x40Extension: WPETexFlag0x40Extension?
        if flags & WPETexInfo.rawExtensionFlag != 0 {
            let sourceStart = reader.cursor
            let rawValue = try reader.readInt32(blockName: "TEXI.depth")
            flag0x40Extension = WPETexFlag0x40Extension(
                rawValue: rawValue,
                sourceRange: sourceStart ..< reader.cursor
            )
        } else {
            flag0x40Extension = nil
        }
        let unknownInt0: Int32 = if infoVersion > 0 {
            try reader.readInt32(blockName: "TEXI.unkInt0")
        } else {
            0
        }

        let format = WPETexFormat(rawValue: formatCode)
        let info = WPETexInfo(
            containerVersion: containerVersion,
            infoVersion: infoVersion,
            width: textureWidth,
            height: textureHeight,
            textureFormatCode: formatCode,
            format: format,
            mipmapCount: 0,
            flags: flags,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            unknownInt0: unknownInt0,
            flag0x40Extension: flag0x40Extension
        )
        guard info.dimensionsLooksValid else {
            throw WPETexDecodeError.invalidDimensions(width: textureWidth, height: textureHeight)
        }
        return info
    }

    // MARK: - TEXB

    private func parseBitmapBlock(
        versionedMagic: String,
        info: WPETexInfo,
        reader: inout WPETexByteReader
    ) throws -> WPETexBitmapBlock {
        let bitmapVersion = parseTrailingVersion(versionedMagic)
        let imageCount = try bitmapVersion == 0 ? 1 : Int(reader.readInt32(blockName: "TEXB.imageCount"))
        guard imageCount > 0, imageCount <= 4096 else {
            throw WPETexDecodeError.mipmapOutOfBounds(index: imageCount)
        }

        let sourceImageFormatCode: Int?
        switch bitmapVersion {
        case 0, 1, 2: sourceImageFormatCode = nil
        case 3, 4: sourceImageFormatCode = try Int(reader.readInt32(blockName: "TEXB.imageFormat"))
        default: throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
        }
        // 14015c8d0 reads this count unconditionally for TEXB4. Video is a TEXI flag,
        // not an alternative interpretation of the first conditional-table words.
        let variantCount = try bitmapVersion == 4 ? Int(reader.readUInt32(blockName: "TEXB.conditionalImageCount")) : 0
        guard variantCount <= 4096 else { throw WPETexDecodeError.mipmapOutOfBounds(index: variantCount) }
        if info.isVolume, variantCount != 0 {
            throw WPETexDecodeError.unsupportedTextureDimension(depth: info.depth)
        }
        var variants: [WPETexConditionalVariant] = []
        var conditionByteCount = 0
        for _ in 0 ..< variantCount {
            let group = try reader.readUInt32(blockName: "TEXB.conditionalGroup")
            let id = try reader.readUInt32(blockName: "TEXB.conditionalImageID")
            let flags = try reader.readUInt32(blockName: "TEXB.conditionalFlags")
            let condition = try reader.readNullTerminatedSpan(blockName: "TEXB.conditionalCondition")
            conditionByteCount += condition.count
            guard conditionByteCount <= 4 << 20 else {
                throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "Conditional JSON exceeds byte budget")
            }
            variants.append(WPETexConditionalVariant(groupKey: group, variantID: id, flags: flags,
                                                     conditionBytes: condition.materializedData()))
        }
        var records: [WPETexConditionalVariantMipmap] = []
        var frames: [[WPETexMipmap]] = []
        frames.reserveCapacity(imageCount)
        for imageIndex in 0 ..< imageCount {
            let mipmapCount = try Int(reader.readInt32(blockName: "TEXB.mipCount"))
            guard mipmapCount > 0, mipmapCount <= 32 else {
                throw WPETexDecodeError.mipmapOutOfBounds(index: mipmapCount)
            }

            var frameMipmaps: [WPETexMipmap] = []
            frameMipmaps.reserveCapacity(mipmapCount)
            for mipmapIndex in 0 ..< mipmapCount {
                try frameMipmaps.append(parseMipmap(
                    version: min(bitmapVersion, 3),
                    index: mipmapIndex,
                    info: info,
                    reader: &reader
                ))
                if variantCount > 0 {
                    try parseConditionalMipmaps(imageIndex: imageIndex, mipmapIndex: mipmapIndex,
                                                reader: &reader, into: &records)
                }
            }
            frames.append(frameMipmaps)
        }
        let bitmap = WPETexBitmapBlock(
            version: bitmapVersion,
            sourceImageFormatCode: sourceImageFormatCode,
            isVideoPayload: info.flags & 0x20 != 0,
            frames: frames,
            conditionalVariants: variants,
            conditionalRecords: records
        )
        // Encoded image/video payloads have their own decoder geometry contract.
        if !bitmap.usesEncodedImagePayload, !bitmap.isVideoPayload {
            for frame in frames {
                try WPETexMipValidation.geometry(frame.map { ($0.index, $0.width, $0.height, $0.depth) })
            }
        }
        return bitmap
    }

    /// 14015c8d0: each mip has an outer group count and an independent record count per group.
    /// Records need not match the table order or contain every declared ID. Keep all records for selection.
    private func parseConditionalMipmaps(
        imageIndex: Int,
        mipmapIndex: Int,
        reader: inout WPETexByteReader,
        into records: inout [WPETexConditionalVariantMipmap]
    ) throws {
        let groupCount = try Int(reader.readUInt32(blockName: "TEXB.conditionalGroupCount"))
        guard groupCount <= 4096 else { throw WPETexDecodeError.mipmapOutOfBounds(index: groupCount) }
        for _ in 0 ..< groupCount {
            let count = try Int(reader.readUInt32(blockName: "TEXB.conditionalRecordCount"))
            guard count <= 4096, records.count <= 65536 - count else {
                throw WPETexDecodeError.decodeFailed(mipmap: mipmapIndex, detail: "Conditional record budget exceeded")
            }
            for _ in 0 ..< count {
                _ = try reader.readUInt32(blockName: "TEXB.conditionalMipWord")
                let id = try reader.readUInt32(blockName: "TEXB.conditionalMipImageID")
                let x = try Int(reader.readUInt32(blockName: "TEXB.conditionalMipX"))
                let y = try Int(reader.readUInt32(blockName: "TEXB.conditionalMipY"))
                let width = try Int(reader.readUInt32(blockName: "TEXB.conditionalMipWidth"))
                let height = try Int(reader.readUInt32(blockName: "TEXB.conditionalMipHeight"))
                let format = try Int(reader.readInt32(blockName: "TEXB.conditionalMipFormat"))
                let count = try Int(reader.readUInt32(blockName: "TEXB.conditionalMipSize"))
                let span = try reader.readSpan(count: count, blockName: "TEXB.conditionalMipPayload")
                records.append(WPETexConditionalVariantMipmap(
                    x: x, y: y, width: width, height: height, formatCode: format, payload: span,
                    variantID: id, imageIndex: imageIndex, mipIndex: mipmapIndex
                ))
            }
        }
    }

    private func parseMipmap(
        version: Int,
        index: Int,
        info: WPETexInfo,
        reader: inout WPETexByteReader
    ) throws -> WPETexMipmap {
        let mipWidth = try Int(reader.readInt32(blockName: "TEXB.mipWidth"))
        let mipHeight = try Int(reader.readInt32(blockName: "TEXB.mipHeight"))
        let mipDepth = try info.isVolume ? Int(reader.readUInt32(blockName: "TEXB.mipDepth")) : 1
        guard mipWidth > 0, mipHeight > 0, mipWidth <= info.width, mipHeight <= info.height else {
            throw WPETexDecodeError.invalidDimensions(width: mipWidth, height: mipHeight)
        }

        var compressedFlag: UInt32 = 0
        var decompressedByteCount: Int?
        if version >= 2 {
            compressedFlag = try reader.readUInt32(blockName: "TEXB.mipCompressed")
            decompressedByteCount = try Int(reader.readUInt32(blockName: "TEXB.mipDecompressedSize"))
        }

        let storedSize = try Int(reader.readUInt32(blockName: "TEXB.mipSize"))
        let payload = try reader.readSpan(count: storedSize, blockName: "TEXB.mipPayload")

        return WPETexMipmap(
            index: index,
            width: max(mipWidth, 1),
            height: max(mipHeight, 1),
            storedByteCount: storedSize,
            decompressedByteCount: decompressedByteCount,
            payload: payload,
            isCompressed: compressedFlag & 1 != 0,
            depth: mipDepth,
            compressionFlags: compressedFlag
        )
    }

    // MARK: - Pixel dispatch

    private func makeCGImage(from parsed: ParsedTex) throws -> CGImage {
        guard !parsed.info.isVolume else {
            throw WPETexDecodeError.unsupportedTextureDimension(depth: parsed.info.depth)
        }
        guard let mip = parsed.bitmap.largestMipmap else {
            throw WPETexDecodeError.missingBitmapBlock
        }
        if parsed.bitmap.isVideoPayload || looksLikeMP4Payload(mip.payload) {
            throw WPETexDecodeError.unsupportedAnimation
        }
        guard let format = parsed.info.format, !format.requiresRawPayload else {
            throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
        }
        if parsed.bitmap.usesEncodedImagePayload {
            let imageBytes = try inflateIfNeeded(
                payload: mip.payload,
                expectedByteCount: nil,
                decompressedByteCount: mip.decompressedByteCount,
                isCompressed: mip.isCompressed,
                mipmap: mip.index
            )
            return try makeEncodedCGImage(from: imageBytes, mipmap: mip.index, info: parsed.info)
        }

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        let pixelBytes: Data = try inflateIfNeeded(
            payload: mip.payload,
            expectedByteCount: expected,
            decompressedByteCount: mip.decompressedByteCount,
            isCompressed: mip.isCompressed,
            mipmap: mip.index
        )

        let decoded: DecodedRGBAImage
        switch format {
        case .rgba8888:
            decoded = try WPETexPixelDecoder.decodeRGBA8888(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .r8:
            decoded = try WPETexPixelDecoder.decodeR8(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .rg88:
            // RG88 = LUMINANCE_ALPHA glow (matches Metal rg8Unorm swizzle).
            let alphaChannelPriority = parsed.info.isRG88LuminanceAlpha
            decoded = try WPETexPixelDecoder.decodeRG88(
                pixelBytes,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index,
                alphaChannelPriority: alphaChannelPriority
            )
        case .dxt1, .dxt3, .dxt5, .bc7:
            decoded = try WPETexMetalTranscoder.transcode(
                pixelBytes,
                format: format,
                width: mip.width,
                height: mip.height,
                mipmap: mip.index
            )
        case .rgba1010102, .rg16Float, .r16Float, .rgba16Float, .rgba16Float15, .r32Float,
             .rgba16Unorm, .rgba16Unorm18, .rgba16Snorm, .rgba16Snorm20:
            throw WPETexDecodeError.unsupportedFormat(code: format.rawValue)
        }
        return try decoded.makeCGImage()
    }

    private func looksLikeMP4Payload(_ span: WPEMappedByteSpan) -> Bool {
        guard span.count >= 12 else { return false }
        return span.byte(at: 4) == 0x66
            && span.byte(at: 5) == 0x74
            && span.byte(at: 6) == 0x79
            && span.byte(at: 7) == 0x70
    }

    private func makeEncodedCGImage(from data: Data, mipmap: Int, info: WPETexInfo) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "ImageIO could not decode encoded mip payload")
        }
        // The PNG/JPEG header is untrusted: ImageIO reports its declared size, which would drive a w*h*4 allocation.
        // TEXI dims already passed `dimensionsLooksValid` (<= 16_384), so this bound also caps the encoded image.
        guard image.width <= info.width, image.height <= info.height else {
            throw WPETexDecodeError.invalidDimensions(width: image.width, height: image.height)
        }
        return image
    }

    private func bridgeEncodedImagePayload(_ parsed: ParsedTex) throws -> WPETexTexturePayload {
        if parsed.hasAnimationFrames {
            return try bridgeEncodedAnimatedImagePayload(parsed)
        }
        return try bridgeSingleEncodedImagePayload(parsed)
    }

    private func rgba8888Info(from source: WPETexInfo, width: Int, height: Int, mipmapCount: Int) -> WPETexInfo {
        WPETexInfo(
            containerVersion: source.containerVersion,
            infoVersion: source.infoVersion,
            width: width,
            height: height,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888,
            mipmapCount: mipmapCount,
            flags: source.flags,
            imageWidth: source.imageWidth,
            imageHeight: source.imageHeight,
            unknownInt0: source.unknownInt0,
            flag0x40Extension: source.flag0x40Extension
        )
    }

    /// Z slices stack vertically: texel (x, y, z) is pixel (x, height * z + y), so rows are already in volume order.
    private func decodeEncodedVolume(_ parsed: ParsedTex) throws -> WPETexTexturePayload {
        let info = parsed.info
        let mip = parsed.bitmap.mipmaps[0]
        let byteCount = try WPETexMipValidation.layout(format: .rgba8888, width: info.width, height: info.height,
                                                       depth: info.depth).byteCount
        guard byteCount <= WPETexCompressedMipmap.maxDecompressedByteCount else {
            throw WPETexMipValidation.Invalid(detail: "Volume mip chain exceeds decoded byte budget")
        }
        let encoded = try inflateIfNeeded(payload: mip.payload, expectedByteCount: nil,
                                          decompressedByteCount: mip.decompressedByteCount,
                                          isCompressed: mip.isCompressed, mipmap: mip.index)
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = image.colorSpace else {
            throw WPETexDecodeError.decodeFailed(mipmap: mip.index, detail: "ImageIO could not decode encoded volume payload")
        }
        guard image.width == info.width, image.height == info.height * info.depth else {
            throw WPETexDecodeError.invalidDimensions(width: image.width, height: image.height)
        }
        var pixels = Data(count: byteCount)
        // Drawing in the image's own colour space keeps CoreGraphics from colour matching the LUT values.
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else {
            throw WPETexDecodeError.decodeFailed(mipmap: mip.index, detail: "CGContext could not draw encoded volume payload")
        }
        WPERasterImageAlpha.unpremultiplyRGBA8(&pixels)
        return WPETexTexturePayload(
            info: rgba8888Info(from: info, width: info.width, height: info.height, mipmapCount: 1),
            mipmaps: [WPETexTextureMipmap(index: 0, width: info.width, height: info.height, depth: info.depth,
                                          bytes: pixels)],
            hasAnimationFrames: false
        )
    }

    private func bridgeSingleEncodedImagePayload(_ parsed: ParsedTex) throws -> WPETexTexturePayload {
        let mipmaps = try rasterizeEncodedMipmaps(parsed, sourceIndex: 0)
        guard let base = mipmaps.first else { throw WPETexDecodeError.missingBitmapBlock }
        let bridgedInfo = rgba8888Info(from: parsed.info, width: base.width, height: base.height,
                                       mipmapCount: mipmaps.count)
        return WPETexTexturePayload(
            info: bridgedInfo,
            mipmaps: mipmaps,
            hasAnimationFrames: false,
            hasConditionalVariants: !parsed.bitmap.conditionalVariants.isEmpty
        )
    }

    private func bridgeEncodedAnimatedImagePayload(_ parsed: ParsedTex) throws -> WPETexTexturePayload {
        let texsFrames = parsed.frameInfo?.frames ?? []
        let defaultDuration = 1.0 / WPETexAnimationTrack.defaultFrameRate

        var rasterizedByImageID: [Int: [WPETexTextureMipmap]] = [:]
        func atlas(for sourceIndex: Int) throws -> [WPETexTextureMipmap] {
            if let cached = rasterizedByImageID[sourceIndex] {
                return cached
            }
            let mipmaps = try rasterizeEncodedMipmaps(parsed, sourceIndex: sourceIndex)
            rasterizedByImageID[sourceIndex] = mipmaps
            return mipmaps
        }

        // Multi-TEXB without TEXS → default-cadence frames (static if one image).
        struct Descriptor {
            let fallbackIndex: Int
            let frameInfo: WPETexFrameInfo?
        }
        let descriptors: [Descriptor]
        if texsFrames.isEmpty {
            guard parsed.bitmap.frames.count > 1 else {
                return try bridgeSingleEncodedImagePayload(parsed)
            }
            descriptors = parsed.bitmap.frames.indices.map {
                Descriptor(fallbackIndex: $0, frameInfo: nil)
            }
        } else {
            descriptors = texsFrames.enumerated().map {
                Descriptor(fallbackIndex: $0.offset, frameInfo: $0.element)
            }
        }

        let frames: [WPETexAnimationFrame] = try descriptors.map { descriptor in
            let requestedID = descriptor.frameInfo?.imageID ?? descriptor.fallbackIndex
            let sourceIndex = parsed.bitmap.frames.indices.contains(requestedID)
                ? requestedID
                : min(descriptor.fallbackIndex, max(parsed.bitmap.frames.count - 1, 0))
            let mipmaps = try atlas(for: sourceIndex)
            guard let mip = mipmaps.first else { throw WPETexDecodeError.missingBitmapBlock }
            let duration: TimeInterval = if let frameInfo = descriptor.frameInfo, frameInfo.frameTime > 0 {
                frameInfo.frameTime
            } else {
                defaultDuration
            }
            let subRect = descriptor.frameInfo?.subRect(
                textureWidth: mip.width,
                textureHeight: mip.height
            )
            return WPETexAnimationFrame(
                imageID: sourceIndex,
                duration: duration,
                mipmaps: mipmaps,
                subRect: subRect,
                samplingDescriptor: descriptor.frameInfo?.samplingDescriptor(
                    textureWidth: mip.width,
                    textureHeight: mip.height
                )
            )
        }

        let frameRate = computeFrameRate(fromDurations: frames.map(\.duration), defaultDuration: defaultDuration)
        let track = WPETexAnimationTrack(
            frames: frames,
            frameRate: frameRate,
            loop: true
        )

        // Bridge dims = largest atlas (callers that ignore the track).
        let infoSource = frames.first?.mipmaps.first
        let bridgedInfo = rgba8888Info(
            from: parsed.info,
            width: infoSource?.width ?? parsed.info.width,
            height: infoSource?.height ?? parsed.info.height,
            mipmapCount: frames.first?.mipmaps.count ?? 0
        )
        return WPETexTexturePayload(
            info: bridgedInfo,
            mipmaps: [],
            hasAnimationFrames: true,
            animationTrack: track,
            hasConditionalVariants: !parsed.bitmap.conditionalVariants.isEmpty
        )
    }

    /// Encoded images are the only TEX path that goes through ImageIO. Decode every authored mip;
    /// retaining just image 0/level 0 silently changes minification and sprite atlas sampling.
    private func rasterizeEncodedMipmaps(_ parsed: ParsedTex, sourceIndex: Int) throws -> [WPETexTextureMipmap] {
        guard parsed.bitmap.frames.indices.contains(sourceIndex) else {
            throw WPETexDecodeError.missingBitmapBlock
        }
        let mipmaps = try parsed.bitmap.frames[sourceIndex].map { mip in
            let bytes = try inflateIfNeeded(payload: mip.payload, expectedByteCount: nil,
                                            decompressedByteCount: mip.decompressedByteCount,
                                            isCompressed: mip.isCompressed, mipmap: mip.index)
            let image = try makeEncodedCGImage(from: bytes, mipmap: mip.index, info: parsed.info)
            let rgba = try rasterizeRGBA8(from: image, mipmap: mip.index)
            return WPETexTextureMipmap(index: mip.index, width: rgba.width, height: rgba.height, bytes: rgba.pixels)
        }
        try WPETexMipValidation.decoded(mipmaps, format: .rgba8888)
        return mipmaps
    }

    /// Renders a `CGImage` into straight-alpha, sRGB-encoded RGBA8 bytes suitable for upload as `MTLPixelFormat.rgba8Unorm_srgb`.
    private func rasterizeRGBA8(from image: CGImage, mipmap: Int) throws -> DecodedRGBAImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / 4,
              height <= Int.max / max(width * 4, 1) else {
            throw WPETexDecodeError.invalidDimensions(width: width, height: height)
        }
        if let bytes = Self.straightRGBA8Bytes(from: image) {
            return DecodedRGBAImage(width: width, height: height, pixels: bytes)
        }
        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let drew = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "CGContext allocation or draw failed for encoded payload")
        }
        WPERasterImageAlpha.unpremultiplyRGBA8(&buffer)
        return DecodedRGBAImage(width: width, height: height, pixels: buffer)
    }

    /// A premultiplied raster round-trip cannot preserve hidden RGB or low-alpha data channels.
    static func straightRGBA8Bytes(from image: CGImage) -> Data? {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.alphaInfo == .last,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              !image.bitmapInfo.contains(.floatComponents),
              order.isEmpty || order == .byteOrder32Big,
              image.decode == nil,
              image.colorSpace?.name == CGColorSpace.sRGB,
              image.width > 0, image.height > 0,
              image.width <= Int.max / 4 else { return nil }
        let packedRow = image.width * 4
        let sourceRow = image.bytesPerRow
        guard sourceRow >= packedRow, image.height <= Int.max / sourceRow,
              let providerData = image.dataProvider?.data,
              CFDataGetLength(providerData) >= sourceRow * image.height,
              let source = CFDataGetBytePtr(providerData) else { return nil }
        return withExtendedLifetime(providerData) {
            if sourceRow == packedRow {
                return Data(bytes: source, count: packedRow * image.height)
            }
            var bytes = Data(count: packedRow * image.height)
            bytes.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return }
                for row in 0 ..< image.height {
                    base.advanced(by: row * packedRow).copyMemory(
                        from: source.advanced(by: row * sourceRow), byteCount: packedRow
                    )
                }
            }
            return bytes
        }
    }

    private func normalizedBytes(
        for mipmap: WPETexMipmap,
        format: WPETexFormat?,
        textureFormatCode: Int
    ) throws -> Data {
        guard let format else {
            throw WPETexDecodeError.unsupportedFormat(code: textureFormatCode)
        }
        let bytes = try inflateIfNeeded(
            payload: mipmap.payload,
            expectedByteCount: WPETexMipValidation.layout(format: format, width: mipmap.width,
                                                          height: mipmap.height, depth: mipmap.depth).byteCount,
            decompressedByteCount: mipmap.decompressedByteCount,
            isCompressed: mipmap.isCompressed,
            mipmap: mipmap.index
        )
        #if DEBUG
        Self.inflateMeter?.record(bytes.count)
        #endif
        return bytes
    }

    private func inflateIfNeeded(
        payload: WPEMappedByteSpan,
        expectedByteCount: Int?,
        decompressedByteCount: Int?,
        isCompressed: Bool,
        mipmap: Int
    ) throws -> Data {
        if isCompressed {
            var outputCount = decompressedByteCount.flatMap { $0 > 0 ? $0 : nil } ?? expectedByteCount ?? 0
            // Clamp untrusted decompressedByteCount before allocate (anti OOM).
            if let expectedByteCount, expectedByteCount > 0 {
                outputCount = min(outputCount, expectedByteCount)
            }
            let maxDecompressedSizeLimit = 268_435_456 // 256 MB
            guard outputCount > 0, outputCount <= maxDecompressedSizeLimit else {
                throw WPETexDecodeError.decompressionFailed(mipmap: mipmap)
            }
            let inflated = try lz4Inflate(payload: payload, outputCount: outputCount, mipmap: mipmap)
            if let expectedByteCount, inflated.count > expectedByteCount {
                return inflated.prefix(expectedByteCount)
            }
            return inflated
        }

        guard let expectedByteCount else { return payload.materializedData() }
        if payload.count >= expectedByteCount {
            return payload.prefix(expectedByteCount).materializedData()
        }

        throw WPETexDecodeError.decodeFailed(mipmap: mipmap, detail: "Truncated uncompressed mip payload")
    }

    private func lz4Inflate(payload: WPEMappedByteSpan, outputCount: Int, mipmap: Int, minimumOutputCount: Int? = nil) throws -> Data {
        var output = Data(count: outputCount)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_decode_buffer(
                    dst, outputCount,
                    src, input.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        // Base mips keep their exact-length guard. Patches need every byte their copy/blend reads;
        // skipping insufficient output avoids reproducing a native uninitialized scratch read.
        guard written >= (minimumOutputCount ?? outputCount), written <= outputCount else {
            throw WPETexDecodeError.decompressionFailed(mipmap: mipmap)
        }
        return minimumOutputCount == nil ? output : output.prefix(written)
    }

    // MARK: - Helpers

    /// "TEXV0005" → 5.
    private func parseTrailingVersion(_ magic: String) -> Int {
        let digits = magic.suffix(4)
        return Int(digits) ?? 0
    }
}

#endif
