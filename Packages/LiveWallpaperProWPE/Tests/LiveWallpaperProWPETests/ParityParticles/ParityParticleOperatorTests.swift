@testable import LiveWallpaperProWPE
import XCTest

final class ParityParticleOperatorTests: XCTestCase {
    typealias Math = WPEParityParticleMath

    func testMovementAddsGravityBeforeDragAndIntegratesUndampedVelocity() {
        var position = SIMD3<Float>(0, 0, 0)
        var velocity = SIMD3<Float>(10, 0, 0)
        Math.move(position: &position, velocity: &velocity, acceleration: SIMD3(0, -100, 0), drag: 0.5, dt: 0.1)
        // v + g·dt = (10, -10, 0); drag factor 1 - 0.5·0.1 = 0.95; position uses the undamped (10, -10, 0).
        XCTAssertEqual(velocity.x, 9.5, accuracy: 1e-5)
        XCTAssertEqual(velocity.y, -9.5, accuracy: 1e-5)
        XCTAssertEqual(position.x, 1, accuracy: 1e-6)
        XCTAssertEqual(position.y, -1, accuracy: 1e-6)
    }

    func testMovementDragFactorIsCappedJustBelowOne() {
        var position = SIMD3<Float>(0, 0, 0)
        var velocity = SIMD3<Float>(10, 0, 0)
        Math.move(position: &position, velocity: &velocity, acceleration: .zero, drag: 100, dt: 0.1)
        XCTAssertEqual(velocity.x, 10 * (1 - 0.999_999_9), accuracy: 1e-9)
        XCTAssertGreaterThan(velocity.x, 0)
        XCTAssertEqual(position.x, 1, accuracy: 1e-6)
    }

    func testAlphaFadeBranches() {
        XCTAssertEqual(Math.alphaFade(t: 0.25, fadeIn: 0.5, fadeOut: 0.5), 0.5)
        XCTAssertEqual(Math.alphaFade(t: 0.75, fadeIn: 0.5, fadeOut: 0.5), 0.5)
        XCTAssertEqual(Math.alphaFade(t: 0.5, fadeIn: 0.5, fadeOut: 0.5), 1)
        XCTAssertEqual(Math.alphaFade(t: 0.5, fadeIn: 0.2, fadeOut: 0.8), 1)
        XCTAssertEqual(Math.alphaFade(t: 0.1, fadeIn: 0.2, fadeOut: 0.8), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Math.alphaFade(t: 0.9, fadeIn: 0.2, fadeOut: 0.8), 0.5, accuracy: 1e-5)
    }

    func testAlphaFadeOverlapOrsTheTwoBitPatterns() {
        // 0.5/0.9 = 0x3F0E38E4 and 0.5/0.8 = 0x3F200000 OR to 0x3F2E38E4.
        let t: Float = 0.5, fadeIn: Float = 0.9, fadeOut: Float = 0.2
        let fadeInValue = t / fadeIn
        let fadeOutValue = (1 - t) / (1 - fadeOut)
        let expected = Float(bitPattern: fadeInValue.bitPattern | fadeOutValue.bitPattern)
        XCTAssertNotEqual(expected, fadeInValue)
        XCTAssertNotEqual(expected, fadeOutValue)
        XCTAssertEqual(Math.alphaFade(t: t, fadeIn: fadeIn, fadeOut: fadeOut), expected)
    }

    func testRampInterpolatesAndClamps() {
        XCTAssertEqual(Math.ramp(t: 0.25, startTime: 0, endTime: 1, start: 1, end: 0), 0.75)
        XCTAssertEqual(Math.ramp(t: 0.25, startTime: 0.5, endTime: 1, start: 1, end: 0), 1)
        XCTAssertEqual(Math.ramp(t: 0.75, startTime: 0.5, endTime: 1, start: 1, end: 0), 0.5)
        XCTAssertEqual(Math.ramp(t: 1.5, startTime: 0, endTime: 1, start: 2, end: 4), 4)
    }

    func testColorChangeInterpolatesPerChannel() {
        let color = Math.ramp(
            t: 0.5, startTime: 0, endTime: 1,
            start: SIMD3<Float>(1, 0, 0.5), end: SIMD3<Float>(0, 1, 0.5)
        )
        XCTAssertEqual(color, SIMD3<Float>(0.5, 0.5, 0.5))
    }

    func testOscillateAlphaWithFixedU() {
        let wave = WPEParityParticleOscillation(
            frequencyMin: 1, frequencyMax: 3, scaleMin: 0.2, scaleMax: 1, phaseMin: 0, phaseMax: 2
        )
        // u = 0.5: f = 2, phase = 1, factor = 0.2 + 0.8·0.5·(sin(2·1.25) + 1)·0.5.
        let expected: Float = 0.2 + 0.8 * 0.5 * (sin(2 * 1.25) + 1) * 0.5
        XCTAssertEqual(Math.oscillation(age: 0.25, u: 0.5, wave: wave), expected, accuracy: 1e-6)
        XCTAssertEqual(expected, 0.519_694_4, accuracy: 1e-6)
    }

    func testOscillatePositionIsTheDifferenceOfTwoSines() {
        let wave = WPEParityParticleOscillation(
            frequencyMin: 2, frequencyMax: 2, scaleMin: 10, scaleMax: 10, phaseMin: 0, phaseMax: 0
        )
        let delta = Math.oscillationOffset(age: 1, dt: 0.1, u: 0, wave: wave, mask: SIMD3(1, 1, 0))
        XCTAssertEqual(delta.x, 10 * (sin(2) - sin(1.8)), accuracy: 1e-5)
        XCTAssertEqual(delta.y, delta.x, accuracy: 1e-6)
        XCTAssertEqual(delta.z, 0)
    }

    func testBlendWeightMultipliesInAndOutRamps() {
        let blend = WPEParityParticleBlend(inStart: 0, inEnd: 0.5, outStart: 0.5, outEnd: 1)
        XCTAssertEqual(blend.weight(t: 0.25), 0.5)
        XCTAssertEqual(blend.weight(t: 0.5), 1)
        XCTAssertEqual(blend.weight(t: 0.75), 0.5)
    }
}
