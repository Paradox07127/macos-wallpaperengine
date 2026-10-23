#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

extension WPEParitySceneDriverTests {
    /// Parent W = T(12,4,0)·S(2,2,1); topleft shifts it by (2,−2) local, so W′ translation x = 12 + 2·2 = 16.
    /// Child W = W_parent·T(1,1,0) (x 14), left shifts it by (2,0) local, so its W′ x = 14 + 2·2 = 18 (1401fd3f0).
    func testGetTransformMatrixAnswersAlignedImageMatrixComposedOnParentWorld() async throws {
        let (_, original) = try sceneInputs()
        let compiler = try makeCompiler()
        let script = """
        export function init(value) {
          thisLayer.alpha = thisLayer.getParent().getTransformMatrix().m[12] / 100;
          thisLayer.brightness = thisLayer.getTransformMatrix().m[12] / 100;
          return value;
        }
        """
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0",
                        "bloom": false, "hdr": false, "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "image": "models/util/solidlayer.json", "solid": true, "size": "4 4",
                 "alignment": "topleft", "origin": "12 4 0", "scale": "2 2 1"],
                ["id": 2, "image": "models/util/solidlayer.json", "solid": true, "size": "4 4", "parent": 1,
                 "alignment": "left", "origin": ["value": "1 1 0", "script": script]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: original, settings: .init(bloom: false, hdrPostProcessing: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "transform-matrix-cache")))
        XCTAssertNil(driver.loadDiagnostics)
        let renderer = try XCTUnwrap(driver.renderer)
        let host = try XCTUnwrap(renderer.instance.script, "the actual Driver must attach SceneScript")
        XCTAssertEqual(host.engine.exceptionCount, 0, host.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(renderer.instance.state.object("2")?.alpha), 0.16, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(renderer.instance.state.object("2")?.brightness), 0.18, accuracy: 0.000001)
    }
}
#endif
