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
    /// 1891a0 consumes all four shake fields before tick; 18aac0 still reads parallax after tick.
    func testCameraShakeKeepsThePreTickPoseAndConsumesStrictLiveFieldsInOriginalDraws() async throws {
        let original: WPEParityProgramAssets
        do { original = try sceneInputs().1 } catch { throw TestScratch.requiredInputError(error, failure: NSError(domain: "Shake.RequiredOriginal", code: 1)) }
        for (path, expected) in [
            ("shaders/genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("shaders/genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
        ] {
            XCTAssertEqual(try SHA256.hash(data: XCTUnwrap(original.data(path))).map { String(format: "%02x", $0) }.joined(), expected)
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                    "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        guard keys.allSatisfy({ ProcessInfo.processInfo.environment[$0] == nil }) else {
            throw NSError(domain: "Shake.ToolOverride", code: 1)
        }
        let compiler = try makeCompiler()
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let toolHashes = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath()
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil)
            return try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + toolHashes.joined(separator: " "))
        var files = try [
            "models/shake-witness.json": ["material": "materials/shake-witness.json"] as [String: Any],
            "materials/shake-witness.json": ["passes": [["shader": "genericimage2", "textures": ["shake-red"],
                                                         "blending": "normal", "cullmode": "nocull"]]],
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let red = cameraWitnessTexture([255, 0, 0, 255])
        XCTAssertEqual(SHA256.hash(data: red).map { String(format: "%02x", $0) }.joined(),
                       "9e441ee114603c6004c2f599e900ab89f93c3821dcbb227a58018cf38b9a4aea")
        files["materials/shake-red.tex"] = red
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        func document(enabled: Any = false, speed: Any = 0, amplitude: Any = 0.5, roughness: Any = 1,
                      scripts: Bool = true, witness: Bool = true, visible: Bool = true) throws -> WPESceneDocument {
            var general: [String: Any] = ["orthogonalprojection": ["width": 16, "height": 16],
                                          "clearenabled": true, "clearcolor": "0 0 0", "bloom": false,
                                          "camerashake": enabled, "camerashakespeed": speed,
                                          "camerashakeamplitude": amplitude, "camerashakeroughness": roughness,
                                          "cameraparallax": false, "cameraparallaxamount": 0.25,
                                          "cameraparallaxdelay": 0, "cameraparallaxmouseinfluence": 0]
            if scripts {
                general["camerashake"] = ["value": enabled, "script": """
                shared.shakeLoads = (shared.shakeLoads || 0) + 1;
                export function update(value) {
                  if (shared.shakeLoads !== 1) throw new Error('shake module rerun');
                  if (!engine.userProperties.drive) return value;
                  thisScene.camerashakespeed = engine.userProperties.speed;
                  thisScene.camerashakeamplitude = engine.userProperties.amplitude;
                  thisScene.camerashakeroughness = engine.userProperties.roughness;
                  thisScene.cameraparallax = engine.userProperties.parallax;
                  return engine.userProperties.enabled;
                }
                """]
            }
            let object: [String: Any] = witness
                ? ["id": 1, "image": "models/shake-witness.json", "origin": "8 8 0", "size": "2 2",
                   "parallaxDepth": "1 0", "visible": visible]
                : ["id": 1, "camera": "activity witness", "origin": "0 0 0"]
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": general, "objects": [object],
            ]), userValues: [:])
        }
        func host(drive: Bool = true, enabled: Bool = true, amplitude: Double = 25, speed: Double = 0,
                  roughness: Double = 1, parallax: Bool = false) throws -> String {
            let values: [String: Any] = ["drive": ["type": "bool", "value": drive], "enabled": ["type": "bool", "value": enabled],
                                         "amplitude": ["type": "slider", "value": amplitude], "speed": ["type": "slider", "value": speed],
                                         "roughness": ["type": "slider", "value": roughness], "parallax": ["type": "bool", "value": parallax]]
            return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let initial = try document()
        try await driver.load(document: initial, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "shake-cache")),
                              scriptHost: .init(userPropertiesJSON: host(drive: false)))
        let renderer = try XCTUnwrap(driver.renderer)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: initial))
        let backbuffer = renderer.backbuffer
        let targets = renderer.targets.mapValues(ObjectIdentifier.init)
        let pipelines = renderer.pipelineCreations
        func frame(_ index: Int, eye: SIMD2<Float>, point: SIMD2<Float>) async throws {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(index) * 0.25,
                                                                     pointer: SIMD2(repeating: 0.5)))
            await command.completed()
            try await settle(driver, label: "shake frame \(index)")
            XCTAssertNil(command.error)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            XCTAssertEqual(renderer.pathCamera.eye.x, eye.x, accuracy: 0.00001)
            XCTAssertEqual(renderer.pathCamera.eye.y, eye.y, accuracy: 0.00001)
            let entry = try XCTUnwrap(renderer.lastFrameDraws.first { $0.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] != nil })
            let mvp = try XCTUnwrap(renderer.uniforms(entry.operation)).matrices.modelViewProjection
            let clip = point / 8 - 1
            XCTAssertEqual(mvp.columns.3.x, clip.x, accuracy: 0.00001)
            XCTAssertEqual(mvp.columns.3.y, clip.y, accuracy: 0.00001)
            guard case let .matrix(encoded)? = entry.draw.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("original shader must receive the same pre-tick pose")
            }
            XCTAssertEqual(encoded.columns[0][3], clip.x, accuracy: 0.00001)
            XCTAssertEqual(encoded.columns[1][3], clip.y, accuracy: 0.00001)
            let pixels = try readBack(renderer.backbuffer, device: device)
            let offset = (Int(16 - point.y) * 16 + Int(point.x)) * 4
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - 255), 1)
            XCTAssertLessThanOrEqual(pixels[offset + 1], 1)
            XCTAssertLessThanOrEqual(pixels[offset + 2], 1)
            XCTAssertTrue(renderer.backbuffer === backbuffer)
            XCTAssertEqual(renderer.targets.mapValues(ObjectIdentifier.init), targets)
            XCTAssertEqual(renderer.pipelineCreations, pipelines)
        }
        // speed0/roughness1: original Xoffset = (height16*.1)*(amplitude*.1), no trig precision claim.
        let steps: [(Bool, Double, Bool, Float, Float)] = [
            (true, 25, true, 0, 10), // old shakeoff; new parallax .25 acts in this frame
            (true, 12.5, false, 4, 4), // old amplitude25; tick writes12.5 for next camera update
            (false, 25, false, 2, 6), // old shakeon; tick turning off cannot undo this pose
            (true, 25, false, 0, 8), // old shakeoff; tick turning on cannot shake this pose
            (true, 25, false, 4, 4),
        ]
        for (index, step) in steps.enumerated() {
            let json = try host(enabled: step.0, amplitude: step.1, parallax: step.2)
            try renderer.applyUserProperties(unchanged, changedJSON: json, mergedJSON: json)
            try await frame(index, eye: SIMD2(step.3, 0), point: SIMD2(step.4, 8))
        }
        let next = try host(amplitude: 1, speed: 2, roughness: 2)
        try renderer.applyUserProperties(unchanged, changedJSON: next, mergedJSON: next)
        try await frame(5, eye: SIMD2(4, 0), point: SIMD2(4, 8))
        // Finite Mac formula admission for speed/roughness; no new UCRT/Darwin native0ULP oracle.
        let t = Float(renderer.clock.timeUniform + renderer.clock.frametime) * 4
        let x = cos(t), y = sin(Float(1.333) * t)
        let length = sqrt(x * x + y * y)
        let remap = pow(length, Float(8))
        let eye = SIMD2((1 / length * x) * remap, (1 / length * y) * remap) * Float(0.16)
        try await frame(6, eye: eye, point: SIMD2(repeating: 8) - eye)
        let invalid = try document(enabled: "true", speed: "3", amplitude: false, roughness: [1], visible: false)
        let paused = try host(drive: false)
        try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: invalid)),
                                         changedJSON: paused, mergedJSON: paused)
        for (name, value): (String, Float) in [("camerashake", 1), ("camerashakespeed", 2),
                                               ("camerashakeamplitude", 1), ("camerashakeroughness", 2)] {
            XCTAssertEqual(renderer.state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        XCTAssertEqual(renderer.state.object("1")?.visible, false)
        let coldDriver = try WPEParitySceneDriver(device: device)
        defer { coldDriver.cleanup() }
        let cold = try document(enabled: "true", speed: "3", amplitude: false, roughness: [1], scripts: false, witness: false)
        try await coldDriver.load(document: cold, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb,
                                  compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "shake-cold-cache")))
        let coldRenderer = try XCTUnwrap(coldDriver.renderer)
        XCTAssertTrue(coldRenderer.isStatic)
        XCTAssertFalse(coldDriver.needsContinuousFrames)
        for (name, value): (String, Float) in [("camerashake", 0), ("camerashakespeed", 3),
                                               ("camerashakeamplitude", 0.5), ("camerashakeroughness", 1)] {
            XCTAssertEqual(coldRenderer.state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let enabled = try document(enabled: true, scripts: false, witness: false)
        try coldRenderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: cold, to: enabled)))
        XCTAssertFalse(coldRenderer.isStatic)
        XCTAssertTrue(coldDriver.needsContinuousFrames)
        let disabled = try document(scripts: false, witness: false)
        try coldRenderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: enabled, to: disabled)))
        XCTAssertTrue(coldRenderer.isStatic)
        XCTAssertFalse(coldDriver.needsContinuousFrames)
        XCTAssertTrue(coldDriver.renderer === coldRenderer)
    }
}
#endif
