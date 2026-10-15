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
    /// Uses only the pre-ModelData Driver/Renderer/State surface so the identical source can exercise 2287affc.
    /// A narrow-index truncation addresses only degenerate vertices and cannot produce the required white pixel.
    func testOpaqueRegisteredModelDataDrawsWideIndicesWithOriginalShader() async throws {
        let original: WPEParityProgramAssets
        do {
            original = try sceneInputs().1
        } catch {
            throw NSError(domain: "OpaqueModelData.RequiredOriginal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original inputs unavailable: \(error)"])
        }
        for (path, expected) in [
            ("scripts/jsclasses/baseclasses.js", "708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294"),
            ("shaders/genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("shaders/genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_pbr.h", "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let bytes = try XCTUnwrap(original.data(path), path)
            _ = try XCTUnwrap(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected ? true : nil,
                              "required original byte identity: \(path)")
        }
        let overrideKeys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                            "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        _ = try XCTUnwrap(overrideKeys.allSatisfy { ProcessInfo.processInfo.environment[$0] == nil } ? true : nil,
                          "the comparison requires the current app-bundle compiler")
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(error): throw NSError(domain: "OpaqueModelData.RequiredBundleCompiler", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let toolHashes = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { path in
                let url = contents.appending(path: path).resolvingSymlinksInPath()
                _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil,
                                  "compiler component must resolve inside the current app bundle")
                return try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        _ = try XCTUnwrap(compiler.compilerIdentity == "wpe-shaderc " + toolHashes.joined(separator: " ") ? true : nil,
                          "actual compiler identity must match all three bundle components")
        let source = #"""
        const material = engine.registerAsset('materials/opaque-model-data.json', true);
        let layer;
        export function init(value) {
          const vertices = new Float32Array(65539 * 5);
          vertices.set([-4,-4,0,.5,.5],65536*5);
          vertices.set([4,-4,0,.5,.5],65537*5);
          vertices.set([0,4,0,.5,.5],65538*5);
          const model = thisScene.createModelData({vertexBuffer:vertices,
            indexBuffer:new Uint32Array([65536,65537,65538]),
            vertexFormat:[IModelData.POSITION,IModelData.UV],material:material,
            boundingBoxMins:new Vec3(-4,-4,0),boundingBoxMaxs:new Vec3(4,4,0)});
          if (!model) throw Error('opaque ModelData creation did not publish its wrapper');
          layer = thisScene.createLayer({id:700101,name:'opaque wide model',model:model,origin:'24 16 0'});
          if (!layer || thisScene.getLayer('opaque wide model') !== layer)
            throw Error('opaque numeric layer creation did not publish the common layer');
          thisLayer.brightness = 7;
          return 0;
        }
        export function update(value) {
          if (thisScene.getLayer('opaque wide model') !== layer) throw Error('opaque layer lost before its draw');
          thisLayer.brightness = 8;
          return 0;
        }
        """#
        let material = try JSONSerialization.data(withJSONObject: ["passes": [["shader": "genericimage2",
                                                                               "textures": ["util/white"], "blending": "normal", "cullmode": "nocull",
                                                                               "depthtest": "disabled", "depthwrite": "disabled"]]], options: [.sortedKeys])
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { path in
            path == "materials/opaque-model-data.json" ? material : nil
        }] + original.sources)
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 48, "height": 32, "auto": false],
                        "clearcolor": "0 0 0", "bloom": false],
            "objects": [["id": 1, "name": "opaque controller", "image": "models/util/solidlayer.json", "size": "1 1",
                         "brightness": 0, "alpha": ["value": 0, "script": source]]],
        ], options: [.sortedKeys])
        let document = try WPESceneDocumentParser.parse(data: scene, userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        // Input identities and GPU availability are prerequisites; the actual run must still distinguish a
        // compiler/loader prerequisite failure from the missing feature's script state or pixels.
        print("opaque-modeldata inputsReady originalSHA=qualified compilerOrigin=current-app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        print("opaque-modeldata sceneSHA256=\(SHA256.hash(data: scene)) materialSHA256=\(SHA256.hash(data: material))")
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "opaque-model-cache")))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.pathCamera.size, SIMD2<Float>(48, 32), "explicit camera qualifies the pixel coordinates")
        let script = try XCTUnwrap(renderer.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(renderer.state.object("1")).brightness, 7)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let submitted = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await submitted.completed()
        try await settle(driver, label: "opaque registered wide-index model")
        XCTAssertNil(submitted.error)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(renderer.state.object("1")).brightness, 8)
        let pixels = try readBack(renderer.backbuffer, device: device)
        for (x, expected) in [(24, 255), (8, 0), (40, 0)] {
            for lane in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(pixels[(16 * 48 + x) * 4 + lane]) - expected), 1,
                                         "original shader wide-index pixel \(x),16 lane\(lane)")
            }
        }
    }
}
#endif
