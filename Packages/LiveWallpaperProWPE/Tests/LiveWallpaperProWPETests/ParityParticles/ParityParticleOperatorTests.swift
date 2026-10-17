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

    func testDragUsesTheFrametimeScaledStep() {
        func damped(_ frame: WPEParityParticleFrameContext) -> (linear: Float, angular: Float) {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount":1,"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10},
               {"name":"velocityrandom","min":"10 0 0","max":"10 0 0"},
               {"name":"angularvelocityrandom","min":"0 0 10","max":"0 0 10"}],
             "operator":[{"name":"movement","drag":1},{"name":"angularmovement","drag":1}]}
            """), rng: WPEParityMT19937(seed: 7))
            particles.advance(dt: 1.0 / 30, frame: frame)
            let slot = ParityParticleTestSupport.liveSlots(particles)[0]
            return (particles.velocity[slot].x, particles.angularVelocity[slot].z)
        }
        // dt·powf(min(0.025·30, 1), 0.7) = 0.75^0.7/30 ≈ 0.027253 → 1 − 0.027253 = 0.972747.
        let scaled = damped(WPEParityParticleFrameContext(frametime: 1.0 / 30))
        XCTAssertEqual(scaled.linear, 9.727_47, accuracy: 1e-4)
        XCTAssertEqual(scaled.angular, 9.727_47, accuracy: 1e-4)
        let plain = damped(WPEParityParticleFrameContext())
        XCTAssertEqual(plain.linear, 10 * (1 - 1.0 / 30))
        XCTAssertEqual(plain.angular, 10 * (1 - 1.0 / 30))
        // At or above 40 fps the factor is 1.
        XCTAssertEqual(damped(WPEParityParticleFrameContext(frametime: 0.02)).linear, plain.linear)
    }

    func testAudioModeZeroAndNilFrametimeMatchUnauthoredSimulationBitForBit() {
        func run(_ audioKey: String, frame: WPEParityParticleFrameContext) -> [UInt32] {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount":64,"emitter":[{"name":"sphererandom","rate":40,"speedmin":5,"speedmax":20\(audioKey)}],
             "initializer":[{"name":"lifetimerandom","min":2,"max":4},
               {"name":"turbulentvelocityrandom"\(audioKey)}],
             "operator":[{"name":"movement","drag":0.7,"gravity":"0 -30 0"},
               {"name":"angularmovement","drag":0.4,"force":"0 0 3"},
               {"name":"turbulence"\(audioKey)},{"name":"vortex"\(audioKey)},{"name":"vortex_v2"\(audioKey)}]}
            """), rng: WPEParityMT19937(seed: 11))
            for index in 0 ..< 45 {
                var step = frame
                step.time = Float(index) / 30
                particles.advance(dt: 1.0 / 30, frame: step)
            }
            return ParityParticleTestSupport.liveSlots(particles).flatMap { slot in
                [particles.position[slot], particles.velocity[slot], particles.angularVelocity[slot]]
                    .flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
            }
        }
        let loud = SIMD16<Float>(repeating: 1)
        let baseline = run("", frame: WPEParityParticleFrameContext())
        XCTAssertFalse(baseline.isEmpty)
        XCTAssertEqual(run(#","audioprocessingmode":0"#,
                           frame: WPEParityParticleFrameContext(spectrumLeft: loud, spectrumRight: loud)), baseline)
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
