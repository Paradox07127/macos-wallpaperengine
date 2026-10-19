#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 1401e8aa0.c:613-629: a passthrough composelayer with an effect captures the snapshot under its own quad.
    func testComposeLayerCaptureSamplesTheFrameUnderTheLayer() async throws {
        let original = try sceneInputs().1
        let root = try XCTUnwrap(original.roots.last)
        let compiler = try makeCompiler()
        var files: [String: Data] = [:]
        for (name, pixel) in [("red", [UInt8]([255, 0, 0, 255])), ("blue", [0, 0, 255, 255])] {
            let documents: [String: Any] = [
                "models/capture-\(name).json": ["material": "materials/capture-\(name).json"],
                "materials/capture-\(name).json": ["passes": [["shader": "genericimage2",
                                                               "textures": ["capture-\(name)-texture"],
                                                               "blending": "normal", "cullmode": "nocull",
                                                               "depthtest": "disabled", "depthwrite": "disabled"]]],
            ]
            for (path, document) in documents {
                files[path] = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            }
            files["materials/capture-\(name)-texture.tex"] = cameraWitnessTexture(pixel)
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources
            + [.directory(root.appending(path: "effects/opacity"))])
        let opacity: [String: Any] = ["id": 11, "file": "effects/opacity/effect.json", "visible": true,
                                      "passes": [["constantshadervalues": ["alpha": 1]]]]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "image": "models/capture-red.json", "origin": "8 8 0", "size": "16 16"],
                ["id": 2, "image": "models/capture-blue.json", "origin": "2 8 0", "size": "4 4"],
                ["id": 3, "image": "models/util/composelayer.json", "origin": "8 8 0", "size": "8 16",
                 "effects": [opacity]],
            ],
        ]), userValues: [:])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "compose-capture-cache")))
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
        try await settle(driver, label: "compose capture frame")
        XCTAssertNil(command.error)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let pixels = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up.
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((15 - y) * 16 + x) * 4
            return (0 ..< 3).map { Int(pixels[offset + $0]) }
        }
        for (x, y, rgb, label) in [(5, 8, [255, 0, 0], "red"), (2, 8, [0, 0, 255], "blue")] {
            for (channel, value) in zip(pixel(x, y), rgb) {
                XCTAssertLessThanOrEqual(abs(channel - value), 1, "(\(x), \(y)) must be \(label): \(pixel(x, y))")
            }
        }
    }
}
#endif
