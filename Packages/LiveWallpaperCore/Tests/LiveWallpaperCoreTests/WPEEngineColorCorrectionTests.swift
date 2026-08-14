import Foundation
import Testing
@testable import LiveWallpaperCore

/// Fixtures are the two real presets this was derived from, so the mapping is
/// pinned to observed data rather than to itself.
@Suite("WPE engine colour correction")
struct WPEEngineColorCorrectionTests {

    /// Preset 3471679253 — correction switched off, every slider neutral.
    private let disabledPreset: [String: WallpaperEngineProjectPropertyValue] = [
        "wec_e": .bool(false), "wec_brs": .number(50), "wec_con": .number(50),
        "wec_hue": .number(50), "wec_sa": .number(50)
    ]

    /// Preset 3544156790 — on, and genuinely adjusted.
    private let adjustedPreset: [String: WallpaperEngineProjectPropertyValue] = [
        "wec_e": .bool(true), "wec_brs": .number(50), "wec_con": .number(80),
        "wec_hue": .number(46), "wec_sa": .number(80)
    ]

    @Test("A wallpaper with no correction block at all reads as absent")
    func absentBlockIsNil() {
        // Distinct from "present and off": nothing to skip, nothing to apply.
        #expect(WPEEngineColorCorrection.parse([:]) == nil)
        #expect(WPEEngineColorCorrection.parse(["windspeed": .number(2)]) == nil)
    }

    @Test("Switched off collapses to neutral")
    func disabledIsNeutral() throws {
        let parsed = try #require(WPEEngineColorCorrection.parse(disabledPreset))
        #expect(parsed == .neutral)
        #expect(parsed.isIdentity)
    }

    @Test("An adjusted preset maps onto the video path's own semantics")
    func adjustedMapsToSharedSemantics() throws {
        let parsed = try #require(WPEEngineColorCorrection.parse(adjustedPreset))
        // 50 is neutral, so brightness stays put while the other three move.
        // Precomputed rather than written as literal arithmetic inside `#expect`:
        // the macro expands into a large expression tree, and untyped literal
        // division inside it pushed the type checker past its time budget on
        // CI's slower runner while staying under it locally.
        #expect(parsed.brightness == 0)
        #expect(parsed.contrast == 1.6)
        #expect(parsed.saturation == 1.6)
        #expect(parsed.hueDegrees == -14.4)
        // Control: this preset must not be mistaken for a no-op, or the renderer
        // would skip the pass and the author's look would still be lost.
        #expect(!parsed.isIdentity)
    }

    @Test("All-neutral sliders are an identity even when switched on")
    func neutralSlidersAreIdentity() throws {
        let parsed = try #require(WPEEngineColorCorrection.parse([
            "wec_e": .bool(true), "wec_brs": .number(50), "wec_con": .number(50),
            "wec_hue": .number(50), "wec_sa": .number(50)
        ]))
        #expect(parsed.isIdentity)
    }

    @Test("Sliders without the flag are applied, not ignored")
    func missingFlagDefaultsToOn() throws {
        // The flag is how a preset says "off"; requiring it would silently drop
        // a correction whose author only moved sliders.
        let parsed = try #require(WPEEngineColorCorrection.parse(["wec_sa": .number(100)]))
        #expect(parsed.saturation == 2)
    }

    @Test("A string NaN is refused, not clamped")
    func stringNaNFallsBackToNeutral() throws {
        // `"NaN"` parses to a non-finite Double, and `min`/`max` pass NaN
        // straight through — the earlier clamp test used `.infinity`, which
        // clamps fine, so it never covered this. A NaN uniform makes every
        // pixel in the frame undefined.
        let parsed = try #require(WPEEngineColorCorrection.parse([
            "wec_e": .bool(true), "wec_brs": .string("NaN"), "wec_con": .string("nan"),
            "wec_hue": .number(.nan), "wec_sa": .number(50)
        ]))
        #expect(parsed.brightness.isFinite)
        #expect(parsed.contrast.isFinite)
        #expect(parsed.hueDegrees.isFinite)
        // Non-finite falls back to the neutral slider position.
        #expect(parsed.brightness == 0)
        #expect(parsed.contrast == 1)
        #expect(parsed.hueDegrees == 0)
    }

    @Test("Out-of-range but finite values are clamped into range")
    func clampsHostileValues() throws {
        // Finite and non-finite are handled differently on purpose: a number
        // outside 0...100 is a value the author wrote badly, so it clamps;
        // a non-finite one is not a value at all, so it falls back to neutral
        // rather than being read as "maximum", which the author never asked for.
        let parsed = try #require(WPEEngineColorCorrection.parse([
            "wec_e": .bool(true), "wec_brs": .number(-500), "wec_con": .number(9999),
            "wec_hue": .number(.infinity), "wec_sa": .number(-1)
        ]))
        #expect(parsed.brightness == -1)
        #expect(parsed.contrast == 2)
        #expect(parsed.saturation == 0)
        // Non-finite → neutral, not the top of the range.
        #expect(parsed.hueDegrees == 0)
    }
}
