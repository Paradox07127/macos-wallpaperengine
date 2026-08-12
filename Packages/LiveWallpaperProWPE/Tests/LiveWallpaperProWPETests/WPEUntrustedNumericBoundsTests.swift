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
