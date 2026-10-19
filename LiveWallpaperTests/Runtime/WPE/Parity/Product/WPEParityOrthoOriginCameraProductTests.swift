#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 140186c90.c:1045-1052: an ortho scene without camera paths draws from eye 0 whatever `camera` authored.
    func testOrthoSceneWithoutPathsDrawsFromTheOriginEye() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files = try [
            "models/origin-witness.json": ["material": "materials/origin-witness.json"] as [String: Any],
            "materials/origin-witness.json": ["passes": [["shader": "genericimage2", "textures": ["origin-red"],
                                                          "blending": "normal", "cullmode": "nocull"]]],
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        files["materials/origin-red.tex"] = cameraWitnessTexture([255, 0, 0, 255])
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "4 0 -1", "eye": "4 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false],
            "objects": [["id": 1, "image": "models/origin-witness.json", "origin": "8 8 0", "size": "2 2"]],
        ]), userValues: [:])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "origin-cache")))
        let renderer = try XCTUnwrap(driver.renderer)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100,
                                                                 pointer: SIMD2(repeating: 0.5)))
        await command.completed()
        try await settle(driver, label: "origin frame")
        XCTAssertNil(command.error)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertEqual(renderer.pathCamera.eye, .zero)
        XCTAssertEqual(renderer.pathCamera.center, SIMD3(0, 0, -1))
        let pixels = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up; the 2×2 square covers x and y 7...8.
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let offset = ((15 - y) * 16 + x) * 4
            return abs(Int(pixels[offset]) - 255) <= 1 && pixels[offset + 1] <= 1 && pixels[offset + 2] <= 1
        }
        for (x, y) in [(7, 7), (8, 8)] {
            XCTAssertTrue(isRed(x, y), "(\(x), \(y)) must be red")
        }
        for (x, y) in [(3, 7), (4, 8), (6, 7), (9, 8)] {
            XCTAssertFalse(isRed(x, y), "(\(x), \(y)) must stay clear")
        }
    }
}
#endif
