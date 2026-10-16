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
    }

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
                     userProperties: WPESceneJSONValue? = nil, path: String? = nil) throws -> WPEParityFrameDrawPlanner.Image {
        guard let path, let keyed = try? sharedKey(span: span, device: device, userProperties: userProperties,
                                                   path: path) else {
            return try upload(span: span, device: device, userProperties: userProperties).image
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
                let uploaded = try upload(span: span, device: device, userProperties: userProperties)
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
        span: WPEMappedByteSpan, device: MTLDevice, userProperties: WPESceneJSONValue?, path: String
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
                            selection: selection?.flagsByVariantID)
        return (key, info, selection)
    }

    private static func upload(span: WPEMappedByteSpan, device: MTLDevice,
                               userProperties: WPESceneJSONValue?) throws
        -> (image: WPEParityFrameDrawPlanner.Image, shared: SharedImage) {
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
