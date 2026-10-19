#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperProWPE
import Metal
import os

/// Uploads native TEX resources once while planning a scene. Raw formats retain their channels and authored
/// mip chain; only TEXB's encoded-image payload uses the decoder's ImageIO bridge. No usage/path swizzle policy.
enum WPEParityTextureLoader {
    enum Failure: Error, LocalizedError {
        case unsupportedConditionalVariants
        case unsupportedSpriteWithoutTEXS(imageID: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedConditionalVariants: "Conditional TEX requires a typed user-property snapshot"
            case let .unsupportedSpriteWithoutTEXS(imageID): "Sprite image \(imageID) has no supported TEXS sampling descriptor"
            }
        }
    }

    private struct SharedKey: Hashable {
        let registryID: UInt64
        let path: String
        let digest: SHA256.Digest
        /// nil when the TEX has no conditional variants or no properties were given.
        let selection: [UInt32: UInt32]?
        /// Compressed and authored-format loads of one file never share a texture.
        let compressed: Bool
    }

    /// Where a compressing upload's images get their cache keys; `kept` is set when no image of the file qualifies.
    private struct CompressionSource {
        let compression: WPEParityTextureCompression
        let digest: SHA256.Digest
        let selection: [UInt32: UInt32]?
        /// The authored mip table of each TEXB image, indexed by image ID.
        let levels: [[WPETexMipmap]]
        let kept: WPEParityTextureCompressor.Reason?
    }

    /// TEXI flag 0x20: the first mip is a video stream.
    private static let videoFlag: UInt32 = 0x20
    /// Shorter sides keep RGBA8; their savings do not pay for an encode.
    private static let minimumCompressedSide = 256

    private struct WeakTexture {
        weak var texture: MTLTexture?
    }

    private struct SharedImage {
        let textures: [Int: WeakTexture]
        let primaryImageID: Int
        let sprites: [(imageID: Int, frame: WPEParityUniformSpriteFrame, duration: Double)]

        /// nil once any texture is gone or on another device.
        func image(device: MTLDevice, info: WPETexInfo,
                   selection: WPETexConditionalSelection?) -> WPEParityFrameDrawPlanner.Image? {
            guard let texture = textures[primaryImageID]?.texture, texture.device === device else { return nil }
            var steps: [WPEParityFrameDrawPlan.SpriteStep] = []
            for sprite in sprites {
                guard let spriteTexture = textures[sprite.imageID]?.texture else { return nil }
                steps.append(.init(frame: sprite.frame, texture: spriteTexture, duration: sprite.duration))
            }
            return WPEParityFrameDrawPlanner.Image(texture: texture, info: info, sprites: steps,
                                                   conditionalSelection: selection)
        }
    }

    private enum Slot {
        case loading(DispatchGroup)
        case ready(SharedImage)
    }

    /// The lock orders all access; published textures are .shaderRead and written only by replace() before publication.
    private static let shared = OSAllocatedUnfairLock<[SharedKey: Slot]>(uncheckedState: [:])

    /// `path` is the asset path that keys a process-wide share of the upload; nil uploads a private copy.
    static func load(span: WPEMappedByteSpan, device: MTLDevice,
                     userProperties: WPESceneJSONValue? = nil, path: String? = nil,
                     compression: WPEParityTextureCompression? = nil) throws -> WPEParityFrameDrawPlanner.Image {
        guard let path, let keyed = try? sharedKey(span: span, device: device, userProperties: userProperties,
                                                   path: path, compressed: compression != nil) else {
            return try upload(span: span, device: device, userProperties: userProperties, compression: compression,
                              digest: nil).image
        }
        let (key, info, selection) = keyed
        while true {
            let group = DispatchGroup()
            let (hit, pending) = withSlots { slots -> (WPEParityFrameDrawPlanner.Image?, DispatchGroup?) in
                slots = slots.filter {
                    guard case let .ready(image) = $0.value else { return true }
                    return image.textures[image.primaryImageID]?.texture != nil
                }
                switch slots[key] {
                case let .loading(other)?:
                    return (nil, other)
                case let .ready(image)?:
                    if let hit = image.image(device: device, info: info, selection: selection) {
                        return (hit, nil)
                    }
                case nil:
                    break
                }
                group.enter()
                slots[key] = .loading(group)
                return (nil, nil)
            }
            if let hit {
                return hit
            }
            if let pending {
                pending.wait()
                continue
            }
            defer { group.leave() }
            do {
                let uploaded = try upload(span: span, device: device, userProperties: userProperties,
                                          compression: compression, digest: key.digest)
                withSlots { $0[key] = .ready(uploaded.shared) }
                return uploaded.image
            } catch {
                withSlots { $0[key] = nil }
                throw error
            }
        }
    }

    private static func withSlots<R>(_ body: (inout [SharedKey: Slot]) -> R) -> R {
        shared.withLockUnchecked(body)
    }

    private static func sharedKey(
        span: WPEMappedByteSpan, device: MTLDevice, userProperties: WPESceneJSONValue?, path: String, compressed: Bool
    ) throws -> (SharedKey, WPETexInfo, WPETexConditionalSelection?) {
        let decoder = WPETexDecoder()
        let info = try decoder.probe(span: span).get()
        let variants = try decoder.extractRawMetadata(span: span).get().bitmap.conditionalVariants
        var selection: WPETexConditionalSelection?
        if !variants.isEmpty, let userProperties {
            selection = try WPETexConditionalSelection(variants: variants, properties: userProperties)
        }
        let digest = span.withUnsafeBytes { SHA256.hash(data: $0) }
        let key = SharedKey(registryID: device.registryID, path: path, digest: digest,
                            selection: selection?.flagsByVariantID, compressed: compressed)
        return (key, info, selection)
    }

    /// `digest` is the span's SHA-256 when the caller already has it.
    private static func upload(span: WPEMappedByteSpan, device: MTLDevice, userProperties: WPESceneJSONValue?,
                               compression: WPEParityTextureCompression?, digest: SHA256.Digest?) throws
        -> (image: WPEParityFrameDrawPlanner.Image, shared: SharedImage) {
        let decoder = WPETexDecoder()
        let info = try decoder.probe(span: span).get()
        if info.isVolume, info.width > 2048 || info.height > 2048 || info.depth > 2048 {
            throw WPEMetalTextureLoaderError.malformedPayload("Volume dimensions exceed the Metal 3D limit")
        }
        let cacheSource = try compression.map { compression in
            try (compression: compression, digest: digest ?? span.withUnsafeBytes { SHA256.hash(data: $0) },
                 raw: decoder.extractRawMetadata(span: span).get())
        }
        if let cacheSource, let cached = cachedUpload(raw: cacheSource.raw, span: span, info: info,
                                                      compression: cacheSource.compression,
                                                      digest: cacheSource.digest, device: device) {
            return cached
        }
        let payload = try decoder.extractTexturePayload(span: span, allowRawVolume: true,
                                                        conditionalProperties: userProperties).get()
        guard payload.videoPayload == nil else { throw WPETexDecodeError.unsupportedAnimation }
        guard !payload.hasConditionalVariants || payload.conditionalSelection != nil else {
            throw Failure.unsupportedConditionalVariants
        }
        guard let format = payload.info.format else {
            throw WPETexDecodeError.unsupportedFormat(code: payload.info.textureFormatCode)
        }
        let frames = payload.animationTrack?.frames ?? []
        if let missing = frames.first(where: { $0.samplingDescriptor == nil }) {
            throw Failure.unsupportedSpriteWithoutTEXS(imageID: missing.imageID)
        }
        let mapping = try WPEMetalTextureFormatMapper.mapping(
            for: format, capabilities: WPEMetalTextureCapabilities(device: device), colorSpace: .linear
        )
        let source = cacheSource.map { cacheSource in
            CompressionSource(compression: cacheSource.compression, digest: cacheSource.digest,
                              selection: payload.conditionalSelection?.flagsByVariantID,
                              levels: cacheSource.raw.bitmap.frames,
                              kept: keptReason(format: format, mapping: mapping, info: payload.info, device: device))
        }
        var textures: [Int: MTLTexture] = [:]
        func upload(_ mipmaps: [WPETexTextureMipmap], imageID: Int) throws -> MTLTexture {
            if let texture = textures[imageID] {
                return texture
            }
            let texture = try source.flatMap { compressedTexture(mipmaps, imageID: imageID, source: $0, device: device) }
                ?? makeTexture(mipmaps: mipmaps, format: format, mapping: mapping,
                               isVolume: payload.info.isVolume, device: device)
            textures[imageID] = texture
            return texture
        }
        var first: MTLTexture?
        if !payload.mipmaps.isEmpty {
            first = try upload(payload.mipmaps, imageID: 0)
        }
        let sprites = try frames.map { source in
            guard let sampling = source.samplingDescriptor else {
                throw Failure.unsupportedSpriteWithoutTEXS(imageID: source.imageID)
            }
            let texture = try upload(source.mipmaps, imageID: source.imageID)
            let size = SIMD2(Float(texture.width), Float(texture.height))
            let rotation = sampling.rotation
            let translation = sampling.translation
            let frame = WPEParityUniformSpriteFrame(
                x: translation.x * size.x, y: translation.y * size.y,
                widthX: rotation.x * size.x, widthY: rotation.y * size.y,
                heightX: rotation.z * size.x, heightY: rotation.w * size.y,
                imageWidth: size.x, imageHeight: size.y
            )
            return WPEParityFrameDrawPlan.SpriteStep(frame: frame, texture: texture, duration: source.duration)
        }
        guard let texture = first ?? sprites.first?.texture else { throw WPETexDecodeError.missingBitmapBlock }
        // The image retains only uploaded GPU resources and small metadata; decompressed mip bytes die here.
        let image = WPEParityFrameDrawPlanner.Image(texture: texture, info: info, sprites: sprites,
                                                    conditionalSelection: payload.conditionalSelection)
        let shared = SharedImage(
            textures: textures.mapValues { WeakTexture(texture: $0) }, primaryImageID: first == nil ? frames[0].imageID : 0,
            sprites: zip(frames, sprites).map { ($0.imageID, $1.frame, $1.duration) }
        )
        return (image, shared)
    }

    /// The texture WPE creates when a material texture has no payload (1400ec220.c:203-234): a 6×6 RGBA8 checker,
    /// texel i yellow when row parity differs from i's parity, else black (140170510).
    static func placeholder(device: MTLDevice) throws -> WPEParityFrameDrawPlanner.Image {
        let size = 6
        let bytes = (0 ..< size * size).flatMap { i -> [UInt8] in
            let lit: UInt8 = (i / size) & 1 != i & 1 ? 255 : 0
            return [lit, lit, 0, 255]
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes,
                        bytesPerRow: size * 4)
        let info = WPETexInfo(containerVersion: 0, infoVersion: 0, width: size, height: size, textureFormatCode: 0,
                              format: .rgba8888, mipmapCount: 1, flags: 9, imageWidth: size, imageHeight: size)
        return WPEParityFrameDrawPlanner.Image(texture: texture, info: info)
    }

    private static func keptReason(format: WPETexFormat, mapping: WPEMetalTextureFormatMapping, info: WPETexInfo,
                                   device: MTLDevice) -> WPEParityTextureCompressor.Reason? {
        if format != .rgba8888 || mapping.pixelFormat != .rgba8Unorm || info.isVolume {
            return .sourceFormat
        }
        if info.flags & videoFlag != 0 {
            return .video
        }
        // Point sampling reads single texels, which block compression shifts.
        if info.noInterpolation {
            return .pointSampled
        }
        return device.supportsFamily(.apple2) ? nil : .device
    }

    /// The cached ASTC upload of a single-image, non-sprite, unconditional TEX, found without decoding the file;
    /// nil when the file is another kind or the cache holds no blocks for it.
    private static func cachedUpload(raw: WPETexRawMetadata, span: WPEMappedByteSpan, info: WPETexInfo,
                                     compression: WPEParityTextureCompression, digest: SHA256.Digest,
                                     device: MTLDevice) -> (image: WPEParityFrameDrawPlanner.Image, shared: SharedImage)? {
        // A TEXS sprite block follows TEXB, so a file that ends at its last mip payload has none.
        guard raw.bitmap.frames.count == 1, raw.bitmap.conditionalVariants.isEmpty, let levels = raw.bitmap.frames.first,
              levels.last?.payload.range.upperBound == span.range.upperBound else { return nil }
        let key = WPEParityCompressedTextureCache.key(source: digest, selection: nil, imageID: 0, levels: levels)
        guard case let .blocks(blocks)? = compression.cache.read(key, levelByteCounts: blockByteCounts(levels)),
              let texture = try? makeASTCTexture(levels: levels, blocks: blocks, device: device) else { return nil }
        #if DEBUG
        compression.compressor.note(.cached)
        #endif
        return (WPEParityFrameDrawPlanner.Image(texture: texture, info: info),
                SharedImage(textures: [0: WeakTexture(texture: texture)], primaryImageID: 0, sprites: []))
    }

    /// nil keeps the authored RGBA8 upload: the image does not qualify, failed the PSNR gate or failed to encode.
    private static func compressedTexture(_ mipmaps: [WPETexTextureMipmap], imageID: Int, source: CompressionSource,
                                          device: MTLDevice) -> MTLTexture? {
        let (texture, outcome) = compress(mipmaps, imageID: imageID, source: source, device: device)
        #if DEBUG
        source.compression.compressor.note(outcome)
        #else
        _ = outcome
        #endif
        return texture
    }

    private static func compress(_ mipmaps: [WPETexTextureMipmap], imageID: Int, source: CompressionSource,
                                 device: MTLDevice) -> (MTLTexture?, WPEParityTextureCompressor.Outcome) {
        if let kept = source.kept {
            return (nil, .kept(kept))
        }
        guard let base = mipmaps.first, min(base.width, base.height) >= minimumCompressedSide else {
            return (nil, .kept(.small))
        }
        guard base.width <= 16384, base.height <= 16384, (try? WPETexMipValidation.decoded(mipmaps, format: .rgba8888)) != nil,
              mipmaps.allSatisfy({ $0.bytes.count >= $0.width * $0.height * 4 }) else {
            return (nil, .kept(.failed))
        }
        let shape = WPEParityTextureCompressor.alphaShape(mipmaps)
        if shape.hidesColor {
            return (nil, .kept(.hiddenColor))
        }
        let alpha: WPEParityTextureCompressor.AlphaMode = shape.opaque ? .opaque : .straight
        let cache = source.compression.cache
        let authored = source.levels[imageID]
        assert(authored.map { [$0.index, $0.width, $0.height] } == mipmaps.map { [$0.index, $0.width, $0.height] },
               "Decoded mip sizes differ from the authored mip table that keys the cache")
        let key = WPEParityCompressedTextureCache.key(source: source.digest, selection: source.selection,
                                                      imageID: imageID, levels: authored)
        switch cache.read(key, levelByteCounts: blockByteCounts(authored)) {
        case .rejected?:
            return (nil, .kept(.quality))
        case let .blocks(levels)?:
            guard let texture = try? makeASTCTexture(levels: authored, blocks: levels, device: device) else {
                return (nil, .kept(.failed))
            }
            return (texture, .cached)
        case nil:
            break
        }
        do {
            guard let levels = try source.compression.compressor.compress(mipmaps, alpha: alpha) else {
                cache.write(.rejected, for: key)
                return (nil, .kept(.quality))
            }
            let texture = try makeASTCTexture(levels: authored, blocks: levels, device: device)
            cache.write(.blocks(levels), for: key)
            return (texture, .encoded)
        } catch {
            return (nil, .kept(.failed))
        }
    }

    private static func blockByteCounts(_ levels: [WPETexMipmap]) -> [Int] {
        levels.map { WPEParityTextureCompressor.blockByteCount(width: $0.width, height: $0.height) }
    }

    private static func makeASTCTexture(levels: [WPETexMipmap], blocks: [Data],
                                        device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .astc_4x4_ldr, width: levels[0].width,
                                                                  height: levels[0].height, mipmapped: false)
        descriptor.mipmapLevelCount = levels.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        for (level, bytes) in zip(levels, blocks) {
            try bytes.withUnsafeBytes { raw in
                guard let pointer = raw.baseAddress else {
                    throw WPEMetalTextureLoaderError.malformedPayload("Empty compressed mip \(level.index)")
                }
                texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height), mipmapLevel: level.index,
                                withBytes: pointer,
                                bytesPerRow: WPEParityTextureCompressor.blocksPerRow(level.width)
                                    * WPEParityTextureCompressor.blockBytes)
            }
        }
        return texture
    }

    private static func makeTexture(mipmaps: [WPETexTextureMipmap], format: WPETexFormat,
                                    mapping: WPEMetalTextureFormatMapping, isVolume: Bool,
                                    device: MTLDevice) throws -> MTLTexture {
        try WPETexMipValidation.decoded(mipmaps, format: format)
        // Apple's Metal feature table specifies 2048 for all three volume axes. Reject before calling
        // Metal so malformed files cannot reach a descriptor-validation assertion.
        let maximumDimension = isVolume ? 2048 : 16384
        guard let base = mipmaps.first, base.width <= maximumDimension, base.height <= maximumDimension,
              base.depth <= (isVolume ? maximumDimension : 1) else {
            throw WPEMetalTextureLoaderError.malformedPayload("Missing or oversized base mip")
        }
        let layouts = try mipmaps.map { level in
            let layout = try WPETexMipValidation.layout(format: format, width: level.width, height: level.height,
                                                        depth: level.depth)
            guard level.bytes.count >= layout.byteCount else {
                throw WPEMetalTextureLoaderError.malformedPayload("Missing or truncated mip \(level.index)")
            }
            return layout
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = isVolume ? .type3D : .type2D
        descriptor.pixelFormat = mapping.pixelFormat
        descriptor.width = base.width
        descriptor.height = base.height
        descriptor.depth = base.depth
        descriptor.mipmapLevelCount = mipmaps.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        for (level, layout) in zip(mipmaps, layouts) {
            try level.bytes.withUnsafeBytes { bytes in
                guard let pointer = bytes.baseAddress else {
                    throw WPEMetalTextureLoaderError.malformedPayload("Empty mip \(level.index)")
                }
                if isVolume {
                    texture.replace(region: MTLRegionMake3D(0, 0, 0, level.width, level.height, level.depth),
                                    mipmapLevel: level.index, slice: 0, withBytes: pointer,
                                    bytesPerRow: layout.bytesPerRow,
                                    bytesPerImage: level.depth > 1 ? layout.bytesPerImage : 0)
                } else {
                    texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height), mipmapLevel: level.index,
                                    withBytes: pointer, bytesPerRow: layout.bytesPerRow)
                }
            }
        }
        return texture
    }
}
#endif
