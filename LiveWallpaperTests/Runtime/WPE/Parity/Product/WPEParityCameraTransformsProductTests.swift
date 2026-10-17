#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Ortho scale is general zoom × root zoom without a camera object (14017fa70.c:226-229); a visible camera
    /// object keeps its own zoom and ignores the root value (1401891a0.c:85-114).
    func testScriptedRootZoomScalesTheOrthoProjectionUntilACameraObjectIsVisible() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files = try [
            "models/zoom-witness.json": ["material": "materials/zoom-witness.json"] as [String: Any],
            "materials/zoom-witness.json": ["passes": [["shader": "genericimage2", "textures": ["zoom-red"],
                                                        "blending": "normal", "cullmode": "nocull"]]],
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        files["materials/zoom-red.tex"] = cameraWitnessTexture([255, 0, 0, 255])
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let zoomScript = """
        export function applyUserProperties(changed) {
          if (changed.big != undefined) {
            const transforms = thisScene.getCameraTransforms();
            transforms.zoom = changed.big ? 2 : 1;
            thisScene.setCameraTransforms(transforms);
          }
        }
        """
        func document(cameraVisible: Bool) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 256, "height": 128], "clearenabled": true,
                            "clearcolor": "0 0 0", "bloom": false, "zoom": ["value": 1.5, "script": zoomScript]],
                "objects": [
                    ["id": 1, "image": "models/zoom-witness.json", "origin": "128 64 0", "size": "48 96"],
                    ["id": 2, "camera": "default", "origin": "0 0 0", "zoom": 1, "visible": cameraVisible],
                ],
            ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        func big(_ value: Bool) -> String {
            #"{"big":{"type":"bool","value":\#(value)}}"#
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let initial = try document(cameraVisible: false)
        try await driver.load(document: initial, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 256, height: 128), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "zoom-cache")),
                              scriptHost: .init(userPropertiesJSON: big(true)))
        let renderer = try XCTUnwrap(driver.renderer)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 256, height: 128)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        func frame(_ index: Int, zoom: Float, scale: Float) async throws {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(index) * 0.25,
                                                                     pointer: SIMD2(repeating: 0.5)))
            await command.completed()
            try await settle(driver, label: "zoom frame \(index)")
            XCTAssertNil(command.error)
            let current = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(current === renderer)
            XCTAssertTrue(current.skipped.isEmpty, "\(current.skipped)")
            XCTAssertEqual(current.pathCamera.zoom, zoom, accuracy: 0.000001, "frame \(index)")
            let entry = try XCTUnwrap(current.lastFrameDraws.first {
                $0.draw.constants[.vertex]?["g_ModelViewProjectionMatrix"] != nil
            })
            let mvp = try XCTUnwrap(current.uniforms(entry.operation)).matrices.modelViewProjection
            XCTAssertEqual(mvp.columns.0.x, scale, accuracy: 0.000001, "frame \(index)")
        }
        try await frame(0, zoom: 3, scale: 0.0234375)
        try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: initial)),
                                         changedJSON: big(false), mergedJSON: big(false))
        try await frame(1, zoom: 1.5, scale: 0.01171875)
        let withCamera = try document(cameraVisible: true)
        try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: withCamera)),
                                         changedJSON: big(true), mergedJSON: big(true))
        try await frame(2, zoom: 1.5, scale: 0.01171875)
        XCTAssertEqual(renderer.state.scriptField("cameraTransforms.zoom", of: ""), .vector(SIMD4(2, 0, 0, 0)))
    }

    /// A user value on a camera object's zoom and a root layer's parallaxDepth reaches the next frame's V/P
    /// without reloading; WPE rewrites both fields with no hook (1401f3460.c:71-103, 1401e0530.c:195-208).
    func testUserCameraObjectZoomAndRootParallaxDepthApplyWithoutReload() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        var files = try [
            "models/zoom-witness.json": ["material": "materials/zoom-witness.json"] as [String: Any],
            "materials/zoom-witness.json": ["passes": [["shader": "genericimage2", "textures": ["zoom-red"],
                                                        "blending": "normal", "cullmode": "nocull"]]],
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        files["materials/zoom-red.tex"] = cameraWitnessTexture([255, 0, 0, 255])
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        func document(lens: Double, depth: String) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 256, "height": 128], "clearenabled": true,
                            "clearcolor": "0 0 0", "bloom": false, "cameraparallax": true,
                            "cameraparallaxamount": 1],
                "objects": [
                    ["id": 1, "image": "models/zoom-witness.json", "origin": "64 32 0", "size": "48 96",
                     "parallaxDepth": ["user": "depth", "value": "1 1"]],
                    ["id": 2, "camera": "default", "origin": "0 0 0", "zoom": ["user": "lens", "value": 1]],
                ],
            ]), userValues: ["lens": .number(lens), "depth": .string(depth)],
            makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document(lens: 1, depth: "1 1"), assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 256, height: 128), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "lens-cache")))
        let renderer = try XCTUnwrap(driver.renderer)
        let generation = driver.loadGeneration
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 256, height: 128)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        func frame(_ index: Int, scale: Float, pushed: Bool) async throws {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(index) * 0.25,
                                                                     pointer: SIMD2(repeating: 0.5)))
            await command.completed()
            try await settle(driver, label: "lens frame \(index)")
            XCTAssertNil(command.error)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            let entry = try XCTUnwrap(renderer.lastFrameDraws.first {
                $0.draw.constants[.vertex]?["g_ModelViewProjectionMatrix"] != nil
            })
            let matrices = try XCTUnwrap(renderer.uniforms(entry.operation)).matrices
            XCTAssertEqual(matrices.modelViewProjection.columns.0.x, scale, accuracy: 0.000001, "frame \(index)")
            XCTAssertEqual(matrices.view != renderer.pathCamera.view, pushed, "frame \(index)")
        }
        try await frame(0, scale: 0.0078125, pushed: true)
        let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                          oldValues: ["lens": .number(1), "depth": .string("1 1")],
                                          newValues: ["lens": .number(1.5), "depth": .string("0 0")])
        XCTAssertTrue(try driver.prepareUserProperties(patch, document: document(lens: 1.5, depth: "0 0")))
        XCTAssertTrue(driver.commitUserProperties(patch))
        XCTAssertTrue(driver.renderer === renderer, "the renderer is not rebuilt")
        XCTAssertEqual(driver.loadGeneration, generation, "the scene did not reload")
        try await frame(1, scale: 0.01171875, pushed: false)
    }
}
#endif
