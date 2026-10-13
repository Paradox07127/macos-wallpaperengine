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

    func testPerspectiveFillsTheOrthoCanvasAtDistance() {
        var camera = camera(renderTarget: canvas)
        camera.perspectiveFOV = 60
        let distance = camera.perspectiveDistance
        XCTAssertEqual(distance, 1080 / tan(Float.pi / 6), accuracy: 1e-2)
        let clip = { (point: SIMD4<Float>) -> SIMD3<Float> in
            let value = camera.perspectiveProjection * camera.perspectiveView * point
            return SIMD3(value.x, value.y, value.z) / value.w
        }
        XCTAssertEqual(clip(SIMD4(1920, 1080, 0, 1)).x, 0, accuracy: 1e-5)
        XCTAssertEqual(clip(SIMD4(1920, 2160, 0, 1)).y, 1, accuracy: 1e-4)
        XCTAssertEqual(clip(SIMD4(3840, 1080, 0, 1)).x, 1, accuracy: 1e-4)
        XCTAssertEqual(camera.perspectiveProjection.columns.2.w, -1)
        XCTAssertEqual(camera.perspectiveView.columns.3.z, -distance)
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
}
