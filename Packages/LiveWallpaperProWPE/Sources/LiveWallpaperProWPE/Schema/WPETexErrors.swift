import CoreGraphics
import Foundation
import LiveWallpaperCore

public enum WPETexFormat: Int, Sendable, Equatable {
    case rgba8888 = 0
    case dxt5 = 4   // BC3
    case dxt3 = 6   // BC2
    case dxt1 = 7   // BC1
    case rg88 = 8
    case r8 = 9
    case bc7 = 12
    case rgba1010102 = 13

    /// nil for block-compressed (BC) formats where the unit is a 4×4 block.
    public var bytesPerPixel: Int? {
        switch self {
        case .rgba8888, .rgba1010102: return 4
        case .r8: return 1
        case .rg88: return 2
        case .dxt1, .dxt3, .dxt5, .bc7: return nil
        }
    }

    public var bytesPerBlock: Int? {
        switch self {
        case .dxt1: return 8
        case .dxt3, .dxt5, .bc7: return 16
        default: return nil
        }
    }

    public func expectedByteCount(width: Int, height: Int) -> Int {
        if let bpp = bytesPerPixel {
            return max(width, 1) * max(height, 1) * bpp
        }
        guard let bpb = bytesPerBlock else { return 0 }
        let blocksW = max((width + 3) / 4, 1)
        let blocksH = max((height + 3) / 4, 1)
        return blocksW * blocksH * bpb
    }

    public var debugLabel: String {
        switch self {
        case .rgba8888:    return "RGBA8888"
        case .dxt5:        return "DXT5 (BC3)"
        case .dxt3:        return "DXT3 (BC2)"
        case .dxt1:        return "DXT1 (BC1)"
        case .r8:          return "R8"
        case .rg88:        return "RG88"
        case .rgba1010102: return "RGBA1010102"
        case .bc7:         return "BC7"
        }
    }

    public var isPhase21Decodable: Bool {
        switch self {
        case .rgba8888, .r8, .rg88:
            return true
        case .dxt1, .dxt3, .dxt5, .bc7:
            return false
        case .rgba1010102:
            return false
        }
    }
}

public enum WPETexDecodeError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedContainer(magic: String)
    case unsupportedBlock(magic: String)
    case missingInfoBlock
    case missingBitmapBlock
    case unsupportedFormat(code: Int)
    case unsupportedAnimation
    case invalidDimensions(width: Int, height: Int)
    case truncatedBlock(block: String, offset: Int)
    case mipmapOutOfBounds(index: Int)
    case decompressionFailed(mipmap: Int)
    case decodeFailed(mipmap: Int, detail: String)
    case metalUnavailable(format: WPETexFormat)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let magic):
            return String(localized: "error.texture.decode.unsupported_container", defaultValue: ".tex container '\(magic)' is unrecognised.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex container magic is unsupported.")
        case .unsupportedBlock(let magic):
            return String(localized: "error.texture.decode.unsupported_block", defaultValue: ".tex block '\(magic)' is unrecognised.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex block magic is unsupported.")
        case .missingInfoBlock:
            return String(localized: "error.texture.decode.missing_info_block", defaultValue: ".tex file is missing the TEXI info block.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXI block.")
        case .missingBitmapBlock:
            return String(localized: "error.texture.decode.missing_bitmap_block", defaultValue: ".tex file is missing the TEXB bitmap block.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXB block.")
        case .unsupportedFormat(let code):
            return String(localized: "error.texture.decode.unsupported_format", defaultValue: ".tex format code \(code) is not yet supported.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file uses an unsupported format code.")
        case .unsupportedAnimation:
            return String(localized: "error.texture.decode.unsupported_animation", defaultValue: ".tex animation/sequence frames are not supported.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file contains unsupported animation frames.")
        case .invalidDimensions(let w, let h):
            return String(localized: "error.texture.decode.invalid_dimensions", defaultValue: ".tex declares invalid dimensions \(w)×\(h).", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file declares invalid pixel dimensions.")
        case .truncatedBlock(let block, let offset):
            return String(localized: "error.texture.decode.truncated_block", defaultValue: ".tex block '\(block)' truncated at offset \(offset).", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex block ends before its declared payload.")
        case .mipmapOutOfBounds(let index):
            return String(localized: "error.texture.decode.mipmap_out_of_bounds", defaultValue: ".tex mipmap index \(index) is out of bounds.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap index is invalid.")
        case .decompressionFailed(let mipmap):
            return String(localized: "error.texture.decode.decompression_failed", defaultValue: ".tex mipmap \(mipmap) decompression failed.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decompressed.")
        case .decodeFailed(let mipmap, let detail):
            return String(localized: "error.texture.decode.decode_failed", defaultValue: ".tex mipmap \(mipmap) decode failed: \(detail)", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decoded.")
        case .metalUnavailable(let format):
            return String(localized: "error.texture.decode.metal_unavailable", defaultValue: "Cannot decode \(format.debugLabel) without Metal support on this machine.", bundle: .appLanguage, comment: "Error shown when a texture format requires Metal support that is unavailable.")
        }
    }
}

// MARK: - Value types parsed out of the container

/// Uninterpreted Int32 after flag `0x40`. It is not a texture dimension and does not imply a 3D texture.
public struct WPETexFlag0x40Extension: Sendable, Equatable {
    public let rawValue: Int32
    public let sourceRange: Range<Int>

    public init(rawValue: Int32, sourceRange: Range<Int>) {
        self.rawValue = rawValue
        self.sourceRange = sourceRange
    }
}

/// `imageWidth`/`imageHeight`/`unknownInt0` are TEXI fields the decoder reads but does not act on. Modal `.tex` records padded atlas size, not logical image size, in `width`/`height`.
public struct WPETexInfo: Sendable, Equatable {
    public let containerVersion: Int
    public let infoVersion: Int
    public let width: Int
    public let height: Int
    public let textureFormatCode: Int
    public let format: WPETexFormat?
    public let mipmapCount: Int
    public let flags: UInt32
    public let imageWidth: Int
    public let imageHeight: Int
    public let unknownInt0: Int32
    public let flag0x40Extension: WPETexFlag0x40Extension?

    public init(
        containerVersion: Int,
        infoVersion: Int,
        width: Int,
        height: Int,
        textureFormatCode: Int,
        format: WPETexFormat?,
        mipmapCount: Int,
        flags: UInt32,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        unknownInt0: Int32 = 0,
        flag0x40Extension: WPETexFlag0x40Extension? = nil
    ) {
        self.containerVersion = containerVersion
        self.infoVersion = infoVersion
        self.width = width
        self.height = height
        self.textureFormatCode = textureFormatCode
        self.format = format
        self.mipmapCount = mipmapCount
        self.flags = flags
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.unknownInt0 = unknownInt0
        self.flag0x40Extension = flag0x40Extension
    }

    public var dimensionsLooksValid: Bool {
        width > 0 && height > 0
            && width <= 16_384 && height <= 16_384
    }

    /// TEXI flag bit 0x1 = NoInterpolation: sample with nearest (point) filtering
    /// instead of linear — pixel-art / palette maps (e.g. `camera.tex`).
    public static let noInterpolationFlag: UInt32 = 0x0000_0001

    /// TEXI bit 0x2 = ClampUVs (must not tile). Unset (the default) tiles with `repeat`, required for scrolled maps whose UVs leave [0,1].
    public static let clampUVsFlag: UInt32 = 0x0000_0002

    /// TEXI flag bit `0x40` appends one uninterpreted `Int32` after
    /// `unknownInt0` and before the next block magic.
    public static let rawExtensionFlag: UInt32 = 0x0000_0040

    /// Sample with clamp-to-edge (`true`) vs `repeat`/tile (`false`). See `clampUVsFlag`.
    public var clampUVs: Bool { flags & Self.clampUVsFlag != 0 }

    /// Sample with nearest (`true`) vs linear (`false`) filtering. See `noInterpolationFlag`.
    public var noInterpolation: Bool { flags & Self.noInterpolationFlag != 0 }

    /// Sample as LUMINANCE_ALPHA → (R, R, R, G): R luminance to RGB, G alpha. Uploading RG88 as `.rg8Unorm` samples (R, G, 0, 1) and renders opaque.
    public var isRG88LuminanceAlpha: Bool {
        format == .rg88
    }
}

/// `condition` is a NUL-terminated ASCII run used as a conditional-mip predicate in the official engine.
public struct WPETexMipmapV4Fields: Sendable, Equatable {
    public let param1: Int32
    public let param2: Int32
    public let condition: String
    public let param3: Int32

    public init(param1: Int32, param2: Int32, condition: String, param3: Int32) {
        self.param1 = param1
        self.param2 = param2
        self.condition = condition
        self.param3 = param3
    }
}

/// `v4Fields` is populated only when parent `WPETexBitmapBlock.version == 4`; older containers leave it nil.
public struct WPETexMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let storedByteCount: Int
    public let decompressedByteCount: Int?
    /// View into the container bytes (mmap-backed when the provider maps the
    /// file) — the compressed payload is never duplicated onto the heap.
    public let payload: WPEMappedByteSpan
    public let isCompressed: Bool
    public let v4Fields: WPETexMipmapV4Fields?

    public init(
        index: Int,
        width: Int,
        height: Int,
        storedByteCount: Int,
        decompressedByteCount: Int?,
        payload: WPEMappedByteSpan,
        isCompressed: Bool,
        v4Fields: WPETexMipmapV4Fields? = nil
    ) {
        self.index = index
        self.width = width
        self.height = height
        self.storedByteCount = storedByteCount
        self.decompressedByteCount = decompressedByteCount
        self.payload = payload
        self.isCompressed = isCompressed
        self.v4Fields = v4Fields
    }
}

public struct WPETexRawMetadata: Sendable, Equatable {
    public let info: WPETexInfo
    public let bitmap: WPETexBitmapBlock

    public init(info: WPETexInfo, bitmap: WPETexBitmapBlock) {
        self.info = info
        self.bitmap = bitmap
    }
}

public struct WPETexBitmapBlock: Sendable, Equatable {
    public let version: Int
    public let sourceImageFormatCode: Int?
    public let isVideoPayload: Bool
    public let frames: [[WPETexMipmap]]

    public init(version: Int, sourceImageFormatCode: Int?, isVideoPayload: Bool, frames: [[WPETexMipmap]]) {
        self.version = version
        self.sourceImageFormatCode = sourceImageFormatCode
        self.isVideoPayload = isVideoPayload
        self.frames = frames
    }

    public var mipmaps: [WPETexMipmap] {
        frames.first ?? []
    }

    public var largestMipmap: WPETexMipmap? {
        mipmaps.first
    }

    public var usesEncodedImagePayload: Bool {
        guard let sourceImageFormatCode else { return false }
        return sourceImageFormatCode != -1 && !isVideoPayload
    }
}

public struct WPETexAnimationTrack: Sendable, Equatable {
    public static let defaultFrameRate: Double = 25

    public let frames: [WPETexAnimationFrame]
    public let frameRate: Double
    public let loop: Bool

    public init(frames: [WPETexAnimationFrame], frameRate: Double, loop: Bool) {
        self.frames = frames
        self.frameRate = frameRate
        self.loop = loop
    }
}

/// Wallpaper Engine samples as `translation + uv.x * rotation.xy + uv.y * rotation.zw`. Values are normalized against that frame's source-image dimensions.
public struct WPETexSpriteSamplingDescriptor: Sendable, Equatable {
    public let rotation: SIMD4<Float>
    public let translation: SIMD2<Float>

    public init(rotation: SIMD4<Float>, translation: SIMD2<Float>) {
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = WPETexSpriteSamplingDescriptor(
        rotation: SIMD4<Float>(1, 0, 0, 1),
        translation: SIMD2<Float>(0, 0)
    )
}

public struct WPETexAnimationFrame: Sendable, Equatable {
    public let imageID: Int
    public let duration: TimeInterval
    public let mipmaps: [WPETexTextureMipmap]
    /// `nil` means use the whole image (legacy `.tex` files that omit TEXS).
    public let subRect: CGRect?
    /// Full affine sampling transform retained from TEXS. `nil` means this
    /// frame was synthesized without TEXS metadata, not an identity fallback.
    public let samplingDescriptor: WPETexSpriteSamplingDescriptor?

    public init(
        imageID: Int,
        duration: TimeInterval,
        mipmaps: [WPETexTextureMipmap],
        subRect: CGRect? = nil,
        samplingDescriptor: WPETexSpriteSamplingDescriptor? = nil
    ) {
        self.imageID = imageID
        self.duration = duration
        self.mipmaps = mipmaps
        self.subRect = subRect
        self.samplingDescriptor = samplingDescriptor
    }
}

public struct WPETexCompressedMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let isCompressed: Bool
    /// View into the container bytes (mmap-backed when the provider maps the
    /// file); the lazy streaming source inflates directly out of the mapping.
    public let compressedBytes: WPEMappedByteSpan
    public let decompressedByteCount: Int

    public init(
        index: Int,
        width: Int,
        height: Int,
        isCompressed: Bool,
        compressedBytes: WPEMappedByteSpan,
        decompressedByteCount: Int
    ) {
        self.index = index
        self.width = width
        self.height = height
        self.isCompressed = isCompressed
        self.compressedBytes = compressedBytes
        self.decompressedByteCount = decompressedByteCount
    }

    public init(
        index: Int,
        width: Int,
        height: Int,
        isCompressed: Bool,
        compressedBytes: Data,
        decompressedByteCount: Int
    ) {
        self.init(
            index: index,
            width: width,
            height: height,
            isCompressed: isCompressed,
            compressedBytes: WPEMappedByteSpan(data: compressedBytes),
            decompressedByteCount: decompressedByteCount
        )
    }
}

public struct WPETexCompressedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let payloads: [WPETexCompressedMipmap]

    public init(width: Int, height: Int, payloads: [WPETexCompressedMipmap]) {
        self.width = width
        self.height = height
        self.payloads = payloads
    }
}

public struct WPETexStreamingFrame: Sendable, Equatable {
    public let imageID: Int
    public let subRect: CGRect
    public let duration: TimeInterval
    public let samplingDescriptor: WPETexSpriteSamplingDescriptor?

    public init(
        imageID: Int,
        subRect: CGRect,
        duration: TimeInterval,
        samplingDescriptor: WPETexSpriteSamplingDescriptor? = nil
    ) {
        self.imageID = imageID
        self.subRect = subRect
        self.duration = duration
        self.samplingDescriptor = samplingDescriptor
    }
}

/// Lazy-decode counterpart to `WPETexTexturePayload`. Peak CPU footprint is mapped `.tex` bytes plus the shared decoded-frame budget, not the full eager-decode total. See `WPEAnimatedFrameByteCache`.
public struct WPETexStreamingPayload: Sendable, Equatable {
    public let info: WPETexInfo
    public let compressedImages: [WPETexCompressedImage]
    public let frames: [WPETexStreamingFrame]
    public let frameRate: Double
    public let loop: Bool

    public init(
        info: WPETexInfo,
        compressedImages: [WPETexCompressedImage],
        frames: [WPETexStreamingFrame],
        frameRate: Double,
        loop: Bool
    ) {
        self.info = info
        self.compressedImages = compressedImages
        self.frames = frames
        self.frameRate = frameRate
        self.loop = loop
    }

    public var totalUncompressedImageBytes: Int {
        compressedImages.reduce(0) { total, image in
            total + (image.payloads.first?.decompressedByteCount
                ?? max(image.width, 1) * max(image.height, 1) * 4)
        }
    }
}

public struct WPETexVideoPayload: Sendable, Equatable {
    public let bytes: Data
    public let fileExtension: String

    public init(bytes: Data, fileExtension: String = "mp4") {
        self.bytes = bytes
        self.fileExtension = fileExtension
    }
}

public struct WPETexTexturePayload: Sendable, Equatable {
    public let info: WPETexInfo
    public let mipmaps: [WPETexTextureMipmap]
    public let animationTrack: WPETexAnimationTrack?
    public let videoPayload: WPETexVideoPayload?

    private let explicitAnimationFlag: Bool

    public init(
        info: WPETexInfo,
        mipmaps: [WPETexTextureMipmap],
        hasAnimationFrames: Bool,
        animationTrack: WPETexAnimationTrack? = nil,
        videoPayload: WPETexVideoPayload? = nil
    ) {
        self.info = info
        self.mipmaps = mipmaps
        self.explicitAnimationFlag = hasAnimationFrames
        self.animationTrack = animationTrack
        self.videoPayload = videoPayload
    }

    public var hasAnimationFrames: Bool {
        explicitAnimationFlag || animationTrack != nil
    }

    public var largestMipmap: WPETexTextureMipmap? {
        mipmaps.first
    }
}

public struct WPETexTextureMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let bytes: Data

    public init(index: Int, width: Int, height: Int, bytes: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

public struct DecodedRGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension DecodedRGBAImage {
    public func makeCGImage() throws -> CGImage {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "CGDataProvider init failed")
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "CGImage init failed")
        }
        return image
    }
}
