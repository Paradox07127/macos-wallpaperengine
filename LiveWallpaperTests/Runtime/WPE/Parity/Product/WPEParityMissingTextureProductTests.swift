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
        XCTAssertTrue(try XCTUnwrap(directDraw.textures["g_Texture1"]) === texture, "One placeholder feeds both binding kinds")
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual([texture.width, texture.height, texture.mipmapLevelCount], [6, 6, 1])
        var bytes = [UInt8](repeating: 0, count: 6 * 6 * 4)
        texture.getBytes(&bytes, bytesPerRow: 6 * 4, from: MTLRegionMake2D(0, 0, 6, 6), mipmapLevel: 0)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "cb7648a7884ca5352905656ec4b792c8a4b5016534ea8ff94081734bcaa1565f")
        for (draw, sampler) in [(importedDraw, "g_Texture0SamplerState"), (directDraw, "g_Texture1SamplerState")] {
            XCTAssertEqual(draw.samplers[sampler], WPEParitySamplerState.wpeFileTexture(flags: 9))
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

    /// FUN_140209360 sizes an autosize layer from its albedo, so a missing file makes the layer and its composite the 6×6
    /// placeholder (1400ec220.c:223-226); a present albedo of the authored size covers the authored 48×24.
    @MainActor @objc func testMissingAutosizeAlbedoShrinksTheLayerAndItsCompositeToThePlaceholder() async throws {
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 1, "Required isolated native-size product gate")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (original, compiler) = try missingTextureInputs()
        for hasAlbedo in [false, true] {
            let label = hasAlbedo ? "present albedo" : "missing albedo"
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            let (sceneJSON, assets) = try autosizeScene(original: original, present: hasAlbedo)
            let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: [:])
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 64, height: 32), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            XCTAssertTrue(driver.didLoad, label)
            let layer = RecordingLayer()
            layer.device = device
            layer.pixelFormat = .rgba8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.drawableSize = CGSize(width: 64, height: 32)
            layer.framebufferOnly = false
            try await present(driver, layer: layer, label: label)
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(label): \(renderer.skipped)")
            let frame = try XCTUnwrap(renderer.frames.first)
            let drawn = Set(renderer.lastFrameDraws.map(\.operation))
            let size = hasAlbedo ? [48, 24] : [6, 6]
            let layerDraws = frame.draws.compactMap { operation, value -> WPEParitySceneDraw? in
                guard case let .scene(draw) = value, draw.objectID == "1", drawn.contains(operation) else { return nil }
                return draw
            }
            let albedo = try XCTUnwrap(layerDraws.first { $0.effectID == nil }, label)
            XCTAssertTrue(layerDraws.contains { $0.effectID != nil }, "\(label): the effect must draw")
            let composite = try XCTUnwrap(renderer.renderTarget(albedo.target), "\(label): \(albedo.target)")
            XCTAssertEqual([composite.width, composite.height], size, "\(label) composite \(albedo.target)")
            let raw = try readBack(renderer.backbuffer, device: renderer.backbuffer.device)
            let width = renderer.backbuffer.width
            let clear = Array(raw[0 ..< 3]).map(Int.init)
            let centre = (16 * width + 32) * 4
            var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
            for y in 0 ..< renderer.backbuffer.height {
                for x in 0 ..< width {
                    let at = (y * width + x) * 4
                    guard zip(raw[at ..< at + 3], clear).contains(where: { abs(Int($0) - $1) > 8 }) else { continue }
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            // Quad centred at (32, 16): 6 units cover pixels 29–34 × 13–18; 48×24 cover 8–55 × 4–27.
            XCTAssertEqual([minX, minY, maxX, maxY], hasAlbedo ? [8, 4, 55, 27] : [29, 13, 34, 18],
                           "\(label) drawn region; corner \(clear), centre \(Array(raw[centre ..< centre + 4]))")
        }
    }

    /// One autosize image layer of authored size 48×24 with a passthrough effect; `present` writes a 48×24 red albedo.
    private func autosizeScene(original: WPEParityProgramAssets, present: Bool) throws -> (Data, WPEParityProgramAssets) {
        let albedo: [String: Any] = ["shader": "passthrough", "textures": ["autosize-product"],
                                     "combos": ["TRANSFORM": 1], "blending": "normal"]
        var files: [String: Data] = try [
            "models/autosize-product.json": JSONSerialization.data(withJSONObject: [
                "autosize": true, "material": "materials/autosize-product.json",
            ]),
            "materials/autosize-product.json": JSONSerialization.data(withJSONObject: ["passes": [albedo]]),
            "materials/autosize-pass.json": JSONSerialization.data(withJSONObject: [
                "passes": [["shader": "passthrough", "combos": ["TRANSFORM": 1], "blending": "normal"]],
            ]),
            "effects/autosize-product.json": JSONSerialization.data(withJSONObject: [
                "passes": [["material": "materials/autosize-pass.json"]],
            ]),
        ]
        if present {
            var tex = Data("TEXV0005\0TEXI0001\0".utf8)
            func word(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { tex.append(contentsOf: $0) }
            }
            for value: UInt32 in [UInt32(WPETexFormat.rgba8888.rawValue), 0, 48, 24, 48, 24, 0] {
                word(value)
            }
            tex.append(contentsOf: "TEXB0003\0".utf8)
            for value: UInt32 in [1, .max, 1, 48, 24, 0, 48 * 24 * 4, 48 * 24 * 4] {
                word(value)
            }
            for _ in 0 ..< 48 * 24 {
                tex.append(contentsOf: [255, 0, 0, 255])
            }
            files["materials/autosize-product.tex"] = tex
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 32], "clearcolor": "0 0 1",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [
                ["id": 1, "name": "autosize", "image": "models/autosize-product.json",
                 "origin": "32 16 0", "size": "48 24", "alpha": 1,
                 "effects": [["id": 4, "file": "effects/autosize-product.json"]]],
            ],
        ]
        return try (JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), assets)
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
            return draw.objectID == "2" && draw.effectID != nil && draw.shader == "effects/blend"
        })
        return (imported.key, direct.key)
    }

    func missingTextureInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, original) = try sceneInputs()
            for (path, expected) in [
                ("shaders/passthrough.vert", "ff6cd2bb166ce427c73058f3f77f338442d83fab9883f302e31bbffd81fa5317"),
                ("shaders/passthrough.frag", "db8586701eeda50c731af880411451be673180049ede8def28932d7180052109"),
                ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
                ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
                ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
                ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
                ("effects/blend/shaders/effects/blend.vert", "3ca25845f8f30cfcc3bff5bbe215185fbce79076d4185a065ee30b35791a6540"),
                ("effects/blend/shaders/effects/blend.frag", "f7692b475727645060fba653173aba1ba13a0be5068d163889657102579e86b0"),
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
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityMissingTextureProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled compiler unavailable: \(error)"]
            ))
        }
    }

    /// Object 1 imports `texture` as its layer image; object 2's stock blend effect samples it as its slot-1 blend texture.
    private func missingTextureScene(original: WPEParityProgramAssets, texture: String,
                                     files extra: [String: Data]) throws -> (Data, WPEParityProgramAssets) {
        let pass: [String: Any] = ["shader": "passthrough", "textures": [texture],
                                   "combos": ["TRANSFORM": 1], "blending": "normal"]
        // BLENDMODE 0 is normal blending, so the opaque blend texture replaces the black layer input.
        let blend: [String: Any] = ["shader": "effects/blend", "textures": [NSNull(), texture],
                                    "combos": ["BLENDMODE": 0], "blending": "normal"]
        var files: [String: Data] = try extra.merging([
            "models/missing-product.json": JSONSerialization.data(withJSONObject: ["material": "materials/missing-product.json"]),
            "materials/missing-product.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "materials/missing-product-blend.json": JSONSerialization.data(withJSONObject: ["passes": [blend]]),
            "effects/missing-product.json": JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/missing-product-blend.json"]]]),
        ]) { $1 }
        for stage in ["vert", "frag"] {
            files["shaders/effects/blend.\(stage)"] = try XCTUnwrap(original.data("effects/blend/shaders/effects/blend.\(stage)"))
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
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
