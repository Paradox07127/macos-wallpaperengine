import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Fixed-font distance consumer behavior. Original Windows byte parity runs in ExternalCorpus.
final class ParityTextDistanceConsumerTests: XCTestCase {

    func testZeroAreaSpaceReservesItsCellAndInvalidPreparationPreservesExistingReferences() throws {
        let outline = try fixedFontRoot()
        let planner = WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(outline)]))
        var spaced = text(); spaced.text = "H "
        let prepared = try planner.plan(spaced, effectCount: 0, glyphMode: .distanceField)
        let mesh = try XCTUnwrap(prepared.layout.mesh)
        XCTAssertEqual(mesh.mono.vertices.count, 8)
        XCTAssertEqual(Set(mesh.mono.glyphKeys), [43, 3])
        let before = try XCTUnwrap(planner.atlases[prepared.atlasKey])
        let space = try XCTUnwrap(before.mono.entry(forKey: 3))
        XCTAssertEqual([space.x1 - space.x0, space.y1 - space.y0], [24, 24])
        var unsupported = text(); unsupported.msdf = false
        XCTAssertThrowsError(try planner.plan(unsupported, effectCount: 0, glyphMode: .distanceField)) {
            XCTAssertEqual($0 as? WPEParityTextPreparationError, .distanceFieldNotRequested)
        }
        unsupported = text(); unsupported.pointSize = .nan
        XCTAssertThrowsError(try planner.plan(unsupported, effectCount: 0, glyphMode: .distanceField)) {
            XCTAssertEqual($0 as? WPEParityTextPreparationError, .nonfiniteDrawParameters)
        }
        let after = try XCTUnwrap(planner.atlases[prepared.atlasKey])
        XCTAssertEqual(Set(planner.atlases.keys), [prepared.atlasKey])
        XCTAssertEqual(after.mono.contentGeneration, before.mono.contentGeneration)
        XCTAssertEqual(after.mono.pixels, before.mono.pixels)
        XCTAssertEqual(after.mono.entry(forKey: 43)?.references, 1)
    }

    func testSharedDistanceAtlasAcrossPointSizesAndModeSwitchReleasesReferences() throws {
        let oracle = try fixedFontRoot()
        let planner = WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(oracle)]))
        let first = try planner.plan(text(), effectCount: 0, glyphMode: .distanceField)
        let generation = try XCTUnwrap(planner.atlases[first.atlasKey]).mono.contentGeneration
        var second = text(); second.id = "U"; second.pointSize = 16
        let other = try planner.plan(second, effectCount: 0, glyphMode: .distanceField)
        XCTAssertEqual(first.atlasKey, other.atlasKey)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.contentGeneration, generation)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.entry(forKey: 43)?.references, 2)
        let ordinary = try planner.plan(text(), effectCount: 0)
        XCTAssertEqual(ordinary.atlasKey, "NotoSans-Regular.ttf_512")
        XCTAssertEqual(planner.atlases[ordinary.atlasKey]?.mono.format, .r8)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.entry(forKey: 43)?.references, 1)
        second.text = ""
        _ = try planner.plan(second, effectCount: 0, glyphMode: .distanceField)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.entry(forKey: 43)?.references, 0)
    }

    func testEffectiveParametersAndActualMaterialIdentity() throws {
        var object = text()
        object.outline = true; object.outlineThickness = 0
        object.blur = true; object.blurSize = 100
        object.dropShadow = true; object.dropShadowSize = 0
        object.dropShadowOffset = SIMD2(-100, 100)
        object.outlineColor = SIMD3(-1, 2, 3); object.dropShadowColor = SIMD3(4, -5, 6)
        object.dropShadowOpacity = 1.4
        let parameters = try XCTUnwrap(WPEParityTextDrawParameters(object: object, pointSize: 32))
        XCTAssertEqual(parameters.renderVar0.x, 24)
        XCTAssertEqual(parameters.renderVar0.y, 0)
        XCTAssertEqual(parameters.renderVar0.z, 6)
        XCTAssertEqual(parameters.renderVar0.w, 0.0024, accuracy: 0.0000001)
        XCTAssertEqual(parameters.renderVar1, SIMD4(-1, 2, 3, -24))
        XCTAssertEqual(parameters.renderVar2, SIMD4(4, -5, 6, 6))
        XCTAssertEqual(parameters.renderVar3X, 1.4)
        XCTAssertEqual(parameters.combos, ["OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1])
        var capped = object; capped.blur = false; capped.outlineThickness = 100
        XCTAssertEqual(try XCTUnwrap(WPEParityTextDrawParameters(object: capped, pointSize: 32)).renderVar0.y.bitPattern,
                       0x40A3_3334, "original rodata outline cap, not nearest Float literal5.1")
        XCTAssertEqual(WPEParityTextGlyphMode.distanceField.materialPath(atlas: .mono, depth: true),
                       "materials/fonts/basefont_msdf_depth.json")
        XCTAssertEqual(WPEParityTextGlyphMode.distanceField.materialPath(atlas: .color, depth: false),
                       "materials/fonts/basefontrgba_msdf.json")
        object.outline = false; object.blur = false; object.dropShadow = false
        let disabled = try XCTUnwrap(WPEParityTextDrawParameters(object: object, pointSize: 32))
        XCTAssertEqual(disabled.renderVar0, SIMD4(24, 0, 0, 0))
        XCTAssertEqual(disabled.renderVar1.w, 0); XCTAssertEqual(disabled.renderVar2.w, 0)
        XCTAssertEqual(disabled.renderVar3X, 1.4)
        XCTAssertTrue(disabled.combos.isEmpty)
        object.blurSize = .nan
        XCTAssertNil(WPEParityTextDrawParameters(object: object, pointSize: 32))
    }

    func testRequestedFieldAdmissionAcceptsMixedFontsAndSizesAndPreservesRV3OtherLanes() throws {
        var object = text()
        object.outline = true; object.dropShadow = true; object.dropShadowOpacity = 0.7
        let writes = try XCTUnwrap(WPEParityTextDrawParameters(object: object, pointSize: 8))
        var state = WPEParityRenderVarState()
        state.rv3 = SIMD4(0, 71, 72, 73)
        state.apply(writes)
        XCTAssertEqual(state.rv0, writes.renderVar0)
        XCTAssertEqual(state.rv1, writes.renderVar1)
        XCTAssertEqual(state.rv2, writes.renderVar2)
        XCTAssertEqual(state.rv3, SIMD4(0.7, 71, 72, 73))
        let requests = try WPEParityTextFieldAdmission.requests([.init(object)], texts: [:])
        XCTAssertEqual(requests.first?.glyphMode, .distanceField, "Real authored fields select the actual mode")
        var different = object; different.id = "U"; different.pointSize = 9; different.font = "RobotoMono-Regular.ttf"
        let mixed = try WPEParityTextFieldAdmission.requests([.init(object), .init(different)], texts: [:])
        XCTAssertEqual(mixed.map(\.glyphMode), [.distanceField, .distanceField])
        XCTAssertNoThrow(try WPEParityTextFieldAdmission.validate([object, different]))
        var nonfinite = different; nonfinite.dropShadowSize = .nan
        XCTAssertThrowsError(try WPEParityTextFieldAdmission.validate([object, nonfinite])) {
            XCTAssertEqual($0 as? WPEParityTextPreparationError, .nonfiniteDrawParameters)
        }
    }

    func text() -> WPEParityTextObject {
        WPEParityTextObject(json: .object(["id": .string("T"), "text": .string("H"),
                                           "font": .string("NotoSans-Regular.ttf"), "pointsize": .number(8), "msdf": .bool(true)]))
    }

    private func fixedFontRoot() throws -> URL {
        PackageTestAssets.fonts
    }

}
