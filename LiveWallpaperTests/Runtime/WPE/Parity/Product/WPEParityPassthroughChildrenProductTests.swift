#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 1401e8aa0.c:186-257: a composelayer with a child and no effect composes over the frame under its own quad.
    func testPassthroughChildrenWithoutEffectPublishOnTheLayerQuad() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files: [String: Data] = [:]
        for (name, pixel) in [("red", [UInt8]([255, 0, 0, 255])), ("blue", [0, 0, 255, 255]),
                              ("green", [0, 255, 0, 255])] {
            let documents: [String: Any] = [
                "models/children-\(name).json": ["material": "materials/children-\(name).json"],
                "materials/children-\(name).json": ["passes": [["shader": "genericimage2",
                                                                "textures": ["children-\(name)-texture"],
                                                                "blending": "normal", "cullmode": "nocull",
                                                                "depthtest": "disabled", "depthwrite": "disabled"]]],
            ]
            for (path, document) in documents {
                files[path] = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            }
            files["materials/children-\(name)-texture.tex"] = cameraWitnessTexture(pixel)
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "image": "models/children-red.json", "origin": "8 8 0", "size": "16 16"],
                ["id": 2, "image": "models/children-blue.json", "origin": "4 4 0", "size": "4 4"],
                ["id": 3, "image": "models/util/composelayer.json", "origin": "12 12 0", "size": "8 8"],
                ["id": 4, "image": "models/children-green.json", "parent": 3, "origin": "0 0 0", "size": "2 2"],
            ],
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "passthrough-children-cache")))
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
        try await settle(driver, label: "passthrough children frame")
        XCTAssertNil(command.error)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let pixels = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up.
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((15 - y) * 16 + x) * 4
            return (0 ..< 3).map { Int(pixels[offset + $0]) }
        }
        for (x, y, rgb, label) in [(4, 4, [0, 0, 255], "blue"), (12, 12, [0, 255, 0], "green"),
                                   (9, 9, [255, 0, 0], "red"), (1, 14, [255, 0, 0], "red")] {
            for (channel, value) in zip(pixel(x, y), rgb) {
                XCTAssertLessThanOrEqual(abs(channel - value), 1, "(\(x), \(y)) must be \(label): \(pixel(x, y))")
            }
        }
    }
}
#endif
