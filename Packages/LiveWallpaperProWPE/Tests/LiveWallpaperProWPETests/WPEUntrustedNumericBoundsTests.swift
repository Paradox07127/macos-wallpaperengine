import Foundation
import Testing
@testable import LiveWallpaperProWPE

/// Workshop scene assets are untrusted input, and `Int(_:)` traps on NaN and on
/// any magnitude past `Int` rather than returning a wrong answer. A single
/// out-of-range literal in `scene.pkg` therefore used to kill the wallpaper
/// agent during load instead of failing the asset closed.
///
/// `1e300` is the probe value throughout because it is *finite* — an
/// `isFinite` guard passes it and still traps.
@Suite("Untrusted numeric bounds")
struct WPEUntrustedNumericBoundsTests {

    /// Values as `JSONSerialization` actually produces them (`__NSCFNumber`),
    /// which is the path real scene data takes.
    private func jsonValues(_ text: String) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(text.utf8)
        ) as? [String: Any] else {
            fatalError("Failed to parse fixture JSON")
        }
        return object
    }

    // MARK: - saturatingInt

    @Test("saturatingInt clamps out-of-range magnitudes instead of trapping")
    func saturatingIntClamps() {
        #expect(WPEValueParser.saturatingInt(1e300) == Int.max)
        #expect(WPEValueParser.saturatingInt(-1e300) == Int.min)
        #expect(WPEValueParser.saturatingInt(.infinity) == Int.max)
        #expect(WPEValueParser.saturatingInt(-.infinity) == Int.min)
        #expect(WPEValueParser.saturatingInt(.nan) == 0)
    }

    @Test("saturatingInt truncates in-range values exactly like Int(_:)")
    func saturatingIntMatchesIntInRange() {
        #expect(WPEValueParser.saturatingInt(42.7) == 42)
        #expect(WPEValueParser.saturatingInt(-42.7) == -42)
        #expect(WPEValueParser.saturatingInt(0) == 0)
    }

    // MARK: - WPEValueParser.int

    /// `maxcount` and `flags` rely on this: `1e300 as? Int` is nil, so the old
    /// code fell through to a trapping `as? Double` branch.
    @Test("int saturates an out-of-range JSON number that as? Int rejects")
    func intSaturatesWhereAsIntFails() {
        let json = jsonValues(#"{"big":1e300,"small":-1e300,"ok":5}"#)
        #expect(json["big"] as? Int == nil)
        #expect(WPEValueParser.int(json["big"]) == Int.max)
        #expect(WPEValueParser.int(json["small"]) == Int.min)
        #expect(WPEValueParser.int(json["ok"]) == 5)
    }

    // MARK: - Sprite sheet sidecar

    @Test("A sub-pixel sprite frame width clamps to the atlas instead of trapping")
    func spriteSheetSubPixelFrameWidthClamps() {
        let json = jsonValues(
            #"{"spritesheetsequences":[{"width":1e-300,"height":1,"frames":1,"duration":1}]}"#
        )
        let sheet = WPEParticleSpriteSheetParser.parse(
            dictionary: json,
            atlasPixelSize: (width: 2048, height: 2048)
        )
        #expect(sheet?.cols == 2048)
        #expect(sheet?.rows == 2048)
    }

    @Test("A well-formed sprite sheet still divides the atlas normally")
    func spriteSheetWellFormedIsUnchanged() {
        let json = jsonValues(
            #"{"spritesheetsequences":[{"width":512,"height":256,"frames":8,"duration":1}]}"#
        )
        let sheet = WPEParticleSpriteSheetParser.parse(
            dictionary: json,
            atlasPixelSize: (width: 2048, height: 1024)
        )
        #expect(sheet?.cols == 4)
        #expect(sheet?.rows == 4)
        #expect(sheet?.frameCount == 8)
    }

    @Test("An out-of-range frame count saturates rather than trapping")
    func spriteSheetOutOfRangeFrameCount() {
        let json = jsonValues(
            #"{"spritesheetsequences":[{"width":512,"height":512,"frames":1e300,"duration":1}]}"#
        )
        let sheet = WPEParticleSpriteSheetParser.parse(
            dictionary: json,
            atlasPixelSize: (width: 2048, height: 2048)
        )
        #expect(sheet?.frameCount == Int.max)
    }
}

extension WPEUntrustedNumericBoundsTests {
    /// Every remaining bare `Int(Double)` in the particle parser, probed with the
    /// same finite-but-unrepresentable `1e300` the suite header explains.
    @Test("Out-of-range particle ids, counts and audio bands saturate instead of trapping")
    func particleParserSaturatesOutOfRangeNumbers() {
        let json = jsonValues(#"""
        {
            "maxcount": 1e300,
            "instantaneous": 1e300,
            "emitter": [{
                "name": "boom",
                "rate": 5,
                "audioprocessing": 1,
                "audioprocessingfrequencystart": 1e300,
                "audioprocessingfrequencyend": -1e300
            }],
            "controlpoint": [{"id": 1e300, "offset": "0 0 0", "flags": 1}],
            "operator": [{"name": "controlpointattract", "controlpoint": 1e300, "scale": 1, "threshold": 2}],
            "children": [{"id": 1e300, "name": "spark"}]
        }
        """#)
        var diagnostics: [WPESceneDiagnostic] = []
        let definition = WPEParticleDefinitionParser.parse(dictionary: json, diagnostics: &diagnostics)

        // Load survived; the saturated values are pinned, not asserted loosely,
        // so a silent behavior change here shows up as a diff.
        #expect(definition.controlPoints.first?.id == Int.max)
        #expect(definition.childReferences.first?.id == Int.max)

        // The audio band clamp: 1e300 → last band, -1e300 → first band, swapped into order.
        if let audio = definition.emitterAudioState {
            #expect(audio.emissionScale(spectrum16: [Float](repeating: 0.5, count: 16)) >= 0)
        }

        // Instance-override count scaling on an already-saturated maxcount must not trap either.
        #expect(definition.maxCount == Int.max, "top-level maxcount saturates at parse")
        let scaled = definition.applying(instanceOverride: WPESceneParticleInstanceOverride(count: 2))
        #expect(scaled.maxCount == Int.max, "Int.max * 2 saturates instead of trapping")
    }
}

/// `{"x":0,"y":0,"z":0}` is an authored zero vector — the camera typed IR was
/// marking it `.unparsed` while the string spelling `"0 0 0"` parsed fine,
/// because the dictionary path conflated "no keys present" with "all zeros".
@Suite("Authored zero vectors")
struct WPEVectorZeroDictionaryTests {
    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test("A dictionary spelling of the zero vector parses like the string spelling")
    func zeroDictionaryParses() {
        #expect(WPEValueParser.vector3(json(#"{"x":0,"y":0,"z":0}"#)) == SIMD3(0, 0, 0))
        #expect(WPEValueParser.vector3("0 0 0") == SIMD3(0, 0, 0))
        #expect(WPEValueParser.vector3(json(#"{"x":0,"y":2,"z":0}"#)) == SIMD3(0, 2, 0))
    }

    @Test("A dictionary with none of the axis keys is still unparsed, not zero")
    func keylessDictionaryStaysNil() {
        #expect(WPEValueParser.vector3(json(#"{"foo":1}"#)) == nil)
        #expect(WPEValueParser.vector3(json(#"{}"#)) == nil)
    }
}
