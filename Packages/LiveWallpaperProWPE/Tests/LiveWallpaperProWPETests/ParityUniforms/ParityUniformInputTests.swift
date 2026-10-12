@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityUniformInputTests: XCTestCase {
    func testPointerIsUnclampedYDownWithLastAndState() {
        let screen = WPEParityUniformScreen(clientWidth: 1920, clientHeight: 1080)
        var pointer = WPEParityUniformPointer()
        pointer.advance(cursor: SIMD2(960, 270), screen: screen, buttonDown: true)
        XCTAssertEqual(pointer.position, SIMD2(0.5, 0.25))
        XCTAssertEqual(pointer.state, SIMD4(1, 1, 1, 0))
        pointer.advance(cursor: SIMD2(-192, 2160), screen: screen, buttonDown: true)
        XCTAssertEqual(pointer.position, SIMD2(-0.1, 2))
        XCTAssertEqual(pointer.lastPosition, SIMD2(0.5, 0.25))
        XCTAssertEqual(pointer.state, SIMD4(1, 1, 0, 0))
        pointer.advance(cursor: SIMD2(0, 0), screen: screen, buttonDown: false)
        XCTAssertEqual(pointer.lastPosition, SIMD2(-0.1, 2))
        XCTAssertEqual(pointer.state, SIMD4(0, 0, 0, 0))
    }

    func testParallaxDelayLerp() {
        let ortho = SIMD2<Float>(1920, 1080)
        let dt: Float = 1.0 / 60
        func step(delay: Float) -> SIMD2<Float> {
            var parallax = WPEParityUniformParallax()
            parallax.advance(pointer: SIMD2(1, 0), mouseInfluence: 1, delay: delay, eye: .zero, ortho: ortho,
                             frametime: dt)
            return parallax.position
        }
        XCTAssertEqual(step(delay: 0), SIMD2(1, 1))
        let half = step(delay: 1.5)
        XCTAssertEqual(half.x, 5 * dt, accuracy: 1e-6)
        XCTAssertEqual(half.y, 5 * dt, accuracy: 1e-6)
        XCTAssertEqual(step(delay: 3), SIMD2(0, 0))
    }

    func testParallaxTargetAndClamp() {
        let ortho = SIMD2<Float>(1920, 1080)
        var parallax = WPEParityUniformParallax()
        parallax.advance(pointer: SIMD2(0.9, 0.9), mouseInfluence: 0.5, delay: 0, eye: SIMD2(192, 0),
                         ortho: ortho, frametime: 1.0 / 60)
        XCTAssertEqual(parallax.position.x, 0.5 + 0.5 * 0.4 + 0.1, accuracy: 1e-6)
        XCTAssertEqual(parallax.position.y, 0.5 - 0.5 * 0.4, accuracy: 1e-6)
        parallax.advance(pointer: SIMD2(0.5, 0.5), mouseInfluence: 0, delay: 0, eye: SIMD2(1920, -1080),
                         ortho: ortho, frametime: 1.0 / 60)
        XCTAssertEqual(parallax.position, SIMD2(1, 0))
    }

    func testEyeAndViewVectors() {
        XCTAssertEqual(WPEParityUniformParallax.eyePosition2D(eye: SIMD2(10, 20), ortho: SIMD2(1920, 1080)),
                       SIMD3(970, 560, 2000))
        let view = simd_float4x4(rows: [
            SIMD4(0, 1, 0, 5),
            SIMD4(0, 0, 1, 6),
            SIMD4(1, 0, 0, 7),
            SIMD4(0, 0, 0, 1),
        ])
        let vectors = WPEParityUniformParallax.viewVectors(view: view)
        XCTAssertEqual(vectors.right, SIMD3(0, 1, 0))
        XCTAssertEqual(vectors.up, SIMD3(0, 0, 1))
        XCTAssertEqual(vectors.forward, SIMD3(-1, 0, 0))
    }

    func testScreenWithOneByOneClient() {
        let screen = WPEParityUniformScreen(clientWidth: 1, clientHeight: 1)
        XCTAssertEqual(screen.screen, SIMD3(2, 2, 1))
        XCTAssertEqual(screen.texelSize, SIMD2(0.5, 0.5))
        XCTAssertEqual(screen.texelSizeHalf, SIMD2(0.25, 0.25))
    }
}
