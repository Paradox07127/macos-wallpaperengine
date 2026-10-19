import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramMaterialBoundsTests: XCTestCase {
    func testModelMaterialLoadRejectsOutOfRangeCombos() throws {
        for value in [1e100, -1e100, Double(Int32.max) + 1, Double(Int32.min) - 1] {
            let fixture = try materialScene(["combos": ["MODE": value]])
            XCTAssertNil(fixture.scene.modelDataMesh(materialPath: Self.materialPath), "\(value)")
            XCTAssertNil(fixture.scene.material(for: fixture.draw), "An invalid material must not bind a default combo")
        }
    }

    func testModelMaterialLoadPreservesTruncationAndInt32Boundaries() throws {
        let fixture = try materialScene(["combos": [
            "MIN": Double(Int32.min) - 0.75, "MAX": Double(Int32.max) + 0.75,
            "POSITIVE": 1.9, "NEGATIVE": -1.9, "WRAPPED": ["value": 7.8], "BOOL": true,
        ]])
        XCTAssertEqual(fixture.scene.modelDataMesh(materialPath: Self.materialPath)?.shader, "bounds")
        let material = try XCTUnwrap(fixture.scene.material(for: fixture.draw))
        XCTAssertEqual(material.combos, ["MIN": .min, "MAX": .max, "POSITIVE": 1, "NEGATIVE": -1,
                                         "WRAPPED": 7, "BOOL": 1])
    }

    func testModelMaterialLoadRejectsInvalidReferenceDimensions() throws {
        for dimension in ["width", "height"] {
            for value in [1e100, -1e100, Double(Int.max), 0, 0.9] {
                var reference: [String: Double] = ["width": 64, "height": 32]
                reference[dimension] = value
                let fixture = try materialScene(["usertexturereference": reference])
                XCTAssertNil(fixture.scene.modelDataMesh(materialPath: Self.materialPath), "\(dimension)=\(value)")
            }
        }
    }

    func testModelMaterialLoadPreservesRepresentableReferenceDimensions() throws {
        let largest = Double(Int.max).nextDown
        for (width, height) in [(1.9, 2048.75), (largest, 1)] {
            let fixture = try materialScene(["usertexturereference": ["width": width, "height": height]])
            XCTAssertNotNil(fixture.scene.modelDataMesh(materialPath: Self.materialPath))
            let material = try XCTUnwrap(fixture.scene.material(for: fixture.draw))
            XCTAssertEqual(material.userTextures.reference,
                           SIMD2(Int(width.rounded(.towardZero)), Int(height.rounded(.towardZero))))
        }
        for fields: [String: Any] in [[:], ["usertexturereference": NSNull()]] {
            let fixture = try materialScene(fields)
            XCTAssertNotNil(fixture.scene.modelDataMesh(materialPath: Self.materialPath))
            XCTAssertNil(fixture.scene.material(for: fixture.draw)?.userTextures.reference)
        }
    }

    func testEffectMaterialRejectsAnOutOfRangeBindingAsAWholePass() throws {
        for value in [1e100, -1e100, Double(Int32.max) + 1, Double(Int32.min) - 1] {
            let scene = try effectScene(index: value)
            XCTAssertTrue(try XCTUnwrap(scene.scene.objects.first?.effects.first).passes.isEmpty)
            let record = try XCTUnwrap(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "1")]?.first)
            XCTAssertEqual(record.materialPath, "materials/bounds.json")
            XCTAssertNil(record.materialPass, "A partial binding table must not become a ready pass")
        }
    }

    func testEffectMaterialBindingRetainsTruncation() throws {
        let scene = try effectScene(index: 1.9)
        let pass = try XCTUnwrap(scene.scene.objects.first?.effects.first?.passes.first)
        let draw = WPEParitySceneDraw(pass: "test", objectID: "7", effectID: "1", shader: "bounds",
                                      source: pass.source, reads: [], target: "backbuffer", blend: .normal,
                                      writeMask: .rgba, geometry: .fullscreenQuad)
        XCTAssertEqual(scene.material(for: draw)?.textures[1], "util/bound")
    }

    private static let materialPath = "materials/bounds.json"

    /// Uses the public scene/ModelData material loader with actual JSON bytes, without a workshop or shader toolchain.
    private func materialScene(_ fields: [String: Any]) throws
        -> (scene: WPEParityProgramScene, draw: WPEParitySceneDraw) {
        var pass: [String: Any] = ["shader": "bounds"]
        pass.merge(fields) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: ["passes": [pass]])
        let root = URL(fileURLWithPath: "/material-bounds-fixture")
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { path in
            path == Self.materialPath ? bytes : nil
        }])
        let document = try WPESceneDocumentParser.parse(data: Data(#"{"camera":{"center":"0 0 0"},"general":{"orthogonalprojection":{"width":64,"height":64}},"objects":[]}"#.utf8),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in MaterialBoundsNoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        let draw = WPEParitySceneDraw(pass: "test", objectID: "1", shader: "bounds",
                                      source: .init(materialPath: Self.materialPath), reads: [], target: "backbuffer",
                                      blend: .normal, writeMask: .rgba, geometry: .modelMesh)
        return (scene, draw)
    }

    private func effectScene(index: Double) throws -> WPEParityProgramScene {
        let pass = ParitySceneDocuments.pass("bounds", extra: ["bind": [["name": "util/bound", "index": index]]])
        return try ParitySceneDocuments.programScene([
            .init(id: "7", json: ["id": 7, "image": "models/7.json", "size": "64 64"],
                  effects: [.init(id: "1", passes: [pass])]),
        ])
    }
}

private struct MaterialBoundsNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
