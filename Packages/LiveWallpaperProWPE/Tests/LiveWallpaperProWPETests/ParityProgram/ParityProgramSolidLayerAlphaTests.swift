import Foundation
@testable import LiveWallpaperProWPE
import XCTest

private typealias D = ParitySceneDocuments

final class ParityProgramSolidLayerAlphaTests: XCTestCase {
    func testUnauthoredSolidLayerKeepsAlphaOneInLoadedLayerColor() throws {
        for image in ["models/util/solidlayer.json", "models/util/solidlayer_depthtest.json"] {
            func color(_ json: [String: Any], visible: Bool = true) throws -> SIMD4<Float>? {
                var layer = D.layer(image: image, json: json,
                                    effects: [D.effect(visible: visible, passes: [D.pass("fx")])])
                layer.model = ["material": "materials/util/solidlayer.json", "solidlayer": true]
                return try D.programScene([layer]).layerColors["7"]
            }
            XCTAssertEqual(try color(["color": "0.2 0.4 0.6"]), SIMD4(0.2, 0.4, 0.6, 1), image)
            XCTAssertEqual(try color(["color": "0.2 0.4 0.6", "alpha": 0.25]), SIMD4(0.2, 0.4, 0.6, 0.25), image)
            XCTAssertEqual(try color(["color": "0.2 0.4 0.6"], visible: false), SIMD4(0.2, 0.4, 0.6, 1), image)
        }
    }

    func testUnauthoredSolidLayerLiveAlphaIsOne() throws {
        let effects: [[String: Any]] = [["id": 1, "file": "effects/fx.json", "visible": true]]
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 7, "image": "models/util/solidlayer.json", "size": "64 64", "effects": effects],
                ["id": 8, "image": "models/util/solidlayer.json", "size": "64 64", "effects": effects, "alpha": 0.25],
                ["id": 9, "shape": "quad", "effects": effects],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let state = WPEParitySceneState(document: document, hdr: false)
        XCTAssertEqual(state.object("7")?.alpha, 1)
        let index = try XCTUnwrap(state.index(of: "7"))
        XCTAssertEqual(state.layerColor(at: index).w, 1)
        XCTAssertEqual(state.object("8")?.alpha, 0.25)
        XCTAssertEqual(state.object("9")?.alpha, 0)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
