#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

/// Uploads native TEX resources once while planning a scene. Raw formats retain their channels and authored
/// mip chain; only TEXB's encoded-image payload uses the decoder's ImageIO bridge. No usage/path swizzle policy.
enum WPEParityTextureLoader {
    enum Failure: Error, LocalizedError {
        case unsupportedConditionalVariants
        case unsupportedSpriteWithoutTEXS(imageID: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedConditionalVariants: "TEXB conditional image selection and patches are not yet supported"
            case let .unsupportedSpriteWithoutTEXS(imageID): "Sprite image \(imageID) has no supported TEXS sampling descriptor"
            }
        }
    }

    struct Sprite {
        let frame: WPEParityUniformSpriteFrame
        let texture: MTLTexture
        let duration: Double
    }

    struct Loaded {
        let texture: MTLTexture
        /// Authored TEXI fields, including source format and flags. The texture describes the actual upload format.
        let info: WPETexInfo
        let sprites: [Sprite]
    }

    static func load(span: WPEMappedByteSpan, device: MTLDevice) throws -> Loaded {
        let decoder = WPETexDecoder()
        let info = try decoder.probe(span: span).get()
        // The native depth field is known, but volume slice layout/encoded unfolding is not yet proved.
        // Reject before any encoded image can be flattened to a successful 2D upload.
        guard !info.isVolume else { throw WPETexDecodeError.unsupportedTextureDimension(depth: info.depth) }
        let payload = try decoder.extractTexturePayload(span: span, scope: .fullChain).get()
        guard payload.videoPayload == nil else { throw WPETexDecodeError.unsupportedAnimation }
        guard !payload.hasConditionalVariants else { throw Failure.unsupportedConditionalVariants }
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
        var textures: [Int: MTLTexture] = [:]
        func upload(_ mipmaps: [WPETexTextureMipmap], imageID: Int) throws -> MTLTexture {
            if let texture = textures[imageID] {
                return texture
            }
            let texture = try makeTexture(mipmaps: mipmaps, format: format, mapping: mapping, device: device)
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
            return Sprite(frame: frame, texture: texture, duration: source.duration)
        }
        guard let texture = first ?? sprites.first?.texture else { throw WPETexDecodeError.missingBitmapBlock }
        // Loaded retains only uploaded GPU resources and small metadata; decompressed mip bytes die here.
        return Loaded(texture: texture, info: info, sprites: sprites)
    }

    private static func makeTexture(mipmaps: [WPETexTextureMipmap], format: WPETexFormat,
                                    mapping: WPEMetalTextureFormatMapping, device: MTLDevice) throws -> MTLTexture {
        try WPETexMipValidation.decoded(mipmaps, format: format)
        guard let base = mipmaps.first, base.width <= 16384, base.height <= 16384 else {
            throw WPEMetalTextureLoaderError.malformedPayload("Missing or oversized base mip")
        }
        let layouts = try mipmaps.map { level in
            let layout = try WPETexMipValidation.layout(format: format, width: level.width, height: level.height)
            guard level.bytes.count >= layout.byteCount else {
                throw WPEMetalTextureLoaderError.malformedPayload("Missing or truncated mip \(level.index)")
            }
            return layout
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mapping.pixelFormat,
                                                                  width: base.width, height: base.height,
                                                                  mipmapped: mipmaps.count > 1)
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
                texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height), mipmapLevel: level.index,
                                withBytes: pointer, bytesPerRow: layout.bytesPerRow)
            }
        }
        return texture
    }
}
#endif
