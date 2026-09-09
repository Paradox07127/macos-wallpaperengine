#if !LITE_BUILD
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Color textures request sRGB-encoded pixel formats; data textures (masks,
/// normal maps, R8/RG8 channels) must stay linear.
enum WPEMetalColorSpace: Equatable, Hashable, Sendable {
    case sRGB
    case linear
}

struct WPEMetalTextureCapabilities: Equatable, Sendable {
    let supportsBCTextureCompression: Bool

    init(device: MTLDevice) {
        supportsBCTextureCompression = device.supportsBCTextureCompression
    }

    init(supportsBCTextureCompression: Bool) {
        self.supportsBCTextureCompression = supportsBCTextureCompression
    }
}

struct WPEMetalTextureFormatMapping: Equatable, Sendable {
    let pixelFormat: MTLPixelFormat
    let bytesPerPixel: Int?
    let bytesPerBlock: Int?
}

enum WPEMetalTextureLoaderError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(WPETexFormat)
    case unsupportedCompressedFormat(WPETexFormat)
    case malformedPayload(String)
    case textureAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return String(
                localized: "error.texture.format.unsupported_format",
                defaultValue: "WPE Metal texture format is unsupported: \(format.debugLabel)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine texture format cannot be mapped to Metal."
            )
        case .unsupportedCompressedFormat(let format):
            return String(
                localized: "error.texture.format.unsupported_compressed_format",
                defaultValue: "This Metal device cannot sample \(format.debugLabel) textures.",
                bundle: .appLanguage, comment: "Error shown when the current Metal device cannot sample a compressed texture format."
            )
        case .malformedPayload(let reason):
            return String(
                localized: "error.texture.format.malformed_payload",
                defaultValue: "WPE Metal texture payload is malformed: \(reason)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine texture payload is malformed."
            )
        case .textureAllocationFailed:
            return String(
                localized: "error.texture.format.texture_allocation_failed",
                defaultValue: "Metal texture allocation failed.",
                bundle: .appLanguage, comment: "Error shown when Metal texture allocation fails."
            )
        }
    }
}

/// Which of Wallpaper Engine's own asset namespaces hold DATA rather than colour.
/// Windows binds every SRV as `*_UNORM`; a Mac sRGB view decodes an authored 0.5
/// to 0.21, which warps normal fields, flow phase and noise modulation
/// (four-scene oracle, 2026-09-07).
///
/// The three prefixes are enumerable, not a substring guess — everything the
/// engine ships under them is data:
///   `effects/` — refractnormal, waterflowphase, waterripplenormal (all three)
///   `util/`    — black, clouds_256, flatnormal, fur, noflow, noise, perlin_256,
///                uniform_256, white
///   `masks/`   — editor-generated `<effect>_mask_<hash>`. Their R8/RG8 members
///                are ALREADY linear (Metal has no `r8Unorm_srgb`), so the RGBA
///                ones were the only members decoded unlike their own peers.
/// Substring matching is deliberately not used: the same corpus has authored
/// colour art named `masking tape` and `normalcafe`.
///
/// Colour assets stay sRGB on purpose. The global gamma-vs-linear contract
/// (`.notes/review/wpe-oracle-4scene-2026-09-07/SUMMARY.md` §B1) is undecided
/// and this must not pre-empt it.
enum WPEMetalTextureColorSpaceClassifier {
    private static let dataPrefixes = ["effects/", "masks/", "util/"]

    static func colorSpace(forReference reference: String) -> WPEMetalColorSpace {
        dataPrefixes.contains(where: normalized(reference).hasPrefix) ? .linear : .sRGB
    }

    /// Peels the container prefixes the resolver and the workshop packer add
    /// (`materials/`, `workshop/<id>/`, in either order and nestable) so the
    /// authored namespace is what gets matched.
    private static func normalized(_ reference: String) -> String {
        var path = Substring(reference.lowercased())
        while true {
            if path.hasPrefix("materials/") {
                path = path.dropFirst("materials/".count)
                continue
            }
            if path.hasPrefix("workshop/") {
                let rest = path.dropFirst("workshop/".count)
                if let slash = rest.firstIndex(of: "/"), rest[rest.startIndex ..< slash].allSatisfy(\.isNumber) {
                    path = rest[rest.index(after: slash)...]
                    continue
                }
            }
            return String(path)
        }
    }
}

enum WPEMetalTextureFormatMapper {
    static func mapping(
        for format: WPETexFormat,
        capabilities: WPEMetalTextureCapabilities,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) throws -> WPEMetalTextureFormatMapping {
        switch format {
        case .rgba8888:
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
                bytesPerPixel: 4,
                bytesPerBlock: nil
            )
        case .r8:
            return WPEMetalTextureFormatMapping(pixelFormat: .r8Unorm, bytesPerPixel: 1, bytesPerBlock: nil)
        case .rg88:
            return WPEMetalTextureFormatMapping(pixelFormat: .rg8Unorm, bytesPerPixel: 2, bytesPerBlock: nil)
        case .dxt1:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc1_rgba_srgb : .bc1_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 8
            )
        case .dxt3:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc2_rgba_srgb : .bc2_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .dxt5:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc3_rgba_srgb : .bc3_rgba,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .bc7:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(
                pixelFormat: colorSpace == .sRGB ? .bc7_rgbaUnorm_srgb : .bc7_rgbaUnorm,
                bytesPerPixel: nil,
                bytesPerBlock: 16
            )
        case .rgba1010102:
            throw WPEMetalTextureLoaderError.unsupportedFormat(format)
        }
    }
}
#endif
