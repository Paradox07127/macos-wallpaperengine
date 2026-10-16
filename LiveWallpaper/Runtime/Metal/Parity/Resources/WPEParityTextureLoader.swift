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
            case .unsupportedConditionalVariants: "Conditional TEX requires a typed user-property snapshot"
            case let .unsupportedSpriteWithoutTEXS(imageID): "Sprite image \(imageID) has no supported TEXS sampling descriptor"
            }
        }
    }

    static func load(span: WPEMappedByteSpan, device: MTLDevice,
                     userProperties: WPESceneJSONValue? = nil) throws -> WPEParityFrameDrawPlanner.Image {
        let decoder = WPETexDecoder()
        let info = try decoder.probe(span: span).get()
        if info.isVolume, info.width > 2048 || info.height > 2048 || info.depth > 2048 {
            throw WPEMetalTextureLoaderError.malformedPayload("Volume dimensions exceed the Metal 3D limit")
        }
        let payload = try decoder.extractTexturePayload(span: span, scope: .fullChain, allowRawVolume: true,
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
        var textures: [Int: MTLTexture] = [:]
        func upload(_ mipmaps: [WPETexTextureMipmap], imageID: Int) throws -> MTLTexture {
            if let texture = textures[imageID] {
                return texture
            }
            let texture = try makeTexture(mipmaps: mipmaps, format: format, mapping: mapping,
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
        return WPEParityFrameDrawPlanner.Image(texture: texture, info: info, sprites: sprites,
                                               conditionalSelection: payload.conditionalSelection)
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
