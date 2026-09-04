#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

/// WPE "Limit rows" / "Max rows" / "Use ellipsis". All 527 corpus text objects
/// author the three keys; 34 turn the limit on, 32 of those at `maxrows: 1`.
/// Until these were read, the CoreText path wrapped until the whole string fit.
struct WPESceneTextRowLimitTests {

    private func textObject(_ extra: String) throws -> WPESceneTextObject {
        let json = """
        {"camera": {"center": "0 0 0", "eye": "0 0 100", "up": "0 1 0"},
         "general": {}, "objects": [{
            "id": 1, "name": "t", "text": "hello",
            "origin": "0 0 0", "angles": "0 0 0", "scale": "1 1 1",
            \(extra)
        }]}
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        return try #require(document.textObjects.first)
    }

    @Test("maxrows is gated by limitrows, exactly like maxwidth is by limitwidth")
    func rowLimitIsGatedByItsToggle() throws {
        // Toggle off is the corpus default (493 of 527) and every one of those
        // objects still writes `maxrows: 1` — honouring it unconditionally would
        // clamp almost the entire corpus to a single row.
        let off = try textObject(#""limitrows": false, "maxrows": 1, "limituseellipsis": true"#)
        #expect(off.maxRows == nil, "an off toggle must not clamp")
        #expect(off.limitUseEllipsis)

        let on = try textObject(#""limitrows": true, "maxrows": 3, "limituseellipsis": true"#)
        #expect(on.maxRows == 3)

        // Absent keys keep the previous unbounded behaviour.
        let bare = try textObject(#""visible": true"#)
        #expect(bare.maxRows == nil)
        #expect(!bare.limitUseEllipsis)

        // A nonsense row count still leaves at least one row to draw.
        let zero = try textObject(#""limitrows": true, "maxrows": 0"#)
        #expect(zero.maxRows == 1)
    }

    @Test("Row-limit fields survive the per-frame withLiveText copy")
    func rowLimitSurvivesLiveTextCopy() throws {
        // `withLiveText` is a hand-written 39-field copy run once per frame. A
        // field missing from it parses correctly and then vanishes from every
        // live frame — the exact shape of this repo's geometry-copy bug, which
        // has already been hit twice.
        let object = try textObject(
            #""limitrows": true, "maxrows": 2, "limituseellipsis": true, "limitwidth": true, "maxwidth": 500"#
        )
        let live = object.withLiveText("world", alpha: 1)
        #expect(live.text == "world")
        #expect(live.maxRows == 2, "maxRows dropped by withLiveText")
        #expect(live.limitUseEllipsis, "limitUseEllipsis dropped by withLiveText")
        #expect(live.maxWidth == object.maxWidth, "control: a pre-existing field still survives")
    }
}

/// `instanceoverride.controlpointN` — one particle file reused across objects,
/// each positioning its control points from the scene. Dropping these left
/// `controlpointattract` pulling toward the emitter itself.
struct WPEParticleInstanceControlPointTests {

    private func particleObject(_ override: String) throws -> WPESceneParticleObject {
        let json = """
        {"camera": {"center": "0 0 0", "eye": "0 0 100", "up": "0 1 0"},
         "general": {}, "objects": [{
            "id": 1, "name": "p", "particle": "particles/p.json",
            "origin": "0 0 0", "angles": "0 0 0", "scale": "1 1 1",
            "instanceoverride": {\(override)}
        }]}
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        return try #require(document.particleObjects.first)
    }

    @Test("instanceoverride controlpointN parses; angles stay unread on purpose")
    func controlPointOverridesParse() throws {
        let object = try particleObject(
            #""size": 0.5, "controlpoint1": "-204.06 -81.03 0", "controlpoint7": "1 2 3", "controlpointangle1": "0 0 90""#
        )
        let override = try #require(object.instanceOverride)
        #expect(override.controlPointOffsets[1] == SIMD3<Double>(-204.06, -81.03, 0))
        #expect(override.controlPointOffsets[7] == SIMD3<Double>(1, 2, 3))
        #expect(override.controlPointOffsets[8] == nil)
        // `controlpointangle1` is an orientation, not an offset — nothing consumes
        // angles yet, so it must NOT be folded in as if it were a position.
        #expect(override.controlPointOffsets.count == 2)
        #expect(override.size == 0.5, "control: sibling keys still parse")
    }

    @Test("An override control point replaces the definition's own offset")
    func controlPointOverrideReplacesAuthoredOffset() throws {
        let definition = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4, rate: 1, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1, sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3<Double>(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3<Double>(0, 0, 0), velocityMax: SIMD3<Double>(0, 0, 0),
            colorMin: SIMD3<Double>(255, 255, 255), colorMax: SIMD3<Double>(255, 255, 255),
            fadeInSeconds: 0,
            controlPoints: [
                // The shape 31.json ships: an authored point with no offset, which
                // parses to (0,0,0) — i.e. the emitter itself.
                WPEParticleControlPoint(id: 1, offset: SIMD3<Double>(0, 0, 0), pointerLocked: false),
                WPEParticleControlPoint(id: 2, offset: SIMD3<Double>(9, 9, 9), pointerLocked: true),
            ]
        )
        let applied = definition.applying(
            instanceOverride: WPESceneParticleInstanceOverride(
                controlPointOffsets: [1: SIMD3<Double>(-204.06, -81.03, 0)]
            )
        )
        let byID = Dictionary(uniqueKeysWithValues: applied.controlPoints.map { ($0.id, $0) })
        #expect(byID[1]?.offset == SIMD3<Double>(-204.06, -81.03, 0), "override wins")
        #expect(byID[2]?.offset == SIMD3<Double>(9, 9, 9), "an omitted point keeps its authored offset")
        #expect(byID[2]?.pointerLocked == true, "control: other fields survive the rebuild")

        // No override at all must leave the authored points untouched.
        let untouched = definition.applying(instanceOverride: WPESceneParticleInstanceOverride(size: 2))
        #expect(untouched.controlPoints == definition.controlPoints)
    }
}
#endif
