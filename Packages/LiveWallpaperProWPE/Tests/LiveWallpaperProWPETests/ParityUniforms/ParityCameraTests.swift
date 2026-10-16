import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

enum ParityCameraFixture {
    private struct NoScripts: WPESceneTransformScriptResolving {
        func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                         seed _: SIMD3<Double>) -> SIMD3<Double>? {
            nil
        }
    }

    static func document(json: String) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                         makeTransformScriptResolver: { _, _ in NoScripts() })
    }

    /// Scene 3660962877 from the HLSL capture: 3840×2160, V = I, object 935 rotated −90°.
    static func scene3660962877() throws -> WPESceneDocument {
        try captured("3660962877")
    }

    static func captured(_ sceneID: String) throws -> WPESceneDocument {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"] else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/\(sceneID)/scene.json")
        return try WPESceneDocumentParser.parse(data: Data(contentsOf: url), userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }
}

final class ParityCameraTests: XCTestCase {
    private let canvas = SIMD2<Float>(3840, 2160)

    func testActiveCameraUsesLastVisibleObjectAndItsParentWorld() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera":{"eye":"100 200 300","center":"100 200 299","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"perspectiveoverridefov":70,"fov":50},
         "objects":[
          {"id":10,"origin":"10 20 30","angles":"0 1.5707963267948966 0","scale":"2 3 4"},
          {"id":1,"camera":"camera","parent":10,"origin":"1 2 3","fov":60,"zoom":2},
          {"id":2,"camera":"camera","origin":"-5 -6 -7","visible":false}]}
        """)
        var state = WPEParitySceneState(document: document, hdr: false)
        let transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(200, 100))
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "1")
        let root = WPEParityCamera.root(document: document, renderTargetSize: SIMD2(200, 100))
        let selected = root.applyingObject(world: transforms.world("1"), objectID: "1", document: document,
                                           state: state, generalZoom: 1.5)
        XCTAssertLessThan(simd_length(selected.eye - SIMD3(22, 26, 28)), 1e-5)
        XCTAssertLessThan(simd_length(selected.center - SIMD3(18, 26, 28)), 1e-5)
        XCTAssertLessThan(simd_reduce_max(simd_abs(selected.up - SIMD3(0, 3, 0))), 1e-5)
        XCTAssertEqual(selected.scenePerspective?.fov, 60)
        XCTAssertEqual(selected.perspectiveFOV, 70)
        XCTAssertEqual(selected.zoom, 3)
        state.setScriptField("fov", of: "1", to: .vector(SIMD4(90, 0, 0, 0)), invalidating: .none)
        state.setScriptField("zoom", of: "1", to: .vector(SIMD4(3, 0, 0, 0)), invalidating: .none)
        let scripted = root.applyingObject(world: transforms.world("1"), objectID: "1", document: document,
                                           state: state, generalZoom: 1.5)
        XCTAssertEqual(scripted.scenePerspective?.fov, 90)
        XCTAssertEqual(scripted.zoom, 4.5)
        XCTAssertEqual(scripted.perspectiveFOV, 70)
        // The parser's initial pose follows the same matrix contract.
        XCTAssertLessThan(simd_length(SIMD3<Float>(document.camera.eye) - selected.eye), 1e-5)
        XCTAssertLessThan(simd_length(SIMD3<Float>(document.camera.center) - selected.center), 1e-5)
        XCTAssertEqual(document.cameraMotion?.objectID, "1")
        state.set(.visible, of: "2", to: SIMD4(1, 0, 0, 0))
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "2")
        state.set(.visible, of: "2", to: .zero)
        state.set(.visible, of: "10", to: .zero)
        XCTAssertNil(WPEParityCamera.activeObjectID(document: document, state: state))
        XCTAssertEqual(root.eye, SIMD3(100, 200, 300), "hidden objects fall back to the authored root")
        XCTAssertEqual(root.center, SIMD3(100, 200, 299))
        let orthographic = camera(renderTarget: canvas).applyingObject(world: transforms.world("1"), fov: 60,
                                                                       zoom: 2, generalZoom: 1)
        XCTAssertNil(orthographic.scenePerspective)
        XCTAssertEqual(orthographic.perspectiveFOV, 95, "object FOV does not rewrite layer override FOV")
    }

    func testCursorWorldUsesViewportHalfDepthAndOnlyDropsOrthographicZ() {
        var camera = WPEParityCamera(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0),
                                     size: SIMD2(200, 100), renderTargetSize: SIMD2(200, 100))
        XCTAssertLessThan(simd_reduce_max(simd_abs(camera.cursorWorld(normalizedPointer: SIMD2(0.2, 0.1))
                - SIMD3(40, 90, 0))), 1e-4)
        camera.eye.z = 5
        camera.center.z = 4
        camera.scenePerspective = .init(fov: 90, near: 1, far: 10)
        let world = camera.cursorWorld(normalizedPointer: SIMD2(0.75, 0.25))
        // Reverse-Z clip depth 0 samples the far plane. It is not an intersection with the scene's z=0 plane.
        XCTAssertLessThan(simd_length(world - SIMD3(10, 5, -5)), 1e-4)
    }

    func testParserSkipsHiddenCameraAncestorAndCameraDefaultFovIsIndependentOfGeneral() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":75},
         "objects":[{"id":1,"camera":"camera","origin":"7 8 9"},
                    {"id":10,"visible":false},
                    {"id":2,"camera":"camera","parent":10,"origin":"20 30 40","fov":120}]}
        """)
        XCTAssertEqual(document.cameraMotion?.objectID, "1")
        XCTAssertEqual(document.camera.eye, SIMD3(7, 8, 9))
        XCTAssertEqual(document.camera.fov, 50, "H08 camera ctor/post-load default is 50")
        let initial = WPEParityCamera(document: document, renderTargetSize: SIMD2(200, 100))
        XCTAssertEqual(initial.scenePerspective?.fov, 50)
        let root = WPEParityCamera.root(document: document, renderTargetSize: SIMD2(200, 100))
        XCTAssertEqual(root.scenePerspective?.fov, 75)
        let state = WPEParitySceneState(document: document, hdr: false)
        let layers = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(200, 100))
        let selected = root.applyingObject(world: layers.world("1"), objectID: "1", document: document,
                                           state: state, generalZoom: 2)
        XCTAssertEqual(selected.scenePerspective?.fov, 50)
        XCTAssertEqual(selected.zoom, 2)
    }

    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, accuracy: Float = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(simd_almost_equal_elements(lhs, rhs, accuracy), "\(lhs) != \(rhs)", file: file, line: line)
    }

    private func camera(renderTarget: SIMD2<Float>, alignment: WPEParityCameraAlignment = .noCrop,
                        zoom: Float = 1) -> WPEParityCamera {
        WPEParityCamera(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), size: canvas,
                        renderTargetSize: renderTarget, zoom: zoom, alignment: alignment)
    }

    func testFixtureCameraIsIdentityViewAndCanvasOrtho() throws {
        let camera = try WPEParityCamera(document: ParityCameraFixture.scene3660962877(),
                                         renderTargetSize: canvas)
        assertEqual(camera.view, matrix_identity_float4x4)
        XCTAssertEqual(camera.bounds, SIMD4(0, 3840, 0, 2160))
        let expected = simd_float4x4(rows: [
            SIMD4(2.0 / 3840, 0, 0, -1), SIMD4(0, 2.0 / 2160, 0, -1), SIMD4(0, 0, 1.0 / 4000, 0.5), SIMD4(0, 0, 0, 1),
        ])
        assertEqual(camera.projection, expected)
    }

    func testOrthoMapsDepthToZeroOne() {
        let projection = camera(renderTarget: canvas).projection
        XCTAssertEqual((projection * SIMD4<Float>(0, 0, -2000, 1)).z, 0, accuracy: 1e-6)
        XCTAssertEqual((projection * SIMD4<Float>(0, 0, 2000, 1)).z, 1, accuracy: 1e-6)
        XCTAssertEqual(projection * SIMD4<Float>(3840, 2160, 0, 1), SIMD4(1, 1, 0.5, 1))
    }

    func testLookAtIsRightHanded() {
        let view = WPEParityCamera.lookAt(eye: SIMD3(10, 20, 5), center: SIMD3(10, 20, 4), up: SIMD3(0, 1, 0))
        XCTAssertEqual(view * SIMD4<Float>(10, 20, 0, 1), SIMD4(0, 0, -5, 1))
        XCTAssertEqual(view * SIMD4<Float>(11, 21, 5, 1), SIMD4(1, 1, 0, 1))
    }

    func testCropOnNarrowerTargetFollowsAlignmentPosition() {
        let target = SIMD2<Float>(1600, 1200)
        // E = 3840 - 2160 * 4/3 = 960; l = (1 - a)E, r = W - aE.
        let cases: [(position: Float, bounds: SIMD4<Float>)] = [
            (0, SIMD4(960, 3840, 0, 2160)), (50, SIMD4(480, 3360, 0, 2160)), (100, SIMD4(0, 2880, 0, 2160)),
        ]
        for (position, bounds) in cases {
            let camera = camera(renderTarget: target,
                                alignment: WPEParityCameraAlignment(mode: 0, position: position))
            XCTAssertEqual(camera.bounds, bounds, "position \(position)")
            XCTAssertEqual((camera.projection * SIMD4(bounds.x, 0, 0, 1)).x, -1, accuracy: 1e-6)
            XCTAssertEqual((camera.projection * SIMD4(bounds.y, 0, 0, 1)).x, 1, accuracy: 1e-6)
        }
        XCTAssertEqual(camera(renderTarget: target).bounds, SIMD4(0, 3840, 0, 2160), "mode 2 never crops")
        XCTAssertEqual(camera(renderTarget: canvas, alignment: WPEParityCameraAlignment(mode: 0)).bounds,
                       SIMD4(0, 3840, 0, 2160), "matching aspect does not crop")
    }

    func testCropOnWiderTargetIsVertical() {
        let camera = camera(renderTarget: SIMD2(3840, 1080), alignment: WPEParityCameraAlignment(mode: 0))
        // E = 2160 - 3840 * 1080/3840 = 1080, centred.
        XCTAssertEqual(camera.bounds, SIMD4(0, 3840, 540, 1620))
    }

    func testFlipHorizontalMirrorsCroppedBounds() {
        let alignment = WPEParityCameraAlignment(mode: 0, position: 0, flipHorizontal: true)
        let camera = camera(renderTarget: SIMD2(1600, 1200), alignment: alignment)
        XCTAssertEqual(camera.bounds, SIMD4(3840 - 960, 0, 0, 2160))
        XCTAssertEqual((camera.projection * SIMD4<Float>(2880, 0, 0, 1)).x, -1, accuracy: 1e-6)
    }

    func testZoomKeepsCanvasCentreFixed() {
        let plain = camera(renderTarget: canvas).projection
        let zoomed = camera(renderTarget: canvas, zoom: 2).projection
        let centre = SIMD4<Float>(1920, 1080, 0, 1)
        XCTAssertEqual(zoomed * centre, plain * centre)
        XCTAssertEqual(zoomed * SIMD4<Float>(960, 540, 0, 1), SIMD4(-1, -1, 0.5, 1))
    }

    func testDocumentZoomMultipliesCameraZoom() throws {
        let document = try ParityCameraFixture.scene3660962877()
        let camera = WPEParityCamera(document: document, renderTargetSize: canvas, cameraZoom: 3)
        XCTAssertEqual(camera.zoom, 3)
    }

    func testEyePositionAddsHalfCanvas() {
        var camera = camera(renderTarget: canvas)
        camera.eye = SIMD3(10, -20, 0)
        XCTAssertEqual(camera.eyePosition, SIMD3(1930, 1060, 2000))
        XCTAssertEqual(camera.eyePosition,
                       WPEParityUniformParallax.eyePosition2D(eye: SIMD2(10, -20), ortho: canvas))
    }

    func testParallaxOffsetsViewByRootDepth() {
        var camera = camera(renderTarget: canvas)
        camera.parallaxAmount = 0.5
        let view = camera.view(parallaxRoot: SIMD2(1000, 500), depth: SIMD2(1, 0.5), smoothed: SIMD2(1920, 1080))
        // (origin - m) * amount * depth = (-920, -580) * 0.5 * (1, 0.5)
        XCTAssertEqual(view * SIMD4<Float>(0, 0, 0, 1), SIMD4(-460, -145, 0, 1))
    }

    func testPerspectiveFillsTheOrthoCanvasAtDistance() throws {
        let camera = camera(renderTarget: canvas)
        XCTAssertEqual(camera.perspectiveFOV, 95)
        let distance = try camera.perspectiveDistance
        // Original CPU 16 paired calls: input 3f543b67 -> Tan return 3f8bafff. This is not a native D golden.
        let nativeTangent = Float(bitPattern: 0x3F8B_AFFF)
        XCTAssertEqual(distance * nativeTangent * camera.projection.columns.1.y, 1, accuracy: 1e-6)
        let projection = try camera.perspectiveProjection
        let view = try camera.perspectiveView
        let clip = { (point: SIMD4<Float>) -> SIMD3<Float> in
            let value = projection * view * point
            return SIMD3(value.x, value.y, value.z) / value.w
        }
        XCTAssertEqual(clip(SIMD4(1920, 1080, 0, 1)).x, 0, accuracy: 1e-5)
        XCTAssertEqual(clip(SIMD4(1920, 2160, 0, 1)).y, 1, accuracy: 1e-4)
        XCTAssertEqual(clip(SIMD4(3840, 1080, 0, 1)).x, 1, accuracy: 1e-4)
        XCTAssertEqual(projection.columns.2.w, -1)
        XCTAssertEqual(view.columns.3.z, -distance)
        var unsupported = camera
        unsupported.perspectiveFOV = .infinity
        XCTAssertThrowsError(try unsupported.perspectiveView) {
            XCTAssertEqual($0 as? WPEParityCamera.PerspectiveMathError,
                           .unsupportedFieldOfView(inputBits: Float.infinity.bitPattern))
        }
        unsupported.scenePerspective = .init(fov: 50)
        XCTAssertNoThrow(try unsupported.perspectiveDistance, "perspective derives its angle without consuming O144")
        unsupported.scenePerspective?.fov = .nan
        XCTAssertThrowsError(try unsupported.perspectiveProjection) {
            XCTAssertEqual($0 as? WPEParityCamera.PerspectiveMathError,
                           .unsupportedFieldOfView(inputBits: Float.nan.bitPattern))
        }
    }

    /// 3509243656 has `"orthogonalprojection": null`: lookAt V and FUN_14009a360's reversed-depth perspective.
    func testPerspectiveScene3509243656UsesGeneralFovNearFar() throws {
        let document = try ParityCameraFixture.captured("3509243656")
        let camera = WPEParityCamera(document: document, renderTargetSize: SIMD2(1920, 1080))
        XCTAssertEqual(camera.scenePerspective, WPEParityScenePerspective(fov: 50, near: 0.0099999998, far: 10000))
        XCTAssertNil(camera.parallaxAmount)
        // Camera object 443 replaces the JSON camera: eye = W.col3, center = eye − W.col2, up = W.col1
        // (1401891a0.c:85-104).
        assertEqual(camera.view, WPEParityCamera.translation(SIMD3(0, 0, -6)))
        assertEqual(camera.projection, simd_float4x4(rows: [
            SIMD4(1.20628514, 0, 0, 0), SIMD4(0, 2.14450692, 0, 0), SIMD4(0, 0, 1.000001e-6, 0.01000001),
            SIMD4(0, 0, -1, 0),
        ]))
        XCTAssertEqual(camera.eyePosition, SIMD3(0, 0, 6))
        var mirrored = camera
        mirrored.alignment.flipHorizontal = true
        XCTAssertEqual(mirrored.projection.columns.0.x, -1.20628514, accuracy: 1e-5)
    }

    func testPerspectiveDepthIsReversed() {
        let projection = WPEParityCamera.perspective(fovY: 1, aspect: 1, near: 5, far: 15000)
        let near = projection * SIMD4<Float>(0, 0, -5, 1)
        let far = projection * SIMD4<Float>(0, 0, -15000, 1)
        XCTAssertEqual(near.z / near.w, 1, accuracy: 1e-6)
        XCTAssertEqual(far.z / far.w, 0, accuracy: 1e-6)
    }

    func testAutoProjectionTakesFirstImageLayerSize() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"orthogonalprojection": {"auto": true}},
         "objects": [{"id": 1, "image": "models/a.json", "origin": "7 9 0", "size": "1000 500"}]}
        """)
        let camera = WPEParityCamera(document: document, renderTargetSize: SIMD2(1000, 500))
        XCTAssertEqual(camera.size, SIMD2(1000, 500))
        let layers = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(1000, 500))
        XCTAssertEqual(layers.layers["1"]?.origin, SIMD3(500, 250, 0))
    }

    func testAuthoredSizeWithoutAutoKeepsLayerOrigin() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "image": "models/a.json", "origin": "7 9 0", "size": "1000 500"}]}
        """)
        XCTAssertEqual(WPEParityCamera(document: document, renderTargetSize: SIMD2(1920, 1080)).size,
                       SIMD2(1920, 1080))
        let layers = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(1920, 1080))
        XCTAssertEqual(layers.layers["1"]?.origin, SIMD3(7, 9, 0))
    }

    /// 140186c90.c:1045-1052: the ortho bit without camera paths loads the scene camera at eye 0.
    func testOrthoSceneWithoutPathsResetsTheRootPose() throws {
        func cameras(_ ortho: String, objects: String = "[]") throws -> (root: WPEParityCamera, initial: WPEParityCamera) {
            let document = try ParityCameraFixture.document(json: """
            {"camera": {"center": "100 200 -1", "eye": "100 200 0", "up": "0 1 0"},
             "general": {"orthogonalprojection": \(ortho)}, "objects": \(objects)}
            """)
            let scene = WPEParityProgramScene(document: document,
                                              assets: WPEParityProgramAssets(sceneDirectory: FileManager.default.temporaryDirectory,
                                                                             assetRoots: []),
                                              settings: .init())
            let pathless = scene.engineFlags.orthographicProjection && scene.cameraPaths.paths.isEmpty
            return (WPEParityCamera.root(document: document, renderTargetSize: SIMD2(1920, 1080), orthoWithoutPaths: pathless),
                    WPEParityCamera(document: document, renderTargetSize: SIMD2(1920, 1080), orthoWithoutPaths: pathless))
        }
        let ortho = try cameras(#"{"width": 1920, "height": 1080}"#)
        for camera in [ortho.root, ortho.initial] {
            XCTAssertEqual(camera.eye, .zero)
            XCTAssertEqual(camera.center, SIMD3(0, 0, -1))
            XCTAssertEqual(camera.up, SIMD3(0, 1, 0))
            XCTAssertEqual(camera.eyePosition, SIMD3(960, 540, 2000))
        }
        for authored in ["null", #"{"width": 0, "height": 1080}"#] {
            let kept = try cameras(authored)
            XCTAssertEqual(kept.root.eye, SIMD3(100, 200, 0), authored)
            XCTAssertEqual(kept.initial.eye, SIMD3(100, 200, 0), authored)
        }
        let object = try cameras(#"{"width": 1920, "height": 1080}"#,
                                 objects: #"[{"id": 1, "camera": "camera", "origin": "7 8 9"}]"#)
        XCTAssertEqual(object.root.eye, .zero)
        XCTAssertEqual(object.initial.eye, SIMD3(7, 8, 9), "a camera object keeps its own pose")
    }
}
