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
    /// Actual object queue -> local transform -> selected camera -> original shader pixels, continued at resize.
    func testCameraQueueMovesOriginalDrawAndContinuesAcrossResizeAndHiddenParent() async throws {
        let original: WPEParityProgramAssets
        do { original = try sceneInputs().1 }
        catch { throw NSError(domain: "CameraQueue.RequiredOriginal", code: 1) }
        for (path, expected) in [
            ("shaders/genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_pbr.h", "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("shaders/genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let bytes = try XCTUnwrap(original.data(path), path)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected)
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                    "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        XCTAssertTrue(keys.allSatisfy { ProcessInfo.processInfo.environment[$0] == nil })
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(error): throw NSError(domain: "CameraQueue.BundleToolchain", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let hashes = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { path in
                let url = contents.appending(path: path).resolvingSymlinksInPath()
                _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil)
                return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        func item(_ x: Float, length: Int, zoom: Float) -> [String: Any] {
            let key: (Float) -> [[String: Any]] = { [["frame": 0, "value": $0], ["frame": length, "value": $0]] }
            return ["options": ["fps": 4, "length": length, "mode": "single"],
                    "eye": ["c0": key(x), "c1": key(0), "c2": key(0)],
                    "center": ["c0": key(x), "c1": key(0), "c2": key(-5)], "zoom": key(zoom)]
        }
        let resources: [String: Any] = [
            "models/queue-witness.json": ["material": "materials/queue-witness.json"],
            "materials/queue-witness.json": ["passes": [["shader": "genericimage2", "textures": ["util/white"],
                                                          "blending": "normal", "cullmode": "nocull"]]],
            "cameras/queue.json": ["paths": [item(0, length: 1, zoom: 1), item(4, length: 4, zoom: 2)]],
        ]
        let files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }] + original.sources)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0"],
            "objects": [
                ["id": 1, "image": "models/queue-witness.json", "origin": "12 8 0", "size": "2 2", "color": "1 0 0"],
                ["id": 3, "image": "models/queue-witness.json", "origin": "0 0 0", "size": "1 1", "color": "0 0 0",
                 "visible": ["value": true, "script": "let ticks = 0; export function update(value) { return ++ticks !== 4; }"]],
                ["id": 2, "camera": "queue witness", "parent": 3, "path": "cameras/queue.json", "queuemode": "sequential"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        print("camera queue scene SHA256=\(SHA256.hash(data: data))")
        for path in files.keys.sorted() { print("camera queue input \(path) SHA256=\(SHA256.hash(data: files[path]!))") }
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false, hdrPostProcessing: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "queue-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        for frame in 0 ... 6 {
            if frame == 3 {
                weak var old = driver.renderer
                driver.updateSurfaceGeometry(drawableSize: CGSize(width: 32, height: 32))
                let replanned = await driver.replan()
                XCTAssertTrue(replanned)
                layer.drawableSize = CGSize(width: 32, height: 32)
                XCTAssertNil(old)
            }
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(frame) * 0.25,
                                                                      pointer: SIMD2(0.5, 0.5)))
            await command.completed()
            try await settle(driver, label: "camera queue frame \(frame)")
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            let active = (2 ... 3).contains(frame) || frame >= 5
            XCTAssertEqual(renderer.pathCamera.eye.x, active ? 4 : 0, accuracy: 0.000001)
            XCTAssertEqual(renderer.pathCamera.zoom, active ? 2 : 1, accuracy: 0.000001)
            XCTAssertFalse(renderer.isStatic, "the authored visibility script must remain active")
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.draw.constants[.vertex]?["g_ModelViewProjectionMatrix"] != nil }?.draw)
            XCTAssertGreaterThan(draw.indexCount + draw.vertexCount, 0)
            let pixels = try readBack(renderer.backbuffer, device: device)
            let scale = frame >= 3 ? 2 : 1
            let x = active ? 8 : 12
            let offset = ((8 * scale) * (16 * scale) + x * scale) * 4
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - 255), 1)
            XCTAssertLessThanOrEqual(pixels[offset + 1], 1)
            XCTAssertLessThanOrEqual(pixels[offset + 2], 1)
        }
    }
}
#endif
