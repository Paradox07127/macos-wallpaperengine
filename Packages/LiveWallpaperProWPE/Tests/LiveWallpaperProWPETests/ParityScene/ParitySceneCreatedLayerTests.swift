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
}

private struct CreatedLayerNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
