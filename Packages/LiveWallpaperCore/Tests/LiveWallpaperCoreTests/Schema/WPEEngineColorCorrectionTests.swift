import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("WPE engine colour correction")
struct WPEEngineColorCorrectionTests {

    private let disabledPreset: [String: WallpaperEngineProjectPropertyValue] = [
        "wec_e": .bool(false), "wec_brs": .number(50), "wec_con": .number(50),
        "wec_hue": .number(50), "wec_sa": .number(50)
    ]

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
        // 50 is neutral, so brightness stays put. Do not inline the arithmetic into
        // `#expect`: untyped literal division there blows the type-checker budget.
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
        // `min`/`max` pass NaN straight through, and a NaN uniform makes every pixel in
        // the frame undefined.
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
        // Finite out-of-range clamps; non-finite is not a value at all and falls back to
        // neutral rather than to the top of the range.
        let parsed = try #require(WPEEngineColorCorrection.parse([
            "wec_e": .bool(true), "wec_brs": .number(-500), "wec_con": .number(9999),
            "wec_hue": .number(.infinity), "wec_sa": .number(-1)
        ]))
        #expect(parsed.brightness == -1)
        #expect(parsed.contrast == 2)
        #expect(parsed.saturation == 0)
        #expect(parsed.hueDegrees == 0)
    }
}
