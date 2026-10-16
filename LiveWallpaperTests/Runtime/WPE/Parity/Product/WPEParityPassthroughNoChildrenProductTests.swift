#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 1401e8aa0.c:185: a passthrough composelayer without effects or children draws nothing over the layers below.
    func testChildlessPassthroughLeavesTheFrameUntouched() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files: [String: Data] = [:]
        for (name, pixel) in [("red", [UInt8]([255, 0, 0, 255])), ("green", [0, 255, 0, 255])] {
            let documents: [String: Any] = [
                "models/passthrough-\(name).json": ["material": "materials/passthrough-\(name).json"],
                "materials/passthrough-\(name).json": ["passes": [["shader": "genericimage2",
                                                                   "textures": ["passthrough-\(name)-texture"],
                                                                   "blending": "normal", "cullmode": "nocull",
                                                                   "depthtest": "disabled",
                                                                   "depthwrite": "disabled"]]],
            ]
            for (path, document) in documents {
                files[path] = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            }
            files["materials/passthrough-\(name)-texture.tex"] = cameraWitnessTexture(pixel)
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false],
            "objects": [
                ["id": 1, "image": "models/passthrough-red.json", "origin": "8 8 0", "size": "16 16"],
                ["id": 2, "image": "models/passthrough-green.json", "origin": "4 4 0", "size": "4 4"],
                ["id": 3, "image": "models/util/composelayer.json", "origin": "12 12 0", "size": "2 2"],
            ],
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "passthrough-cache")))
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
        try await settle(driver, label: "passthrough frame")
        XCTAssertNil(command.error)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let pixels = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up.
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((15 - y) * 16 + x) * 4
            return (0 ..< 3).map { Int(pixels[offset + $0]) }
        }
        for (channel, value) in zip(pixel(4, 4), [0, 255, 0]) {
            XCTAssertLessThanOrEqual(abs(channel - value), 1, "(4, 4) must be green: \(pixel(4, 4))")
        }
        for (channel, value) in zip(pixel(12, 12), [255, 0, 0]) {
            XCTAssertLessThanOrEqual(abs(channel - value), 1, "(12, 12) must be red: \(pixel(12, 12))")
        }
    }
}
#endif
