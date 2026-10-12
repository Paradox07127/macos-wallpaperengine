import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityTextPlannerTests: XCTestCase {
    static func makePlanner() throws -> WPEParityTextPlanner {
        let font = ParityFontChainTests.assetsRoot.appendingPathComponent(ParityFontChainTests.notoSans)
        guard FileManager.default.fileExists(atPath: font.path) else {
            throw XCTSkip("Wallpaper Engine assets fonts not installed at \(font.path)")
        }
        return WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)]))
    }

    static func textObject(_ id: String = "T", text: String = "Hi", colorBlendMode: Int = 0,
                           opaqueBackground: Bool = false, depthTest: String? = nil) -> WPEParityTextObject {
        var fields: [String: WPESceneJSONValue] = [
            "id": .string(id), "text": .string(text), "font": .string(ParityFontChainTests.notoSans),
            "pointsize": .number(32), "colorBlendMode": .number(Double(colorBlendMode)),
            "opaquebackground": .bool(opaqueBackground),
        ]
        fields["depthtest"] = depthTest.map(WPESceneJSONValue.string)
        return WPEParityTextObject(json: .object(fields))
    }

    func testEveryQuadTakesItsAtlasEntryUVs() throws {
        let planner = try Self.makePlanner()
        let (layout, key) = planner.plan(Self.textObject(), effectCount: 0)
        let mesh = try XCTUnwrap(layout.mesh)
        let atlas = try XCTUnwrap(planner.atlases[key]).mono
        XCTAssertEqual(mesh.mono.glyphKeys.count, 2)
        XCTAssertTrue(mesh.color.glyphKeys.isEmpty)
        for (quad, glyph) in mesh.mono.glyphKeys.enumerated() {
            let uv = try XCTUnwrap(atlas.entry(forKey: glyph)).uv
            let corners = mesh.mono.vertices[quad * 4 ..< quad * 4 + 4].map { SIMD2($0.u, $0.v) }
            XCTAssertEqual(corners, [SIMD2(uv.x, uv.y), SIMD2(uv.z, uv.y), SIMD2(uv.x, uv.w), SIMD2(uv.z, uv.w)])
            XCTAssertNotEqual(uv.x, uv.z)
        }
        XCTAssertEqual(key, WPEParityGlyphAtlasInstance.key(fontPath: ParityFontChainTests.notoSans, pointSize: 32))
    }

    func testReplanningTheSameTextInsertsNothing() throws {
        let planner = try Self.makePlanner()
        let first = planner.plan(Self.textObject(), effectCount: 0)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.takeDirty(), true)
        let second = planner.plan(Self.textObject(), effectCount: 0)
        XCTAssertEqual(second.layout, first.layout)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.isDirty, false)
        // Another object at the same font and size shares the instance.
        _ = planner.plan(Self.textObject("U", text: "iH"), effectCount: 0)
        XCTAssertEqual(planner.atlases.count, 1)
        XCTAssertEqual(planner.atlases[first.atlasKey]?.mono.isDirty, false)
    }

    func testGlyphAndFBOTranslationsFollowTheQ6Formulas() throws {
        let planner = try Self.makePlanner()
        let object = Self.textObject()
        let direct = try XCTUnwrap(planner.plan(object, effectCount: 0).layout.mesh)
        let width = direct.maxX - direct.minX
        let height = direct.top - direct.bottom
        XCTAssertEqual(WPEParityTextMatrices.glyphTranslation(direct),
                       SIMD2(-width / 2 - min(direct.minX, 0), height / 2 - direct.top))

        let (layout, key) = planner.plan(object, effectCount: 1)
        let text = WPEParitySceneText(object: object, effectCount: 1, layout: layout, atlasKey: key, hdr: false,
                                      orthographic: true)
        let mesh = try XCTUnwrap(layout.mesh)
        XCTAssertEqual(text.padding, SIMD2(32, 32))
        XCTAssertEqual(WPEParityTextMatrices.fboGlyphTranslation(mesh, padding: text.padding),
                       SIMD2(32 - min(mesh.minX, 0), 32 - mesh.bottom))
        XCTAssertEqual(WPEParityTextMatrices.backgroundTranslation(mesh, padding: text.padding),
                       SIMD2(-(mesh.maxX - mesh.minX) / 2 - 32, -(mesh.top - mesh.bottom) / 2 - 32))
        XCTAssertEqual(layout.fboSize, SIMD2(Int(64 + mesh.maxX - mesh.minX), Int(64 + mesh.top - mesh.bottom)))

        let fbo = WPEParityTextMatrices.fbo(size: layout.fboSize, translation: SIMD2(10, 20))
        XCTAssertEqual(fbo.view, matrix_identity_float4x4)
        XCTAssertEqual(fbo.model.columns.3, SIMD4(10, 20, 0, 1))
        // FBO pixel (0, 0) lands on clip (-1, -1).
        let corner = fbo.projection * SIMD4(0, 0, 0, 1)
        XCTAssertEqual(SIMD2(corner.x, corner.y), SIMD2(-1, -1))
    }

    func testAnchorsMoveByTheCropMarginsInOrthographicScenesOnly() {
        let margins = WPEParityTextCropMargins(left: 10, top: 20, right: 30, bottom: 40)
        let expected: [(WPEParityTextAnchor, SIMD2<Float>)] = [
            (.none, .zero), (.center, SIMD2(-10, 10)), (.top, SIMD2(-10, -20)), (.topRight, SIMD2(-30, -20)),
            (.right, SIMD2(-30, 10)), (.bottomRight, SIMD2(-30, 40)), (.bottom, SIMD2(-10, 40)),
            (.bottomLeft, SIMD2(10, 40)), (.left, SIMD2(10, 10)), (.topLeft, SIMD2(10, -20)),
        ]
        for (anchor, offset) in expected {
            XCTAssertEqual(WPEParityTextMatrices.anchorOffset(anchor, margins: margins, orthographic: true), offset,
                           "\(anchor)")
            XCTAssertEqual(WPEParityTextMatrices.anchorOffset(anchor, margins: margins, orthographic: false), .zero,
                           "\(anchor)")
        }
        let model = WPEParityTextMatrices.layerModel(simd_float4x4(diagonal: SIMD4(2, 2, 1, 1)),
                                                     anchorOffset: SIMD2(5, 6), blockOffset: SIMD2(1, 1))
        XCTAssertEqual(model.columns.3, SIMD4(7, 8, 0, 1))
    }

    func testCameraCropMarginsMatchTheOrthoBounds() {
        let camera = WPEParityCamera(eye: .zero, center: .zero, up: SIMD3(0, 1, 0), size: SIMD2(1920, 1080),
                                     renderTargetSize: SIMD2(1000, 1000),
                                     alignment: WPEParityCameraAlignment(mode: 0, position: 25))
        let margins = camera.cropMargins
        XCTAssertEqual(margins, WPEParityTextCropMargins(left: 630, top: 0, right: 210, bottom: 0))
        XCTAssertEqual(camera.bounds, SIMD4(630, 1920 - 210, 0, 1080))
    }
}
