#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// 全 is e5 85 a8: the 0x85 byte must not cut the `// [COMBO]` line (140162100.c:113), or ZEROALPHA loses its
    /// default 1 and Difference (mode 18) of the opaque passthrough against itself turns the canvas black.
    func testComboDefaultBehindNonASCIIMaterialReachesComposeEffect() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files: [String: Data] = [:]
        for (name, pixel) in [("red", [UInt8]([255, 0, 0, 255])), ("blue", [0, 0, 255, 255])] {
            let documents: [String: Any] = [
                "models/combo-\(name).json": ["material": "materials/combo-\(name).json"],
                "materials/combo-\(name).json": ["passes": [["shader": "genericimage2",
                                                             "textures": ["combo-\(name)-texture"],
                                                             "blending": "normal", "cullmode": "nocull",
                                                             "depthtest": "disabled", "depthwrite": "disabled"]]],
            ]
            for (path, document) in documents {
                files[path] = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            }
            files["materials/combo-\(name)-texture.tex"] = cameraWitnessTexture(pixel)
        }
        files["effects/zeroalpha/effect.json"] = try JSONSerialization.data(withJSONObject: [
            "passes": [["material": "materials/effects/zeroalpha.json"]],
        ])
        files["materials/effects/zeroalpha.json"] = try JSONSerialization.data(withJSONObject: [
            "passes": [["shader": "effects/zeroalpha", "blending": "normal", "depthtest": "disabled",
                        "depthwrite": "disabled", "cullmode": "nocull"]],
        ])
        files["shaders/effects/zeroalpha.vert"] = Data("""
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
        \tgl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        \tv_TexCoord = a_TexCoord;
        }
        """.utf8)
        files["shaders/effects/zeroalpha.frag"] = Data("""
        // [COMBO] {"material":"完全","combo":"ZEROALPHA","type":"options","default":1}
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        void main() {
        \tvec4 albedo = texSample2D(g_Texture0, v_TexCoord);
        #if ZEROALPHA == 1
        \talbedo.a = 0.0;
        #endif
        \tgl_FragColor = albedo;
        }
        """.utf8)
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "image": "models/combo-red.json", "origin": "8 8 0", "size": "16 16"],
                ["id": 2, "image": "models/combo-blue.json", "origin": "2 8 0", "size": "4 4"],
                ["id": 3, "image": "models/util/composelayer.json", "origin": "8 8 0", "size": "8 8",
                 "scale": "2 2 2", "colorBlendMode": 18,
                 "effects": [["id": 11, "file": "effects/zeroalpha/effect.json", "visible": true]]],
            ],
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "combo-default-cache")))
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
        try await settle(driver, label: "combo default frame")
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
