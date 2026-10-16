import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParitySceneCreatedLayerTests: XCTestCase {
    func testCreatedImageLayerIDKeepsExplicitIDAndSkipsReservedIDs() throws {
        let source: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 1, "image": "models/a.json", "origin": "8 8 0", "color": "0 1 0", "alpha": 0.5],
                ["id": 2, "name": "sound", "sound": ["sounds/a.mp3"]],
                ["id": 4, "image": "models/b.json"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in CreatedLayerNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let membership = state.membershipGeneration

        let first = try state.appendImageLayer(cloning: "1", id: nil) { $0.origin = SIMD3(30, 30, 0) }
        XCTAssertEqual(first, 3, "The counter must skip the ids the document reserves, sound objects included")
        let created = try XCTUnwrap(state.object("3"))
        XCTAssertEqual(created.templateID, "1")
        XCTAssertEqual(created.origin, SIMD3(30, 30, 0))
        XCTAssertEqual(created.color, SIMD3(0, 1, 0))
        XCTAssertEqual(created.alpha, 0.5)
        XCTAssertNil(created.modelDataToken)
        XCTAssertEqual(state.commonOrder.last, "3")
        XCTAssertGreaterThan(state.membershipGeneration, membership)

        XCTAssertEqual(try state.appendImageLayer(cloning: "1", id: 7) { _ in }, 7)
        XCTAssertThrowsError(try state.appendImageLayer(cloning: "1", id: 4) { _ in })
        XCTAssertEqual(try state.appendImageLayer(cloning: "1", id: nil) { _ in }, 5)
        XCTAssertEqual(try state.appendImageLayer(cloning: "1", id: nil) { _ in }, 6)
        XCTAssertEqual(try state.appendImageLayer(cloning: "1", id: nil) { _ in }, 8,
                       "An explicit created id is reserved like a loaded one")
        XCTAssertThrowsError(try state.appendImageLayer(cloning: "missing", id: nil) { _ in })
    }

    func testCloneAdoptsLoadedEffectStateIndependently() throws {
        let effect: [String: Any] = ["id": 5, "file": "effects/tint/effect.json", "visible": false,
                                     "passes": [["constantshadervalues": ["k": 0.25]]]]
        let source: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "image": "models/a.json", "origin": "8 8 0", "effects": [effect]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in CreatedLayerNoScripts() })
        let templatePass = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        let loaded = WPEParitySceneState(document: document, hdr: false, constants: [templatePass: ["k": [0.25]]])
        var state = loaded
        XCTAssertTrue(state.setConstant("k", of: templatePass, to: .init(value: SIMD4(0.75, 0, 0, 0), count: 1)))

        let clone = try String(state.appendImageLayer(cloning: "1", id: 9, adopting: loaded) { _ in })
        let clonePass = WPEParityMaterialPassKey(objectID: clone, effectID: "5", pass: 0)
        XCTAssertEqual(state.isEffectVisible("5", of: clone), false, "The clone starts from the loaded visibility")
        XCTAssertEqual(state.constant("k", of: clonePass)?.value.x, 0.25, "The clone starts from the loaded constants")
        XCTAssertTrue(state.setEffect("5", of: clone, visible: true))
        XCTAssertEqual(state.isEffectVisible("5", of: clone), true)
        XCTAssertEqual(state.isEffectVisible("5", of: "1"), false, "A clone write must not reach its template")
        XCTAssertEqual(state.constant("k", of: templatePass)?.value.x, 0.75)

        let clone2 = try String(state.appendImageLayer(cloning: "1", id: 10) { _ in })
        XCTAssertNil(state.isEffectVisible("5", of: clone2))
        XCTAssertNil(state.passIndex(of: .init(objectID: clone2, effectID: "5", pass: 0)))
    }
}

private struct CreatedLayerNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
