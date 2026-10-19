import Foundation
@testable import LiveWallpaperProWPE
import Testing

/// `1e300` is the probe value throughout because it is *finite* — an `isFinite` guard
/// passes it and still traps.
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

    @Test("int saturates an out-of-range JSON number that as? Int rejects")
    func intSaturatesWhereAsIntFails() {
        let json = jsonValues(#"{"big":1e300,"small":-1e300,"ok":5}"#)
        #expect(json["big"] as? Int == nil)
        #expect(WPEValueParser.int(json["big"]) == Int.max)
        #expect(WPEValueParser.int(json["small"]) == Int.min)
        #expect(WPEValueParser.int(json["ok"]) == 5)
    }
}

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

    @Test("Numeric vectors reject nonfinite components without clamping finite HDR values")
    func vectorsRejectNonfiniteComponents() {
        for value in ["nan 0 0", "0 inf 0", "0 0 -infinity"] {
            #expect(WPEValueParser.numberVector(value) == nil)
        }
        #expect(WPEValueParser.numberVector([Double.nan, 0, 0]) == nil)
        #expect(WPEValueParser.numberVector([0, Double.infinity, 0]) == nil)
        #expect(WPEValueParser.numberVector("-2 4 1e100") == [-2, 4, 1e100])
        #expect(WPEValueParser.numberVector([-2, 4, 1e100]) == [-2, 4, 1e100])
    }

    @Test("Scalar values and animation frames reject nonfinite data")
    func scalarAndAnimationFramesRejectNonfiniteData() throws {
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, "nan", "inf", "-infinity"] {
            #expect(WPEValueParser.double(value) == nil)
        }
        #expect(WPEValueParser.double(-2) == -2)
        #expect(WPEValueParser.double("1e100") == 1e100)
        #expect(WPEValueParser.double(true, boolAsNumber: true) == 1)
        let raw = try JSONSerialization.jsonObject(with: Data(#"{"value":0,"animation":{"c0":[{"frame":"nan","value":1},{"frame":0,"value":"inf"},{"frame":1,"value":2}],"options":{"fps":30,"length":1}}}"#.utf8))
        let animation = try #require(WPEValueParser.animatedValue(raw))
        let track = try #require(animation.animation.tracks.first)
        #expect(track.count == 1)
        #expect(track.first?.frame == 1)
        #expect(track.first?.value == 2)
    }
}
