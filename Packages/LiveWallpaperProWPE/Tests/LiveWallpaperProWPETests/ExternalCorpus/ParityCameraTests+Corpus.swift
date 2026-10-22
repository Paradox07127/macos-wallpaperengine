import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

extension ParityCameraTests {
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

    func testDocumentZoomMultipliesCameraZoom() throws {
        let document = try ParityCameraFixture.scene3660962877()
        let camera = WPEParityCamera(document: document, renderTargetSize: canvas, cameraZoom: 3)
        XCTAssertEqual(camera.zoom, 3)
    }

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
}
