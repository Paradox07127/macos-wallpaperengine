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
    /// 183a70 publishes projection before the script tick; object/queue selection replaces only effective FOV.
    func testSceneProjectionUsesStrictLiveFieldsBeforeTickAndPreservesThemAcrossCameraSelectionAndResize() async throws {
        let original: WPEParityProgramAssets
        do { original = try sceneInputs().1 } catch { throw TestScratch.requiredInputError(error, failure: NSError(domain: "Projection.RequiredOriginal", code: 1)) }
        for (path, expected) in [
            ("shaders/genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("shaders/genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
        ] {
            XCTAssertEqual(try SHA256.hash(data: XCTUnwrap(original.data(path))).map { String(format: "%02x", $0) }.joined(), expected)
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                    "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        guard keys.allSatisfy({ ProcessInfo.processInfo.environment[$0] == nil }) else {
            throw NSError(domain: "Projection.ToolOverride", code: 1)
        }
        let compiler = try makeCompiler()
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let hashes = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath()
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil)
            return try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        var files = try [
            "models/projection-witness.json": ["material": "materials/projection-witness.json"] as [String: Any],
            "materials/projection-witness.json": ["passes": [["shader": "genericimage2", "textures": ["projection-red"],
                                                              "blending": "normal", "cullmode": "nocull"]]],
            "cameras/projection.json": ["paths": [["options": ["fps": 4, "length": 100, "mode": "loop"],
                                                   "fov": [["frame": 0, "value": 90], ["frame": 100, "value": 90]]]]],
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let red = cameraWitnessTexture([255, 0, 0, 255])
        XCTAssertEqual(SHA256.hash(data: red).map { String(format: "%02x", $0) }.joined(),
                       "9e441ee114603c6004c2f599e900ab89f93c3821dcbb227a58018cf38b9a4aea")
        files["materials/projection-red.tex"] = red
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        func document(fov: Any = false, near: Any = false, far: Any = "10000", scripted: Bool = true,
                      activeObject: Bool = false, activeQueue: Bool = false, visible: Bool = true) throws -> WPESceneDocument {
            var general: [String: Any] = ["orthogonalprojection": NSNull(), "fov": fov, "nearz": near, "farz": far,
                                          "clearenabled": true, "clearcolor": "0 0 0", "bloom": false]
            if scripted {
                general["fov"] = ["value": fov, "script": """
                shared.projectionLoads = (shared.projectionLoads || 0) + 1;
                export function update(value) {
                  if (shared.projectionLoads !== 1) throw new Error('projection module rerun');
                  if (!engine.userProperties.drive) return value;
                  thisScene.nearz = engine.userProperties.near;
                  thisScene.farz = engine.userProperties.far;
                  return engine.userProperties.fov;
                }
                """]
            }
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": general,
                "objects": [
                    ["id": 1, "image": "models/projection-witness.json", "origin": "2 0 -8", "size": "2 2", "visible": visible],
                    ["id": 2, "camera": "projection object", "fov": 60, "visible": activeObject],
                    ["id": 3, "camera": "projection queue", "fov": 60, "path": "cameras/projection.json",
                     "queuemode": "sequential", "visible": activeQueue],
                ],
            ]), userValues: [:])
        }
        func host(fov: Double = 90, near: Double = 1, far: Double = 9, drive: Bool = true) throws -> String {
            let values: [String: Any] = ["drive": ["type": "bool", "value": drive], "fov": ["type": "slider", "value": fov],
                                         "near": ["type": "slider", "value": near], "far": ["type": "slider", "value": far]]
            return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let initial = try document()
        try await driver.load(document: initial, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 64, height: 64), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "projection-cache")),
                              scriptHost: .init(userPropertiesJSON: host(drive: false)))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let renderer = try XCTUnwrap(driver.renderer)
        let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: initial))
        let backbuffer = renderer.backbuffer
        let targets = renderer.targets.mapValues(ObjectIdentifier.init)
        let pipelines = renderer.pipelineCreations
        func frame(_ index: Int, fov: Float, focal: Float, near: Float, far: Float, reused: Bool = true) async throws {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(index) * 0.25,
                                                                     pointer: SIMD2(repeating: 0.5)))
            await command.completed()
            try await settle(driver, label: "projection frame \(index)")
            XCTAssertNil(command.error)
            let current = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(current.skipped.isEmpty, "\(current.skipped)")
            XCTAssertEqual(current.pathCamera.scenePerspective, .init(fov: fov, near: near, far: far))
            let entry = try XCTUnwrap(current.lastFrameDraws.first { $0.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] != nil })
            let mvp = try XCTUnwrap(current.uniforms(entry.operation)).matrices.modelViewProjection
            let aspect = Float(current.backbuffer.width) / Float(current.backbuffer.height)
            let range = near / (far - near)
            XCTAssertEqual(mvp.columns.3.x, focal / aspect * 2, accuracy: 0.000001)
            XCTAssertEqual(mvp.columns.3.z, range * -8 + range * far, accuracy: 0.000001)
            XCTAssertEqual(mvp.columns.3.w, 8, accuracy: 0.000001)
            guard case let .matrix(encoded)? = entry.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("Original shader must receive the published projection")
            }
            XCTAssertEqual(encoded.columns[0][3], mvp.columns.3.x)
            XCTAssertEqual(encoded.columns[2][3], mvp.columns.3.z)
            if fov < 179 {
                let pixels = try readBack(current.backbuffer, device: device)
                let x = Int((1 + focal / aspect / 4) * Float(current.backbuffer.width) / 2)
                let offset = (current.backbuffer.height / 2 * current.backbuffer.width + x) * 4
                XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - 255), 1)
                XCTAssertLessThanOrEqual(pixels[offset + 1], 1)
                XCTAssertLessThanOrEqual(pixels[offset + 2], 1)
            }
            if reused {
                XCTAssertTrue(current === renderer)
                XCTAssertTrue(current.backbuffer === backbuffer)
                XCTAssertEqual(current.targets.mapValues(ObjectIdentifier.init), targets)
                XCTAssertEqual(current.pipelineCreations, pipelines)
            }
        }
        // Fixed focal values are qualified independently against original 09a360 instructions.
        let focal50 = Float(bitPattern: 0x4009_3F99)
        let focal60 = Float(bitPattern: 0x3FDD_B3D7)
        let focal90 = Float(bitPattern: 0x3F7F_FFFF)
        let focalUpper = Float(bitPattern: 0x3A64_C406)
        let steps: [(Double, Double, Double, Float, Float, Float, Float)] = [
            (90, 1, 9, 50, focal50, 0.1, 10000),
            (60, 0.5, 100, 90, focal90, 1, 9),
            (250, 1, 9, 60, focal60, 0.5, 100),
        ]
        for (index, step) in steps.enumerated() {
            let json = try host(fov: step.0, near: step.1, far: step.2)
            try renderer.applyUserProperties(unchanged, changedJSON: json, mergedJSON: json)
            try await frame(index, fov: step.3, focal: step.4, near: step.5, far: step.6)
        }
        let paused = try host(drive: false)
        try renderer.applyUserProperties(unchanged, changedJSON: paused, mergedJSON: paused)
        try await frame(3, fov: 250, focal: focalUpper, near: 1, far: 9)
        XCTAssertEqual(renderer.instance.state.scriptField("fov", of: ""), .vector(SIMD4(250, 0, 0, 0)), "Clamp must not change public raw FOV")
        let object = try document(fov: 90, near: 1, far: 9, activeObject: true)
        try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: object)))
        try await frame(4, fov: 60, focal: focal60, near: 1, far: 9)
        XCTAssertEqual(renderer.instance.state.scriptField("fov", of: ""), .vector(SIMD4(90, 0, 0, 0)))
        let queue = try document(fov: 90, near: 1, far: 9, activeQueue: true)
        try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: object, to: queue)))
        try await frame(5, fov: 90, focal: focal90, near: 1, far: 9)
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 128, height: 64))
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        layer.drawableSize = CGSize(width: 128, height: 64)
        try await frame(6, fov: 90, focal: focal90, near: 1, far: 9, reused: false)
        let current = try XCTUnwrap(driver.renderer)
        let invalid = try document(fov: "50", near: false, far: false)
        for name in ["fov", "nearz", "farz"] {
            XCTAssertNil(WPEParityScriptProperty.sceneFloatValue(fromJSON: invalid.resolvedGeneralJSON[name]))
        }
        let generation = current.instance.state.scriptFieldsGeneration
        try current.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: queue, to: invalid)))
        XCTAssertEqual(current.instance.state.scriptFieldsGeneration, generation)
        try await frame(7, fov: 90, focal: focal90, near: 1, far: 9, reused: false)
        let cold = try WPEParitySceneDriver(device: device)
        defer { cold.cleanup() }
        let coldDocument = try document(scripted: false)
        try await cold.load(document: coldDocument, assets: assets, settings: .init(bloom: false),
                            drawableSize: CGSize(width: 64, height: 64), pixelFormat: .bgra8Unorm_srgb,
                            compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "projection-cold-cache")))
        let coldRenderer = try XCTUnwrap(cold.renderer)
        XCTAssertNil(coldRenderer.instance.script)
        for (name, value): (String, Float) in [("fov", 50), ("nearz", 0.1), ("farz", 10000)] {
            XCTAssertEqual(coldRenderer.instance.state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let accepted = try document(fov: 90, near: 1, far: 9, scripted: false)
        try coldRenderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: coldDocument, to: accepted)))
        for (name, value): (String, Float) in [("fov", 90), ("nearz", 1), ("farz", 9)] {
            XCTAssertEqual(coldRenderer.instance.state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        layer.drawableSize = CGSize(width: 64, height: 64)
        let command = try XCTUnwrap(cold.renderAndPresentFrame(layer: layer, timestamp: 100,
                                                               pointer: SIMD2(repeating: 0.5)))
        await command.completed()
        try await settle(cold, label: "projection without VM")
        XCTAssertNil(command.error)
        XCTAssertTrue(coldRenderer.skipped.isEmpty, "\(coldRenderer.skipped)")
        XCTAssertEqual(coldRenderer.pathCamera.scenePerspective, .init(fov: 90, near: 1, far: 9))
        let entry = try XCTUnwrap(coldRenderer.lastFrameDraws.first { $0.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] != nil })
        let matrix = try XCTUnwrap(coldRenderer.uniforms(entry.operation)).matrices.modelViewProjection
        XCTAssertEqual(matrix.columns.3.x, focal90 * 2, accuracy: 0.000001)
        XCTAssertEqual(matrix.columns.3.z, 0.125, accuracy: 0.000001)
        let pixels = try readBack(coldRenderer.backbuffer, device: device)
        let offset = (32 * 64 + 40) * 4
        XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - 255), 1)
        XCTAssertLessThanOrEqual(pixels[offset + 1], 1)
        XCTAssertLessThanOrEqual(pixels[offset + 2], 1)

        let overrideDocument = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": [
                "orthogonalprojection": ["width": 64, "height": 64],
                "perspectiveoverridefov": ["value": false, "script": """
                export function update(value) { return engine.userProperties.fov; }
                """],
                "clearenabled": true, "clearcolor": "0 0 0", "bloom": false,
            ],
            "objects": [["id": 1, "image": "models/projection-witness.json", "origin": "32 32 0",
                         "size": "16 16", "perspective": true]],
        ]), userValues: [:])
        try await cold.load(document: overrideDocument, assets: assets, settings: .init(bloom: false),
                            drawableSize: CGSize(width: 64, height: 64), pixelFormat: .bgra8Unorm_srgb,
                            compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "projection-override-cache")),
                            scriptHost: .init(userPropertiesJSON: host(fov: 60)))
        let overrideRenderer = try XCTUnwrap(cold.renderer)
        XCTAssertEqual(overrideRenderer.pathCamera.perspectiveFOV, 95, "Bool cannot replace the native Float seed")
        XCTAssertEqual(overrideRenderer.instance.state.scriptField("perspectiveoverridefov", of: ""), .vector(SIMD4(95, 0, 0, 0)))
        var distances: [Float] = []
        for (index, expectedFOV): (Int, Float) in [(0, 95), (1, 60)] {
            let command = try XCTUnwrap(cold.renderAndPresentFrame(layer: layer, timestamp: 200 + Double(index) * 0.25,
                                                                   pointer: SIMD2(repeating: 0.5)))
            await command.completed()
            try await settle(cold, label: "perspective override frame \(index)")
            XCTAssertNil(command.error)
            XCTAssertTrue(cold.renderer === overrideRenderer)
            XCTAssertTrue(overrideRenderer.skipped.isEmpty, "\(overrideRenderer.skipped)")
            XCTAssertEqual(overrideRenderer.pathCamera.perspectiveFOV, expectedFOV)
            XCTAssertEqual(overrideRenderer.instance.state.scriptField("perspectiveoverridefov", of: ""), .vector(SIMD4(60, 0, 0, 0)))
            let draw = try XCTUnwrap(overrideRenderer.lastFrameDraws.first {
                $0.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] != nil
            })
            let mvp = try XCTUnwrap(overrideRenderer.uniforms(draw.operation)).matrices.modelViewProjection
            guard case let .matrix(encoded)? = draw.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("Original shader must receive the selected override camera")
            }
            XCTAssertEqual(encoded.columns[3][3], mvp.columns.3.w)
            distances.append(mvp.columns.3.w)
            let output = try readBack(overrideRenderer.backbuffer, device: device)
            let centre = (32 * 64 + 32) * 4
            XCTAssertLessThanOrEqual(abs(Int(output[centre]) - 255), 1)
            XCTAssertLessThanOrEqual(output[centre + 1], 1)
            XCTAssertLessThanOrEqual(output[centre + 2], 1)
        }
        XCTAssertNotEqual(distances[0].bitPattern, distances[1].bitPattern, "Tick writes affect the following selected camera")
        var unsupportedCamera = overrideRenderer.pathCamera
        unsupportedCamera.perspectiveFOV = .infinity
        XCTAssertThrowsError(try overrideRenderer.cursorQuad("1", camera: unsupportedCamera)) {
            XCTAssertEqual($0 as? WPEParityCamera.PerspectiveMathError,
                           .unsupportedFieldOfView(inputBits: Float.infinity.bitPattern))
        }
    }
}
#endif
