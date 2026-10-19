import CryptoKit
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Prepared mono consumer candidate, verified against separately qualified Windows original H bytes.
/// Root supplies the pinned original oracle directories and owns compilation/execution.
final class ParityTextDistanceConsumerTests: XCTestCase {
    func testOriginalHFieldFlowsThroughExistingPlannerAtlasAndQuad() throws {
        let oracle = try originalOutline()
        let planner = WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(oracle)]))
        let object = text()
        let bitmap = try XCTUnwrap(planner.layout(object, effectCount: 0).mesh)
        let prepared = try planner.plan(object, effectCount: 0, glyphMode: .distanceField)
        let mesh = try XCTUnwrap(prepared.layout.mesh)
        XCTAssertEqual(mesh.glyphMode, .distanceField)
        XCTAssertEqual(prepared.atlasKey, "NotoSans-Regular.ttf_msdf")
        let instance = try XCTUnwrap(planner.atlases[prepared.atlasKey])
        XCTAssertEqual(instance.mono.format, .rgba8)
        XCTAssertTrue(instance.colorGroups.isEmpty)
        let entry = try XCTUnwrap(instance.mono.entry(forKey: 43))
        XCTAssertEqual([entry.x0, entry.y0, entry.x1, entry.y1], [0, 0, 42, 47])
        XCTAssertEqual(entry.references, 1)
        var cell = Data()
        for y in entry.y0 ..< entry.y1 {
            let start = (y * instance.mono.width + entry.x0) * 4
            cell.append(contentsOf: instance.mono.pixels[start ..< start + 42 * 4])
        }
        XCTAssertEqual(cell, try Data(contentsOf: oracle.appendingPathComponent("rgba-cell.bin")))
        XCTAssertEqual([mesh.minX, mesh.maxX, mesh.top, mesh.bottom, mesh.lineHeight],
                       [bitmap.minX, bitmap.maxX, bitmap.top, bitmap.bottom, bitmap.lineHeight])
        XCTAssertEqual(prepared.layout.fboSize, try planner.layout(object, effectCount: 0).fboSize)
        XCTAssertEqual(prepared.layout.blockOffset, try planner.layout(object, effectCount: 0).blockOffset)
        let vertices = mesh.mono.vertices, ordinary = bitmap.mono.vertices
        XCTAssertEqual(vertices.count, 4)
        // Actual original y_ppem33: vertex-only gutter33*12/32=12.375, not the24px logical cell extent.
        XCTAssertEqual(vertices[0].x, ordinary[0].x - 12.375)
        XCTAssertEqual(vertices[0].y, ordinary[0].y + 12.375)
        XCTAssertEqual(vertices[3].x, ordinary[3].x + 12.375)
        XCTAssertEqual(vertices[3].y, ordinary[3].y - 12.375)
        XCTAssertEqual(vertices.map { SIMD2($0.u, $0.v) },
                       [SIMD2(0, 0), SIMD2(42.0 / 512, 0), SIMD2(0, 47.0 / 512), SIMD2(42.0 / 512, 47.0 / 512)])
    }

    func testZeroAreaSpaceReservesItsCellAndInvalidPreparationPreservesExistingReferences() throws {
        let outline = try originalOutline()
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
        let oracle = try originalOutline()
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

    private func text() -> WPEParityTextObject {
        WPEParityTextObject(json: .object(["id": .string("T"), "text": .string("H"),
                                           "font": .string("NotoSans-Regular.ttf"), "pointsize": .number(8), "msdf": .bool(true)]))
    }

    private func originalOutline() throws -> URL {
        try oracle(environment: "LOOMSCREEN_WPE_GLYPH_ORACLE_DIR",
                   manifestSHA: "ac47bffbf998d8ac6fb3bec69f2564b6f7578bb13509ffc575a759746a50da1f")
    }

    private func oracle(environment: String, manifestSHA: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environment] else {
            throw XCTSkip("Set \(environment) to the pinned original oracle directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(sha(manifest), manifestSHA)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        for file in files {
            let name = try XCTUnwrap(file["path"] as? String)
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertEqual(data.count, file["bytes"] as? Int)
            XCTAssertEqual(sha(data), file["sha256"] as? String)
        }
        return root
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
