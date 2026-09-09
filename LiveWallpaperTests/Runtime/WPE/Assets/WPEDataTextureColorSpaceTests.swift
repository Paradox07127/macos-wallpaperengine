import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// Windows RenderDoc captures of 2370927443 / 3554161528 / 2955378002 / 3448877775
/// bind every SRV as `*_UNORM`, while Mac built `effects/waterripplenormal`,
/// `effects/waterflowphase`, `util/noise` and the RGBA `masks/*` as
/// `rgba8Unorm_srgb` (trace format 71). Those are data, not colour: 0.5 decodes
/// to 0.21 and the normal field / flow phase / noise modulation is warped.
@Suite("WPE data texture colour space")
struct WPEDataTextureColorSpaceTests {
    /// Every reference the four-scene traces showed as format 71 while the same
    /// directory's R8/RG8 siblings were already linear (format 10 / 30).
    static let dataReferences = [
        "effects/waterripplenormal",
        "effects/waterflowphase",
        "effects/refractnormal",
        "util/noise",
        "util/clouds_256",
        "util/white",
        "materials/util/noise.tex",
        "masks/godrays_downsample2_mask_843377ec5689457129ad9ee2dd9c051f084db05d",
        "masks/opacity_mask_3bdf7b6b8dc3e0fd019a607371289b0a9cfec094",
        "masks/waterripple_mask_ee7058443ac3beeaf111023c053d54e1874d24c7",
        "workshop/3248335727/masks/opacity_mask_b46090becade15742727de64041260c1ab4bade4",
        "materials/masks/tint_mask_26f1dac1.tex",
    ]

    /// Authored colour content from the same four traces. These must keep sRGB
    /// decoding — the global gamma-vs-linear contract is a separate, undecided
    /// question and this change must not pre-empt it.
    static let colorReferences = [
        "Neon cafe",
        "night cielo",
        "Night2",
        "materials/particle/halo_1.tex",
        "particle/3",
        "models/futaba",
        "workshop/3241236635/30Bottom",
        "normalcafe",
        "masking tape",
    ]

    @Test("Engine data-texture namespaces load linear", arguments: dataReferences)
    func dataReferencesAreLinear(reference: String) {
        #expect(WPEMetalTextureColorSpaceClassifier.colorSpace(forReference: reference) == .linear)
    }

    @Test("Authored colour content stays sRGB", arguments: colorReferences)
    func colorReferencesStaySRGB(reference: String) {
        #expect(WPEMetalTextureColorSpaceClassifier.colorSpace(forReference: reference) == .sRGB)
    }

    @Test("A linear classification reaches the Metal pixel format")
    func classificationReachesPixelFormat() throws {
        let caps = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)
        let dataSpace = WPEMetalTextureColorSpaceClassifier.colorSpace(forReference: "util/noise")
        let colorSpace = WPEMetalTextureColorSpaceClassifier.colorSpace(forReference: "Neon cafe")
        // 70 = rgba8Unorm, 71 = rgba8Unorm_srgb in the canonical trace.
        #expect(try WPEMetalTextureFormatMapper.mapping(
            for: .rgba8888, capabilities: caps, colorSpace: dataSpace
        ).pixelFormat == .rgba8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(
            for: .rgba8888, capabilities: caps, colorSpace: colorSpace
        ).pixelFormat == .rgba8Unorm_srgb)
        #expect(try WPEMetalTextureFormatMapper.mapping(
            for: .dxt5, capabilities: caps, colorSpace: dataSpace
        ).pixelFormat == .bc3_rgba)
    }
}
