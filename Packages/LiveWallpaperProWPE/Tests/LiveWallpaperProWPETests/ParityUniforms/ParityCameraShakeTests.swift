@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityCameraShakeTests: XCTestCase {
    private let eye = SIMD3<Float>(10, 20, 0)
    private let center = SIMD3<Float>(10, 20, -1)

    private func assertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(lhs - rhs), accuracy, "\(lhs) != \(rhs)", file: file, line: line)
    }

    private func assertShake(_ shake: WPEParityCameraShake, time: Float, orthoHeight: Float, offset: SIMD3<Float>,
                             file: StaticString = #filePath, line: UInt = #line) {
        let shaken = shake.shaken(eye: eye, center: center, time: time, orthoHeight: orthoHeight)
        assertEqual(shaken.eye, eye + offset, accuracy: 1e-4, file: file, line: line)
        assertEqual(shaken.center, center + offset, accuracy: 1e-4, file: file, line: line)
    }

    func testPerspectiveAtTimeZeroMovesAlongX() {
        // t = 0: v = (1, 0, 0); A = 2 × 0.1.
        let shake = WPEParityCameraShake(speed: 1, amplitude: 2, roughness: 1, orthographic: false)
        assertShake(shake, time: 0, orthoHeight: 1080, offset: SIMD3(0.2, 0, 0))
    }

    func testRoughnessOneSkipsTheRemap() {
        // t = 2² × 0.5 = 2: v = (cos 2, sin 2.666, sin 2); A = 0.1.
        let shake = WPEParityCameraShake(speed: 2, amplitude: 1, roughness: 1, orthographic: false)
        assertShake(shake, time: 0.5, orthoHeight: 1080, offset: SIMD3(-0.0416147, 0.0457865, 0.0909297))
    }

    func testRoughnessTwoRemapsLength() {
        // r = 8: v = v̂ · |v|⁸ with |v| = 1.0998367.
        let shake = WPEParityCameraShake(speed: 2, amplitude: 1, roughness: 2, orthographic: false)
        assertShake(shake, time: 0.5, orthoHeight: 1080, offset: SIMD3(-0.0810110, 0.0891323, 0.1770123))
    }

    func testOrthographicDropsZAndScalesByOrthoHeight() {
        // A = 0.1 × 1080 × 0.1 = 10.8.
        let shake = WPEParityCameraShake(speed: 2, amplitude: 1, roughness: 1, orthographic: true)
        assertShake(shake, time: 0.5, orthoHeight: 1080, offset: SIMD3(-4.4943858, 4.9449464, 0))
    }

    func testOrthographicFlattensBeforeTheRoughnessRemap() {
        // 140199580.c:26-44: z = 0 first, so |v| = |(cos 2, sin 2.666)| = 0.618723; v = v̂ · |v|⁸; A = 10.8.
        let shake = WPEParityCameraShake(speed: 2, amplitude: 1, roughness: 2, orthographic: true)
        assertShake(shake, time: 0.5, orthoHeight: 1080, offset: SIMD3(-0.1560081, 0.1716479, 0))
    }

    private func document(general: String) throws -> WPESceneDocument {
        try ParityCameraFixture.document(json: """
        {"camera": {"center": "10 20 -1", "eye": "10 20 0", "up": "0 1 0"},
         "general": {\(general)}, "objects": []}
        """)
    }

    func testDocumentDefaultsAndDisabled() throws {
        let ortho = "\"orthogonalprojection\": {\"width\": 1920, \"height\": 1080}"
        let enabled = try document(general: "\(ortho), \"camerashake\": true")
        XCTAssertEqual(WPEParityCameraShake(general: enabled.general),
                       WPEParityCameraShake(speed: 3, amplitude: 0.5, roughness: 1, orthographic: true))
        let authored = try document(general: """
        \(ortho), "camerashake": true, "camerashakespeed": 2, "camerashakeamplitude": 1, "camerashakeroughness": 0.5
        """)
        XCTAssertEqual(WPEParityCameraShake(general: authored.general),
                       WPEParityCameraShake(speed: 2, amplitude: 1, roughness: 0.5, orthographic: true))
        let perspective = try document(general: "\"orthogonalprojection\": null, \"camerashake\": true")
        XCTAssertEqual(WPEParityCameraShake(general: perspective.general)?.orthographic, false)

        let disabled = try document(general: "\(ortho), \"camerashake\": false, \"camerashakespeed\": 2")
        XCTAssertNil(WPEParityCameraShake(general: disabled.general))
        let camera = WPEParityCamera(document: disabled, renderTargetSize: SIMD2(1920, 1080))
        XCTAssertNil(camera.shake)
        XCTAssertEqual(camera.shaken(time: 7), camera)
    }

    func testShakenViewTranslatesWithTimeAndFeedsParallaxBase() throws {
        let document = try document(general: """
        "orthogonalprojection": {"width": 1920, "height": 1080}, "camerashake": true, "camerashakespeed": 2,
        "camerashakeamplitude": 1
        """)
        let camera = WPEParityCamera(document: document, renderTargetSize: SIMD2(1920, 1080))
        let start = camera.shaken(time: 0)
        let later = camera.shaken(time: 0.5)
        // t = 0 → (10.8, 0, 0); t = 2 → (-4.4943858, 4.9449464, 0).
        let delta = SIMD3<Float>(-4.4943858 - 10.8, 4.9449464, 0)
        assertEqual(later.eye - start.eye, delta, accuracy: 1e-4)
        XCTAssertTrue(simd_almost_equal_elements(later.view, start.view * WPEParityCamera.translation(-delta), 1e-4))
        assertEqual(later.eyePosition - start.eyePosition, delta, accuracy: 1e-4)

        var parallax = WPEParityUniformParallax()
        parallax.advance(pointer: SIMD2(0.5, 0.5), mouseInfluence: 0, delay: 0, eye: SIMD2(later.eye.x, later.eye.y),
                         ortho: later.size, frametime: 0.016)
        let base = later.size * 0.5 + SIMD2(10, 20)
        XCTAssertEqual(parallax.smoothed.x, base.x + 10.8 * cos(2), accuracy: 1e-3)
        XCTAssertEqual(parallax.smoothed.y, base.y + 10.8 * sin(Float(1.333 * 2)), accuracy: 1e-3)
    }

    func testWithoutShakeViewHoldsOverTime() throws {
        let document = try document(general: "\"orthogonalprojection\": {\"width\": 1920, \"height\": 1080}")
        let camera = WPEParityCamera(document: document, renderTargetSize: SIMD2(1920, 1080))
        XCTAssertNil(camera.parallaxAmount)
        XCTAssertEqual(camera.shaken(time: 0).view, camera.shaken(time: 12.5).view)
        XCTAssertEqual(camera.shaken(time: 12.5).eyePosition, camera.eyePosition)
    }
}
