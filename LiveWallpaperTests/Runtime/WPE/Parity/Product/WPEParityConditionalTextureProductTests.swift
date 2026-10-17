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
    /// Fixed TEXB4 bytes reach both the imported layer-image and direct effect-asset binding, through the
    /// original passthrough and blend shaders and real Driver prepare/commit/present. No script or JSON binding owns the key.
    @MainActor @objc func testConditionalTextureInitialSelectionAndLivePropertyReplaceBothRealConsumers() async throws {
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 1, "Required isolated native-size product gate")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (original, compiler) = try conditionalTextureInputs()
        let (sceneJSON, assets) = try conditionalTextureScene(original: original)
        let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: [:])
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 64, height: 16), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch),
                              scriptHost: .init(userPropertiesJSON: #"{"enabled":{"type":"bool","value":true}}"#))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        let bindings = try XCTUnwrap(driver.userPropertyBindings["enabled"], "Actual texture-only property binding")
        XCTAssertFalse(bindings.isEmpty)
        XCTAssertTrue(bindings.allSatisfy { $0.action == .incremental })
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertNil(renderer.script, "A TEX-only dependency must work without any SceneScript binding")
        let generation = driver.loadGeneration
        let rendererIdentity = ObjectIdentifier(renderer)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.drawableSize = CGSize(width: 64, height: 16)
        layer.framebufferOnly = false
        try await present(driver, layer: layer, label: "conditional initial true")
        let initial = try conditionalTextureReading(driver, layer: layer, rgb: [0, 255, 0])
        let pipelines = renderer.pipelineCreations

        var enabled = true
        var previousTexture = initial
        for next in [false, true, false] {
            let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                              oldValues: ["enabled": .bool(enabled)], newValues: ["enabled": .bool(next)])
            let updated = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: ["enabled": .bool(next)])
            _ = try XCTUnwrap(driver.canApplyUserPropertiesLive(patch) ? true : nil, "TEX-only key needs the product live gate")
            _ = try XCTUnwrap(driver.prepareUserProperties(patch, document: updated) ? true : nil, "Real product prepare")
            _ = try XCTUnwrap(driver.commitUserProperties(patch) ? true : nil, "Real product commit")
            try await present(driver, layer: layer, label: "conditional enabled=\(next)")
            let texture = try conditionalTextureReading(driver, layer: layer, rgb: next ? [0, 255, 0] : [255, 0, 0])
            XCTAssertNotEqual(texture, previousTexture, "Changed observations replace the actual sampled GPU resource")
            XCTAssertEqual(driver.loadGeneration, generation, "No scene reload")
            XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), rendererIdentity, "No renderer rebuild")
            XCTAssertEqual(renderer.pipelineCreations, pipelines, "Property-only texture replacement compiles no pipeline")
            try await present(driver, layer: layer, label: "conditional unchanged \(next)")
            XCTAssertEqual(try conditionalTextureReading(driver, layer: layer, rgb: next ? [0, 255, 0] : [255, 0, 0]), texture,
                           "Unchanged frames must keep the immutable texture")
            previousTexture = texture
            enabled = next
        }
        // The latest committed value is false, different from the original true snapshot.
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 128, height: 32))
        let resized = await driver.replan()
        _ = try XCTUnwrap(resized ? true : nil, "Real product resize")
        layer.drawableSize = CGSize(width: 128, height: 32)
        try await present(driver, layer: layer, label: "conditional false after resize")
        _ = try conditionalTextureReading(driver, layer: layer, rgb: [255, 0, 0])
    }

    /// Returns identity values only; the test does not retain old GPU textures across replacement.
    private func conditionalTextureReading(_ driver: WPEParitySceneDriver, layer: RecordingLayer, rgb: [Int]) throws -> ObjectIdentifier {
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(renderer.fallbackTextures)")
        let frame = try XCTUnwrap(renderer.frames.first)
        let imported = try XCTUnwrap(frame.draws.first { _, value in
            guard case let .scene(draw) = value else { return false }
            return draw.objectID == "1" && draw.effectID == nil && draw.shader == "passthrough"
        })
        let direct = try XCTUnwrap(frame.draws.first { _, value in
            guard case let .scene(draw) = value else { return false }
            return draw.objectID == "2" && draw.effectID != nil && draw.shader == "effects/blend"
        })
        guard case let .scene(description) = imported.value else { throw NSError(domain: "ConditionalTexture.Draw", code: 1) }
        XCTAssertTrue(description.reads.contains { id in frame.resources.contains { $0.id == id && $0.lifetime == .imported } })
        let importedDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == imported.key }?.draw)
        let directDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == direct.key }?.draw)
        let importedTexture = try XCTUnwrap(importedDraw.textures["g_Texture0"])
        let directTexture = try XCTUnwrap(directDraw.textures["g_Texture1"])
        XCTAssertTrue(importedTexture === directTexture, "One asset cache owner feeds both binding kinds")
        XCTAssertEqual(importedTexture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual([importedTexture.width, importedTexture.height], [2, 2])
        let raw = try readBack(renderer.backbuffer, device: renderer.backbuffer.device)
        let drawable = try XCTUnwrap(layer.lastTexture)
        let presented = try readBack(drawable, device: drawable.device)
        for (bytes, width, height) in [(raw, renderer.backbuffer.width, renderer.backbuffer.height),
                                       (presented, drawable.width, drawable.height)] {
            for x in [width / 4, width * 3 / 4] {
                let at = (height / 2 * width + x) * 4
                for lane in 0 ..< 3 {
                    XCTAssertLessThanOrEqual(abs(Int(bytes[at + lane]) - rgb[lane]), 1, "Actual draw/present pixel at \(x)")
                }
                XCTAssertEqual(bytes[at + 3], 255)
            }
        }
        return ObjectIdentifier(importedTexture)
    }

    private func conditionalTextureInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
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
                workDirectory: scratch.appending(path: "conditional-bundled-shaderc")
            )
            return (original, compiler)
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityConditionalTextureProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled compiler unavailable: \(error)"]
            ))
        }
    }

    private func conditionalTextureScene(original: WPEParityProgramAssets) throws -> (Data, WPEParityProgramAssets) {
        // Independently packed TEXB4: raw red2x2 base, group71/id9000/flags2 green replacement if bool enabled.
        let tex = try XCTUnwrap(Data(base64Encoded: "VEVYVjAwMDUAVEVYSTAwMDEAAAAAAAMAAAACAAAAAgAAAAIAAAACAAAAAAAAAFRFWEIwMDA0AAEAAAD/////AQAAAEcAAAAoIwAAAgAAAHsiY29uZGl0aW9uIjoiZW5hYmxlZCJ9AAEAAAACAAAAAgAAAAAAAAAQAAAAEAAAAP8AAP//AAD//wAA//8AAP8BAAAAAQAAABMAAAAoIwAAAAAAAAAAAAACAAAAAgAAAP////8QAAAAAP8A/wD/AP8A/wD/AP8A/w=="))
        XCTAssertEqual(SHA256.hash(data: tex).map { String(format: "%02x", $0) }.joined(),
                       "49644469885c35751abd70e9d616f787a7848d863b77440a629ea00565b8c76f")
        let pass: [String: Any] = ["shader": "passthrough", "textures": ["conditional-product"],
                                   "combos": ["TRANSFORM": 1], "blending": "normal"]
        // BLENDMODE 0 is normal blending, so the opaque blend texture replaces the black layer input.
        let blend: [String: Any] = ["shader": "effects/blend", "textures": [NSNull(), "conditional-product"],
                                    "combos": ["BLENDMODE": 0], "blending": "normal"]
        var files: [String: Data] = try [
            "materials/conditional-product.tex": tex,
            "models/conditional-product.json": JSONSerialization.data(withJSONObject: ["material": "materials/conditional-product.json"]),
            "materials/conditional-product.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "materials/conditional-product-blend.json": JSONSerialization.data(withJSONObject: ["passes": [blend]]),
            "effects/conditional-product.json": JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/conditional-product-blend.json"]]]),
        ]
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
                ["id": 1, "name": "conditional-imported", "image": "models/conditional-product.json",
                 "origin": "16 8 0", "size": "32 16", "alpha": 1],
                ["id": 2, "name": "conditional-direct", "image": "models/util/solidlayer.json",
                 "origin": "48 8 0", "size": "32 16", "color": "0 0 0", "alpha": 1,
                 "effects": [["id": 4, "file": "effects/conditional-product.json"]]],
            ],
        ]
        return try (JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), assets)
    }
}
#endif
