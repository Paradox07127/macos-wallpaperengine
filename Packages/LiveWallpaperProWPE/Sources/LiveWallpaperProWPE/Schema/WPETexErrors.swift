import CoreGraphics
import Foundation
import LiveWallpaperCore

public enum WPETexFormat: Int, Sendable, Equatable {
    case rgba8888 = 0
    case dxt5 = 4 // BC3
    case dxt3 = 6 // BC2
    case dxt1 = 7 // BC1
    case rg88 = 8
    case r8 = 9
    case rg16Float = 10
    case r16Float = 11
    case bc7 = 12
    case rgba1010102 = 13
    case rgba16Float = 14
    case rgba16Float15 = 15
    case r32Float = 16
    case rgba16Unorm = 17
    case rgba16Unorm18 = 18
    case rgba16Snorm = 19
    case rgba16Snorm20 = 20

    /// nil for block-compressed (BC) formats where the unit is a 4×4 block.
    public var bytesPerPixel: Int? {
        switch self {
        case .rgba8888, .rgba1010102, .rg16Float, .r32Float: 4
        case .r8: 1
        case .rg88, .r16Float: 2
        case .rgba16Float, .rgba16Float15, .rgba16Unorm, .rgba16Unorm18, .rgba16Snorm, .rgba16Snorm20: 8
        case .dxt1, .dxt3, .dxt5, .bc7: nil
        }
    }

    public var bytesPerBlock: Int? {
        switch self {
        case .dxt1: 8
        case .dxt3, .dxt5, .bc7: 16
        default: nil
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
        case .rgba8888: "RGBA8888"
        case .dxt5: "DXT5 (BC3)"
        case .dxt3: "DXT3 (BC2)"
        case .dxt1: "DXT1 (BC1)"
        case .r8: "R8"
        case .rg88: "RG88"
        case .rgba1010102: "RGBA1010102"
        case .bc7: "BC7"
        case .rg16Float: "RG16 FLOAT"
        case .r16Float: "R16 FLOAT"
        case .rgba16Float, .rgba16Float15: "RGBA16 FLOAT"
        case .r32Float: "R32 FLOAT"
        case .rgba16Unorm, .rgba16Unorm18: "RGBA16 UNORM"
        case .rgba16Snorm, .rgba16Snorm20: "RGBA16 SNORM"
        }
    }

    /// These native formats are supported only as raw TEXB bytes. Their encoded-image interpretation is unproved.
    /// Numeric suffixes retain distinct authored codes that share a native DXGI resource format.
    public var requiresRawPayload: Bool {
        switch self {
        case .rg16Float, .r16Float, .rgba16Float, .rgba16Float15, .r32Float,
             .rgba16Unorm, .rgba16Unorm18, .rgba16Snorm, .rgba16Snorm20: true
        default: false
        }
    }

    public var isPhase21Decodable: Bool {
        switch self {
        case .rgba8888, .r8, .rg88:
            true
        case .dxt1, .dxt3, .dxt5, .bc7:
            false
        case .rgba1010102, .rg16Float, .r16Float, .rgba16Float, .rgba16Float15, .r32Float,
             .rgba16Unorm, .rgba16Unorm18, .rgba16Snorm, .rgba16Snorm20:
            false
        }
    }
}

public enum WPETexDecodeError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedContainer(magic: String)
    case unsupportedBlock(magic: String)
    case missingInfoBlock
    case missingBitmapBlock
    case unsupportedFormat(code: Int)
    case unsupportedTextureDimension(depth: Int)
    case unsupportedAnimation
    case invalidDimensions(width: Int, height: Int)
    case truncatedBlock(block: String, offset: Int)
    case mipmapOutOfBounds(index: Int)
    case decompressionFailed(mipmap: Int)
    case decodeFailed(mipmap: Int, detail: String)
    case metalUnavailable(format: WPETexFormat)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedContainer(magic):
            String(localized: "error.texture.decode.unsupported_container", defaultValue: ".tex container '\(magic)' is unrecognised.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex container magic is unsupported.")
        case let .unsupportedBlock(magic):
            String(localized: "error.texture.decode.unsupported_block", defaultValue: ".tex block '\(magic)' is unrecognised.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex block magic is unsupported.")
        case .missingInfoBlock:
            String(localized: "error.texture.decode.missing_info_block", defaultValue: ".tex file is missing the TEXI info block.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXI block.")
        case .missingBitmapBlock:
            String(localized: "error.texture.decode.missing_bitmap_block", defaultValue: ".tex file is missing the TEXB bitmap block.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file is missing the TEXB block.")
        case let .unsupportedFormat(code):
            String(localized: "error.texture.decode.unsupported_format", defaultValue: ".tex format code \(code) is not yet supported.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file uses an unsupported format code.")
        case let .unsupportedTextureDimension(depth):
            String(localized: "error.texture.decode.unsupported_dimension", defaultValue: ".tex volume textures (depth \(depth)) are not yet supported.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine volume texture cannot be uploaded.")
        case .unsupportedAnimation:
            String(localized: "error.texture.decode.unsupported_animation", defaultValue: ".tex animation/sequence frames are not supported.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file contains unsupported animation frames.")
        case let .invalidDimensions(w, h):
            String(localized: "error.texture.decode.invalid_dimensions", defaultValue: ".tex declares invalid dimensions \(w)×\(h).", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex file declares invalid pixel dimensions.")
        case let .truncatedBlock(block, offset):
            String(localized: "error.texture.decode.truncated_block", defaultValue: ".tex block '\(block)' truncated at offset \(offset).", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex block ends before its declared payload.")
        case let .mipmapOutOfBounds(index):
            String(localized: "error.texture.decode.mipmap_out_of_bounds", defaultValue: ".tex mipmap index \(index) is out of bounds.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap index is invalid.")
        case let .decompressionFailed(mipmap):
            String(localized: "error.texture.decode.decompression_failed", defaultValue: ".tex mipmap \(mipmap) decompression failed.", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decompressed.")
        case let .decodeFailed(mipmap, detail):
            String(localized: "error.texture.decode.decode_failed", defaultValue: ".tex mipmap \(mipmap) decode failed: \(detail)", bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine .tex mipmap cannot be decoded.")
        case let .metalUnavailable(format):
            String(localized: "error.texture.decode.metal_unavailable", defaultValue: "Cannot decode \(format.debugLabel) without Metal support on this machine.", bundle: .appLanguage, comment: "Error shown when a texture format requires Metal support that is unavailable.")
        }
    }
}

// MARK: - Value types parsed out of the container

/// TEXI's conditional depth field. Native 14015c760 reads it before the versioned tail word;
/// 1400ec220 uses it in the volume texture descriptor when flag 0x40 is set.
public struct WPETexFlag0x40Extension: Sendable, Equatable {
    public let rawValue: Int32
    public let sourceRange: Range<Int>

    public init(rawValue: Int32, sourceRange: Range<Int>) {
        self.rawValue = rawValue
        self.sourceRange = sourceRange
    }
}

/// `unknownInt0` preserves TEXI's versioned tail word. `width`/`height` describe the texture,
/// while `imageWidth`/`imageHeight` retain the authored image extent.
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

    public var isVolume: Bool {
        flags & Self.rawExtensionFlag != 0
    }

    public var depth: Int {
        flag0x40Extension.map { Int(UInt32(bitPattern: $0.rawValue)) } ?? 1
    }

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
            && width <= 16384 && height <= 16384
    }

    /// TEXI flag bit 0x1 = NoInterpolation: sample with nearest (point) filtering
    /// instead of linear — pixel-art / palette maps (e.g. `camera.tex`).
    public static let noInterpolationFlag: UInt32 = 0x0000_0001

    /// TEXI bit 0x2 = ClampUVs (must not tile). Unset (the default) tiles with `repeat`, required for scrolled maps whose UVs leave [0,1].
    public static let clampUVsFlag: UInt32 = 0x0000_0002

    /// TEXI flag bit `0x40` adds depth before the versioned tail word and adds depth to every mip record.
    public static let rawExtensionFlag: UInt32 = 0x0000_0040

    /// Sample with clamp-to-edge (`true`) vs `repeat`/tile (`false`). See `clampUVsFlag`.
    public var clampUVs: Bool {
        flags & Self.clampUVsFlag != 0
    }

    /// Sample with nearest (`true`) vs linear (`false`) filtering. See `noInterpolationFlag`.
    public var noInterpolation: Bool {
        flags & Self.noInterpolationFlag != 0
    }

    /// Sample as LUMINANCE_ALPHA → (R, R, R, G): R luminance to RGB, G alpha. Uploading RG88 as `.rg8Unorm` samples (R, G, 0, 1) and renders opaque.
    public var isRG88LuminanceAlpha: Bool {
        format == .rg88
    }
}

public struct WPETexMipmap: Sendable, Equatable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let depth: Int
    public let storedByteCount: Int
    public let decompressedByteCount: Int?
    /// View into the container bytes (mmap-backed when the provider maps the
    /// file) — the compressed payload is never duplicated onto the heap.
    public let payload: WPEMappedByteSpan
    public let isCompressed: Bool
    public let compressionFlags: UInt32

    public init(
        index: Int,
        width: Int,
        height: Int,
        storedByteCount: Int,
        decompressedByteCount: Int?,
        payload: WPEMappedByteSpan,
        isCompressed: Bool,
        depth: Int = 1,
        compressionFlags: UInt32 = 0
    ) {
        self.index = index
        self.width = width
        self.height = height
        self.depth = depth
        self.storedByteCount = storedByteCount
        self.decompressedByteCount = decompressedByteCount
        self.payload = payload
        self.isCompressed = isCompressed
        self.compressionFlags = compressionFlags
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

/// One TEXB0004 record. Selection is by variantID; replacement comes from the table flags,
/// never from the rectangle.
public struct WPETexConditionalVariantMipmap: Sendable, Equatable {
    public let variantID: UInt32
    public let imageIndex: Int
    public let mipIndex: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Image decoder format domain, not TEXI's texture format.
    public let formatCode: Int
    public let payload: WPEMappedByteSpan

    public init(x: Int, y: Int, width: Int, height: Int, formatCode: Int, payload: WPEMappedByteSpan,
                variantID: UInt32 = 0, imageIndex: Int = 0, mipIndex: Int = 0) {
        self.variantID = variantID
        self.imageIndex = imageIndex
        self.mipIndex = mipIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.formatCode = formatCode
        self.payload = payload
    }
}

/// The original three unsigned table words plus the NUL-delimited JSON bytes (without the NUL).
public struct WPETexConditionalVariant: Sendable, Equatable {
    public let groupKey: UInt32
    public let variantID: UInt32
    public let flags: UInt32
    public let conditionBytes: Data

    public init(groupKey: UInt32, variantID: UInt32, flags: UInt32, conditionBytes: Data) {
        self.groupKey = groupKey
        self.variantID = variantID
        self.flags = flags
        self.conditionBytes = conditionBytes
    }
}

public struct WPETexBitmapBlock: Sendable, Equatable {
    public let version: Int
    public let sourceImageFormatCode: Int?
    public let isVideoPayload: Bool
    public let frames: [[WPETexMipmap]]
    public let conditionalVariants: [WPETexConditionalVariant]
    /// Each wire record once, in original image/mip/group/record order, including unselected IDs.
    public let conditionalRecords: [WPETexConditionalVariantMipmap]

    public init(
        version: Int,
        sourceImageFormatCode: Int?,
        isVideoPayload: Bool,
        frames: [[WPETexMipmap]],
        conditionalVariants: [WPETexConditionalVariant] = [],
        conditionalRecords: [WPETexConditionalVariantMipmap] = []
    ) {
        self.version = version
        self.sourceImageFormatCode = sourceImageFormatCode
        self.isVideoPayload = isVideoPayload
        self.frames = frames
        self.conditionalVariants = conditionalVariants
        self.conditionalRecords = conditionalRecords
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
    public let hasConditionalVariants: Bool
    /// Non-nil only after selection/materialization against the caller's typed property snapshot.
    public let conditionalSelection: WPETexConditionalSelection?

    private let explicitAnimationFlag: Bool

    public init(
        info: WPETexInfo,
        mipmaps: [WPETexTextureMipmap],
        hasAnimationFrames: Bool,
        animationTrack: WPETexAnimationTrack? = nil,
        videoPayload: WPETexVideoPayload? = nil,
        hasConditionalVariants: Bool = false,
        conditionalSelection: WPETexConditionalSelection? = nil
    ) {
        self.info = info
        self.mipmaps = mipmaps
        self.conditionalSelection = conditionalSelection
        explicitAnimationFlag = hasAnimationFrames
        self.animationTrack = animationTrack
        self.videoPayload = videoPayload
        self.hasConditionalVariants = hasConditionalVariants
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
    public let depth: Int
    public let bytes: Data

    public init(index: Int, width: Int, height: Int, depth: Int = 1, bytes: Data) {
        self.index = index
        self.width = width
        self.height = height
        self.depth = depth
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

public extension DecodedRGBAImage {
    func makeCGImage() throws -> CGImage {
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
