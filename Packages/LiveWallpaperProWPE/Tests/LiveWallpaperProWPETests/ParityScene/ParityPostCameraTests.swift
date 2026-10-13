import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Camera paths, camerafade and ccsimple as WPE loads and steps them (R15, 1401891a0.c, FUN_140198e20).
final class ParityPostCameraTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-post-camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("camera"),
                                                withIntermediateDirectories: true)
        let transformA0: [String: Any] = ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"]
        let transformA1: [String: Any] = ["eye": "100 0 0", "center": "100 0 -1", "up": "0 1 0", "zoom": 2]
        let transformB0: [String: Any] = ["eye": "10 20 30", "center": "10 20 29", "up": "0 1 0", "timestamp": 0]
        let transformB1: [String: Any] = ["eye": "20 20 30", "center": "20 20 29", "up": "0 1 0"]
        let file: [String: Any] = ["paths": [
            ["duration": 2, "transforms": [transformA0, transformA1]],
            ["duration": 5, "disabled": true, "transforms": [transformA0]],
            // The disabled first transform still counts: the last one's default timestamp is 2/2 × 1.
            ["duration": 1, "transforms": [["disabled": true, "eye": "9 9 9"], transformB0, transformB1]],
            ["duration": 3, "transforms": []],
            ["duration": 4, "transforms": [transformA0]],
        ]]
        try JSONSerialization.data(withJSONObject: file).write(to: root.appendingPathComponent("camera/paths.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Camera paths

    func testPathFileStopsAtTheFirstPathWithoutTransformsAndSkipsDisabledOnes() throws {
        let paths = try scene(camera: ["paths": ["camera/paths.json"]]).cameraPaths.paths
        XCTAssertEqual(paths.map(\.duration), [2, 1])
        XCTAssertEqual(paths[0].keyframes.map(\.timestamp), [0, 2])
        XCTAssertEqual(paths[0].keyframes.map(\.pose.zoom), [1, 2])
        XCTAssertEqual(paths[1].keyframes.map(\.timestamp), [0, 1])
        XCTAssertEqual(paths[1].keyframes[0].pose.eye, SIMD3(10, 20, 30))
    }

    func testEveryPathsEntryClearsTheListSoOnlyATrailingStringLoads() throws {
        XCTAssertTrue(try scene(camera: ["paths": ["camera/paths.json", 3]]).cameraPaths.paths.isEmpty)
        XCTAssertEqual(try scene(camera: ["paths": [3, "camera/paths.json"]]).cameraPaths.paths.count, 2)
        XCTAssertTrue(try scene(camera: ["paths": ["camera/missing.json"]]).cameraPaths.paths.isEmpty)
    }

    /// dt 0.5: the pose is taken before the step; path A ends once t passes its last keyframe, B loops back to A.
    func testTwoPathsStepThroughTheSwitchAndLoop() throws {
        var paths = try scene(camera: ["paths": ["camera/paths.json"]]).cameraPaths
        let expected: [(eye: SIMD3<Float>, centerX: Float, zoom: Float, path: Int)] = [
            (SIMD3(0, 0, 0), 0, 1, 0),
            // s = 0.25: h10 0.140625, h00 0.84375, h11 −0.046875, h01 0.15625.
            (SIMD3(20.3125, 0, 0), 20.3125, 1.203125, 0),
            (SIMD3(50, 0, 0), 50, 1.5, 0),
            (SIMD3(79.6875, 0, 0), 79.6875, 1.796875, 0),
            (SIMD3(100, 0, 0), 100, 2, 1),
            (SIMD3(10, 20, 30), 10, 1, 1),
            (SIMD3(15, 20, 30), 15, 1, 1),
            (SIMD3(20, 20, 30), 20, 1, 0),
            (SIMD3(0, 0, 0), 0, 1, 0),
        ]
        for (frame, want) in expected.enumerated() {
            let pose = try XCTUnwrap(paths.advance(dt: 0.5), "frame \(frame)")
            XCTAssertEqual(pose.eye, want.eye, "frame \(frame)")
            XCTAssertEqual(pose.center.x, want.centerX, "frame \(frame)")
            XCTAssertEqual(pose.zoom, want.zoom, "frame \(frame)")
            XCTAssertEqual(paths.pathIndex, want.path, "frame \(frame)")
        }
    }

    func testPosedCameraZoomsByGeneralTimesPoseZoomBeforeTheShake() {
        let base = WPEParityCamera(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), size: SIMD2(1920, 1080),
                                   renderTargetSize: SIMD2(1920, 1080), zoom: 1.5,
                                   shake: WPEParityCameraShake(speed: 1, amplitude: 2, roughness: 1,
                                                               orthographic: false))
        let pose = WPEParityCameraPose(eye: SIMD3(5, 6, 7), center: SIMD3(5, 6, 6), up: SIMD3(0, 1, 0), zoom: 2)
        let camera = base.posed(pose, generalZoom: 1.5).shaken(time: 0)
        XCTAssertEqual(camera.zoom, 3)
        XCTAssertEqual(camera.eye.x, 5.2, accuracy: 1e-5)
        XCTAssertEqual(camera.center.x, 5.2, accuracy: 1e-5)
    }

    func testNoPathsLeavesTheSceneCamera() {
        var paths = WPEParityCameraPaths()
        XCTAssertNil(paths.advance(dt: 0.5))
        XCTAssertEqual(paths.fadeAlpha, 0)
    }

    // MARK: Fade

    func testFadeAlphaOverThePathEdges() throws {
        var paths = try scene(camera: ["paths": ["camera/paths.json"]]).cameraPaths
        var alphas: [Float] = []
        for _ in 0 ..< 8 {
            _ = paths.advance(dt: 0.25)
            alphas.append(paths.fadeAlpha)
        }
        // t = 0.25, 0.5 … 2 of D = 2.
        XCTAssertEqual(alphas, [0.5, 0, 0, 0, 0, 0, 0.5, 1])
    }

    func testFadeLoadsOnlyWithCameraFadeAndPaths() throws {
        let withPaths: [String: Any] = ["paths": ["camera/paths.json"]]
        XCTAssertTrue(try scene(camera: withPaths).postProcess.fadeActive)
        XCTAssertFalse(try scene(camera: withPaths, general: ["camerafade": false]).postProcess.fadeActive)
        XCTAssertFalse(try scene(camera: ["paths": []], general: ["camerafade": true]).postProcess.fadeActive)
        XCTAssertFalse(try scene(camera: [:]).postProcess.fadeActive)
    }

    func testFadeDrawsAfterColorCorrection() throws {
        let program = try scene(camera: ["paths": ["camera/paths.json"]],
                                colorCorrection: WPEParityColorCorrection(wecE: true, wecBrs: 25))
        let draws = WPEParityPostProcessBuilder.build(program.postProcess).draws
        XCTAssertEqual(draws.suffix(2).map(\.shader), ["ccsimple", "fade"])
        XCTAssertEqual(draws.last?.blend, .translucent)
    }

    // MARK: ccsimple

    func testDefaultColorCorrectionDrawsNothing() throws {
        XCTAssertFalse(try scene(camera: [:]).postProcess.colorCorrectionEnabled)
        let neutral = try scene(camera: [:], colorCorrection: WPEParityColorCorrection(wecE: true, wecCon: 50,
                                                                                       wecBrs: 50, wecSa: 50,
                                                                                       wecHue: 50, wccAmt: 100))
        XCTAssertFalse(neutral.postProcess.colorCorrectionEnabled)
        XCTAssertFalse(WPEParityPostProcessBuilder.build(neutral.postProcess).draws.contains { $0.shader == "ccsimple" })
    }

    func testColorAdjustmentWritesScaledParams() throws {
        let program = try scene(camera: [:], colorCorrection: WPEParityColorCorrection(
            wecE: true, wecCon: 100, wecBrs: 25, wecSa: 100, wecHue: 75
        ))
        let draw = try XCTUnwrap(WPEParityPostProcessBuilder.build(program.postProcess).draws.last)
        XCTAssertEqual(draw.shader, "ccsimple")
        XCTAssertEqual(draw.reads, ["_rt_FullFrameBuffer"])
        XCTAssertEqual(draw.combos, ["COL": 1])
        let root2 = Float(2).squareRoot()
        XCTAssertEqual(draw.constants, ["g_Params": [0.25, root2, root2, 0.25]])
        XCTAssertTrue(draw.textures.isEmpty)
    }

    func testLUTBindsSlotOneAndAmountWithoutParams() throws {
        let program = try scene(camera: [:], colorCorrection: WPEParityColorCorrection(wccV: "warm", wccAmt: 50))
        let draw = try XCTUnwrap(WPEParityPostProcessBuilder.build(program.postProcess).draws.last)
        XCTAssertEqual(draw.combos, ["LUT": 1])
        XCTAssertEqual(draw.constants, ["g_LutParams": [0.5]])
        XCTAssertEqual(draw.textures, [1: "lut/warm"])
        let material = program.engineMaterial(draw)
        XCTAssertEqual(material.combos["LUT"], 1)
        XCTAssertEqual(material.textures[1], "lut/warm")
        let off = try scene(camera: [:], colorCorrection: WPEParityColorCorrection(wccV: "warm", wccAmt: 0))
        XCTAssertFalse(off.postProcess.colorCorrectionEnabled)
    }

    func testColorAndLUTTogether() throws {
        let program = try scene(camera: [:], colorCorrection: WPEParityColorCorrection(wecE: true, wecSa: 0,
                                                                                       wccV: "cool"))
        let draw = try XCTUnwrap(WPEParityPostProcessBuilder.build(program.postProcess).draws.last)
        XCTAssertEqual(draw.combos, ["COL": 1, "LUT": 1])
        XCTAssertEqual(draw.constants, ["g_Params": [1, 1, 0, 0], "g_LutParams": [1]])
    }

    // MARK: Helpers

    private func scene(camera: [String: Any], general: [String: Any] = [:],
                       colorCorrection: WPEParityColorCorrection = WPEParityColorCorrection()) throws
        -> WPEParityProgramScene {
        var general = general
        general["orthogonalprojection"] = ["width": 1920, "height": 1080]
        var cameraJSON = camera
        cameraJSON["center"] = "0 0 -1"
        cameraJSON["eye"] = "0 0 0"
        cameraJSON["up"] = "0 1 0"
        let json: [String: Any] = ["camera": cameraJSON, "general": general,
                                   "objects": [["id": 1, "name": "layer"]]]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        return WPEParityProgramScene(document: document,
                                     assets: WPEParityProgramAssets(sceneDirectory: root, assetRoots: []),
                                     settings: WPEParityProgramSettings(colorCorrection: colorCorrection))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
