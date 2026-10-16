#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

extension WPEParitySceneDriverTests {
    /// A material texture with no file reaches both the imported layer-image and the direct effect-asset binding as
    /// WPE's 6×6 checker (1400ec220.c:203-234, 140170510), through real Driver load and present.
    @MainActor @objc func testMissingMaterialTextureDrawsTheNativeCheckerPlaceholder() async throws {
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 1, "Required isolated native-size product gate")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let (imported, direct) = try await missingTextureRender(driver, device: device, texture: "missing-product",
                                                                files: [:])
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let importedDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == imported }?.draw)
        let directDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == direct }?.draw)
        let texture = try XCTUnwrap(importedDraw.textures["g_Texture0"])
        XCTAssertTrue(try XCTUnwrap(directDraw.textures["g_Texture0"]) === texture, "One placeholder feeds both binding kinds")
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual([texture.width, texture.height, texture.mipmapLevelCount], [6, 6, 1])
        var bytes = [UInt8](repeating: 0, count: 6 * 6 * 4)
        texture.getBytes(&bytes, bytesPerRow: 6 * 4, from: MTLRegionMake2D(0, 0, 6, 6), mipmapLevel: 0)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "cb7648a7884ca5352905656ec4b792c8a4b5016534ea8ff94081734bcaa1565f")
        for draw in [importedDraw, directDraw] {
            XCTAssertEqual(draw.samplers["g_Texture0SamplerState"], WPEParitySamplerState.wpeFileTexture(flags: 9))
        }
        let raw = try readBack(renderer.backbuffer, device: renderer.backbuffer.device)
        let (width, height) = (renderer.backbuffer.width, renderer.backbuffer.height)
        for x in [width / 4, width * 3 / 4] {
            let at = (height / 2 * width + x) * 4
            let pixel = Array(raw[at ..< at + 4]).map(Int.init)
            let matches = [[0, 0, 0, 255], [255, 255, 0, 255]].contains { expected in
                zip(pixel, expected).allSatisfy { abs($0 - $1) <= 1 }
            }
            XCTAssertTrue(matches, "Checker texel at quad centre \(x): \(pixel)")
        }
    }

    /// A present file the decoder rejects stays a typed texture skip; only a missing file gets the placeholder.
    @MainActor @objc func testMalformedMaterialTextureStillSkipsTheDraw() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let broken = Data("TEXV0005\0".utf8) + Data(count: 8)
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let (imported, direct) = try await missingTextureRender(driver, device: device, texture: "broken-product",
                                                                files: ["materials/broken-product.tex": broken])
        let renderer = try XCTUnwrap(driver.renderer)
        for operation in [imported, direct] {
            guard case let .texture(reason)? = renderer.skipped[operation] else {
                XCTFail("Operation \(operation) must be a texture skip: \(renderer.skipped)")
                continue
            }
            XCTAssertTrue(reason.contains("materials/broken-product.tex"), reason)
        }
    }

    /// Loads and presents one frame; returns the operation keys of object 1's imported draw and object 2's effect draw.
    @MainActor private func missingTextureRender(_ driver: WPEParitySceneDriver, device: MTLDevice, texture: String,
                                                 files: [String: Data]) async throws -> (Int, Int) {
        let (original, compiler) = try missingTextureInputs()
        let (sceneJSON, assets) = try missingTextureScene(original: original, texture: texture, files: files)
        let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: [:])
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 64, height: 16), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.drawableSize = CGSize(width: 64, height: 16)
        layer.framebufferOnly = false
        try await present(driver, layer: layer, label: "missing texture \(texture)")
        let renderer = try XCTUnwrap(driver.renderer)
        let frame = try XCTUnwrap(renderer.frames.first)
        let imported = try XCTUnwrap(frame.draws.first { _, value in
            guard case let .scene(draw) = value else { return false }
            return draw.objectID == "1" && draw.effectID == nil && draw.shader == "passthrough"
        })
        let direct = try XCTUnwrap(frame.draws.first { _, value in
            guard case let .scene(draw) = value else { return false }
            return draw.objectID == "2" && draw.effectID != nil && draw.shader == "passthrough"
        })
        return (imported.key, direct.key)
    }

    private func missingTextureInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, original) = try sceneInputs()
            for (path, expected) in [
                ("shaders/passthrough.vert", "ff6cd2bb166ce427c73058f3f77f338442d83fab9883f302e31bbffd81fa5317"),
                ("shaders/passthrough.frag", "db8586701eeda50c731af880411451be673180049ede8def28932d7180052109"),
                ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
                ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
                ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
                ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
            ] {
                let bytes = try XCTUnwrap(original.data(path), path)
                _ = try XCTUnwrap(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected ? true : nil,
                                  "Required original shader/resource identity: \(path)")
            }
            let contents = Bundle.main.bundleURL.appending(path: "Contents")
            let compiler = try WPEParityHelperShaderCompiler(
                helper: contents.appending(path: "MacOS/wpe-shaderc"),
                dxcompiler: contents.appending(path: "Frameworks/libdxcompiler.dylib"),
                metalIRConverter: contents.appending(path: "Frameworks/libmetalirconverter.dylib"),
                workDirectory: scratch.appending(path: "missing-texture-bundled-shaderc")
            )
            return (original, compiler)
        } catch {
            throw NSError(domain: "WPEParityMissingTextureProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled compiler unavailable: \(error)"])
        }
    }

    /// Object 1 imports `texture` as its layer image; object 2's effect binds it directly.
    private func missingTextureScene(original: WPEParityProgramAssets, texture: String,
                                     files extra: [String: Data]) throws -> (Data, WPEParityProgramAssets) {
        let pass: [String: Any] = ["shader": "passthrough", "textures": [texture],
                                   "combos": ["TRANSFORM": 1], "blending": "normal"]
        let files: [String: Data] = try extra.merging([
            "models/missing-product.json": JSONSerialization.data(withJSONObject: ["material": "materials/missing-product.json"]),
            "materials/missing-product.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "effects/missing-product.json": JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/missing-product.json"]]]),
        ]) { $1 }
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }] + original.sources)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 16], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [
                ["id": 1, "name": "missing-imported", "image": "models/missing-product.json",
                 "origin": "16 8 0", "size": "32 16", "alpha": 1],
                ["id": 2, "name": "missing-direct", "image": "models/util/solidlayer.json",
                 "origin": "48 8 0", "size": "32 16", "color": "0 0 0", "alpha": 1,
                 "effects": [["id": 4, "file": "effects/missing-product.json"]]],
            ],
        ]
        return try (JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), assets)
    }
}
#endif
