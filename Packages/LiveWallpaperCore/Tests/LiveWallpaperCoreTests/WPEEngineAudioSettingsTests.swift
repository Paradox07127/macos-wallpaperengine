import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("WPE engine audio settings")
struct WPEEngineAudioSettingsTests {

    @Test("A wallpaper with no preset volume reads as absent")
    func absentVolumeIsNil() {
        #expect(WPEEngineAudioSettings.parse([:]) == nil)
        // A preset that carries other engine keys but no volume must not be
        // read as "silent" — absent is not zero.
        #expect(WPEEngineAudioSettings.parse(["wec_e": .bool(true)]) == nil)
    }

    @Test("The observed presets' levels map onto a 0...1 scale")
    func observedLevelsMap() throws {
        // Preset 3471679253 published 50, preset 3544156790 published 80.
        #expect(try #require(WPEEngineAudioSettings.parse(["volume": .number(50)])).volumeScale == 0.5)
        #expect(try #require(WPEEngineAudioSettings.parse(["volume": .number(80)])).volumeScale == 0.8)
    }

    @Test("Full volume is neutral, so it multiplies nothing away")
    func fullVolumeIsNeutral() throws {
        let parsed = try #require(WPEEngineAudioSettings.parse(["volume": .number(100)]))
        #expect(parsed.isNeutral)
        // Control: the levels the real presets use must NOT read as neutral, or
        // the author's choice would be silently discarded.
        #expect(try #require(WPEEngineAudioSettings.parse(["volume": .number(80)])).isNeutral == false)
    }

    @Test("A string NaN yields no setting rather than a NaN gain")
    func stringNaNIsRefused() {
        // A NaN gain would also slip the sound runtime's `abs(delta) > 0.001`
        // guard — the comparison is false for NaN — so the old level would be
        // kept silently instead of failing where anyone could see it.
        #expect(WPEEngineAudioSettings.parse(["volume": .string("NaN")]) == nil)
        #expect(WPEEngineAudioSettings.parse(["volume": .number(.nan)]) == nil)
    }

    @Test("Out-of-range values are clamped before they scale a gain")
    func clampsHostileValues() throws {
        #expect(try #require(WPEEngineAudioSettings.parse(["volume": .number(-40)])).volumeScale == 0)
        #expect(try #require(WPEEngineAudioSettings.parse(["volume": .number(1000)])).volumeScale == 1)
        // Non-finite is not an out-of-range number, it is not a number — it
        // reads as "no setting" rather than as full volume.
        #expect(WPEEngineAudioSettings.parse(["volume": .number(.infinity)]) == nil)
    }
}

@Suite("WPE engine audio composition")
struct WPEEngineAudioCompositionTests {

    @Test("The preset scales the user's level rather than replacing it")
    func presetScalesMaster() {
        // 3544156790 published 80. At half master the wallpaper must land at
        // 0.4, not at 0.8 — a preset states a relative level.
        let preset = WPEEngineAudioSettings(volumeScale: 0.8)
        #expect(WPEEngineAudioSettings.effectiveVolume(master: 0.5, preset: preset) == 0.4)
        #expect(WPEEngineAudioSettings.effectiveVolume(master: 1.0, preset: preset) == 0.8)
    }

    @Test("No preset leaves the user's level untouched")
    func absentPresetIsTransparent() {
        // Control: without this the multiplication could be dropped entirely and
        // the suite above would still pass.
        #expect(WPEEngineAudioSettings.effectiveVolume(master: 0.35, preset: nil) == 0.35)
        #expect(WPEEngineAudioSettings.effectiveVolume(master: 0.35, preset: .neutral) == 0.35)
    }

    @Test("Muting the app wins over any preset level")
    func masterZeroSilences() {
        #expect(WPEEngineAudioSettings.effectiveVolume(
            master: 0, preset: WPEEngineAudioSettings(volumeScale: 1)
        ) == 0)
    }
}

/// Engine keys are bare names — `volume`, `rate`, `alignment` — and a wallpaper
/// is free to declare a property of the same name. The repo's own schema fixture
/// declares `volume` as a slider. So the source these are read from matters:
/// `presetSnapshot` is what a preset published, while the layered map also
/// carries whatever the user moved in the settings card.
@Suite("Engine keys are read from the preset, not the user's edits")
struct WPEEngineKeySourceTests {

    private func descriptor(
        presetValues: [String: WallpaperEngineProjectPropertyValue],
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "1", cacheRelativePath: "wpe-cache/1", entryFile: "scene.pkg",
            capabilityTier: .imageOnly,
            propertyOverrides: overrides,
            presetID: presetValues.isEmpty ? nil : "p",
            presetSnapshot: presetValues
        )
    }

    @Test("A wallpaper's own `volume` slider is not mistaken for the engine's")
    func authorVolumeSliderIsNotEngineVolume() {
        // No preset at all — the layered map is exactly the user's edits, so
        // reading it would turn an author's slider into a master-gain scale.
        let d = descriptor(presetValues: [:], overrides: ["volume": .number(20)])
        #expect(WPEEngineAudioSettings.parse(d.presetSnapshot) == nil)
        // What the old source would have produced, for contrast: a 0.2 scale
        // applied to every sound in the scene.
        #expect(WPEEngineAudioSettings.parse(d.layeredPropertyValues())?.volumeScale == 0.2)
    }

    @Test("A preset's engine volume is still read")
    func presetVolumeStillApplies() throws {
        // Control: the fix must not make engine settings unreachable.
        let d = descriptor(presetValues: ["volume": .number(80)], overrides: [:])
        #expect(try #require(WPEEngineAudioSettings.parse(d.presetSnapshot)).volumeScale == 0.8)
    }

    @Test("Editing an author property does not shadow the preset's engine value")
    func userEditDoesNotOverrideEngineValue() throws {
        // Both present: the preset says 80, the user moved a same-named author
        // slider to 20. The engine setting is the preset's.
        let d = descriptor(
            presetValues: ["volume": .number(80)], overrides: ["volume": .number(20)]
        )
        #expect(try #require(WPEEngineAudioSettings.parse(d.presetSnapshot)).volumeScale == 0.8)
    }
}
