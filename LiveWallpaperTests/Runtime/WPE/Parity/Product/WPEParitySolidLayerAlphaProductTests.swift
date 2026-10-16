#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 1401e6980.c:40: a solid layer without authored "alpha" draws its effect output at alpha 1, covering the clear.
    func testUnauthoredSolidLayerWithEffectDrawsOpaque() async throws {
        let (_, original) = try sceneInputs()
        let root = try XCTUnwrap(original.roots.last)
        let assets = WPEParityProgramAssets(sources: original.sources + [.directory(root.appending(path: "effects/tint"))])
        for (path, expected) in [
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("effects/tint/effect.json", "9bda1c7c508c71b90d7d51fbef45f06eb284691f8447000a3c98ef95dfdadbcc"),
            ("materials/effects/tint.json", "d5a190abf6ebc13981b7e26ca623577d2cfe0783a343e05fc1a46dcce7cb5016"),
            ("shaders/effects/tint.frag", "02b9397cec32de6f0d8caa2e1af7c07510752d474bd64048c9d78f55926973f1"),
        ] {
            let data = try XCTUnwrap(assets.data(path), path)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        // Default BLENDMODE 30: mix(c, max(c) · color, alpha), so white at 0.5 lifts each zero channel to 0.5.
        let tint: [String: Any] = ["id": 11, "file": "effects/tint/effect.json", "visible": true,
                                   "passes": [["constantshadervalues": ["color": "1 1 1", "alpha": 0.5]]]]
        let objects: [[String: Any]] = [
            ["id": 1, "image": "models/util/solidlayer.json", "size": "8 8", "origin": "8 8 0", "color": "1 0 0",
             "effects": [tint]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": objects,
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .rgba8Unorm,
                              compiler: makeCompiler(), diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let renderer = try XCTUnwrap(driver.renderer)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        try await present(driver, layer: layer, label: "solid layer tint")
        XCTAssertEqual(driver.shaderErrorSummary.count, 0)
        XCTAssertEqual(renderer.skipped, [:])
        let pixels = try readBack(renderer.backbuffer, device: device)
        let offset = (8 * 16 + 8) * 4
        let rgb = [255, 128, 128]
        XCTAssertLessThanOrEqual((0 ..< 3).map { abs(Int(pixels[offset + $0]) - rgb[$0]) }.max() ?? .max, 1,
                                 "\(Array(pixels[offset ..< offset + 4]))")
    }
}
#endif
