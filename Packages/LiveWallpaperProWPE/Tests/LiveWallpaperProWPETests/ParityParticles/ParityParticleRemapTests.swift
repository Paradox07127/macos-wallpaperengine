@testable import LiveWallpaperProWPE
import XCTest

final class ParityParticleRemapTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport
    private typealias Math = WPEParityParticleRemapMath

    /// One particle born on the first step with lifetime 2, then stepped `age` seconds.
    private func system(initializers: String = "", operators: String = "", age: Float = 0.5,
                        seed: UInt32 = 5489) -> WPEParityParticleSystem {
        var system = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 1,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}\(initializers)],
             "operator": [\(operators)]}
            """),
            rng: WPEParityMT19937(seed: seed), is3D: true
        )
        system.advance(dt: 0.001)
        if age > 0 {
            system.advance(dt: age)
        }
        XCTAssertEqual(system.liveCount, 1)
        return system
    }

    private func opacity(_ extra: String) -> Float {
        system(operators: """
        {"name": "remapvalue", "operation": "remap", "output": "opacity",
         "outputrangemin": 0.2, "outputrangemax": 0.6\(extra)}
        """).alpha[0]
    }

    /// (U^exp·Δ + min)·alpha (D/14023b340.c:524-539).
    func testAlphaRandomExponentShapesTheDraw() {
        let linear = system(initializers: #", {"name": "alpharandom", "min": 0.2, "max": 0.6}"#, age: 0)
        let squared = system(initializers: #", {"name": "alpharandom", "min": 0.2, "max": 0.6, "exponent": 2}"#,
                             age: 0)
        let u = (linear.alpha[0] - 0.2) / 0.4
        XCTAssertEqual(squared.alpha[0], u * u * 0.4 + 0.2, accuracy: 1e-6)
    }

    /// Input lifetimefraction 0.5/2, output Δ·v + min (full.s 601363-601759, 601930-601945).
    func testRemapValueMapsLifetimeFractionIntoOpacity() {
        XCTAssertEqual(opacity(""), 0.3, accuracy: 1e-7)
    }

    /// Transforms at v = 0.25 (full.s 601415-601693).
    func testRemapValueTransforms() {
        // sine: sin_ps(0.25·2π − π/2)·0.5 + 0.5 = 0.5.
        XCTAssertEqual(opacity(#", "transformfunction": "sine""#), 0.4, accuracy: 1e-6)
        // saw: frac(0.25) = 0.25; triangle: 1 − |0.5 − 1| = 0.5; square: rint(frac(0.75)) = 1.
        XCTAssertEqual(opacity(#", "transformfunction": "saw", "transforminputscale": 1"#), 0.3, accuracy: 1e-7)
        XCTAssertEqual(opacity(#", "transformfunction": "triangle", "transforminputscale": 1"#), 0.4, accuracy: 1e-7)
        XCTAssertEqual(opacity(#", "transformfunction": "square", "transforminputscale": 3"#), 0.6, accuracy: 1e-7)
    }

    /// Input clamp (flags 1) and output clamp (flags 2) to [0, 1] (full.s 601375-601402, 601760-601765).
    func testRemapValueClampFlags() {
        XCTAssertEqual(opacity(#", "inputrangemax": 0.125, "flags": 1"#), 0.6, accuracy: 1e-7)
        let clamped = system(operators: """
        {"name": "remapvalue", "operation": "remap", "output": "opacity", "outputrangemin": 0.2,
         "outputrangemax": 5, "flags": 2}
        """)
        XCTAssertEqual(clamped.alpha[0], 1)
    }

    /// FastNoise 2D simplex, seed = bits of the birth u; goldens re-evaluated in float32 (w48-dec/noise_golden.py).
    func testSimplex2Goldens() {
        let seed = Int32(bitPattern: Float(0.5).bitPattern)
        XCTAssertEqual(Math.simplex2(seed: seed, 2.5, 0).bitPattern, 0xBF03_E8E5)
        XCTAssertEqual(Math.simplex2(seed: seed, 1.7, 0).bitPattern, 0x3EBB_B3E3)
        XCTAssertEqual(Math.simplex2(seed: seed, -3.3, 0).bitPattern, 0x3EA6_63B1)
        XCTAssertEqual(Math.simplex2(seed: 12345, 0, 0), 0)
    }

    /// Cephes sin_ps at known angles (full.s 601415-601470).
    func testSinPS() {
        XCTAssertEqual(Math.sinPS(0), 0)
        XCTAssertEqual(Math.sinPS(Math.halfPi), 1, accuracy: 1e-7)
        XCTAssertEqual(Math.sinPS(-Math.pi / 6), -0.5, accuracy: 1e-7)
        XCTAssertEqual(Math.sinPS(3 * Math.halfPi), -1, accuracy: 1e-6)
    }

    /// Simplex transform with the particle's own seed, scale 10 (the workshop scene's form).
    func testRemapValueSimplexUsesBirthSeed() {
        let particles = system(operators: """
        {"name": "remapvalue", "operation": "remap", "output": "opacity", "outputrangemin": 0.2,
         "outputrangemax": 0.6, "transformfunction": "simplexnoise", "transforminputscale": 10}
        """)
        let noise = Math.simplex2(seed: Int32(bitPattern: particles.birthU[0].bitPattern), 2.5, 0)
        XCTAssertEqual(particles.alpha[0], 0.4 * (noise * 0.5 + 0.5) + 0.2)
    }

    /// fbm: Σ noise·amp with amp from 1/(1 + 0.5 + 0.25), seed + 1 per octave (D/1400fbc70.c).
    func testFBM2SumsOctaves() {
        let seed: Int32 = 7, x: Float = 1.3
        let bounding = Float(1) / 1.75
        var expected = Math.simplex2(seed: seed, x, 0) * bounding
        expected += Math.simplex2(seed: 8, x * 2, 0) * (bounding * 0.5)
        expected += Math.simplex2(seed: 9, x * 4, 0) * (bounding * 0.25)
        XCTAssertEqual(Math.fbm2(seed: seed, octaves: 3, bounding: bounding, x, 0), expected, accuracy: 1e-7)
    }

    /// Speed output scales velocity to the remapped length (full.s 601947-601993); two steps double it twice.
    func testRemapValueSpeedOutput() {
        let particles = system(
            initializers: #", {"name": "velocityrandom", "min": "3 4 0", "max": "3 4 0"}"#,
            operators: #"{"name": "remapvalue", "operation": "multiply", "output": "speed", "outputrangemin": 2, "outputrangemax": 2}"#
        )
        XCTAssertEqual(particles.velocity[0].x, 12, accuracy: 1e-5)
        XCTAssertEqual(particles.velocity[0].y, 16, accuracy: 1e-5)
    }

    /// remapinitialvalue: maxlifetime 2 over 0..4 → 0.5 → size 0..10 → 5 (full.s 594467-594476, 594841-594847,
    /// 595062-595072).
    func testRemapInitialValueSetsInitialSize() {
        let particles = system(initializers: """
        , {"name": "remapinitialvalue", "operation": "remap", "inputrangemax": 4, "output": "size",
           "outputrangemax": 10}
        """, age: 0)
        XCTAssertEqual(particles.size[0], 5, accuracy: 1e-6)
    }

    /// remapinitialvalue sine uses CRT sinf on (v·π)·scale − π/2 (full.s 594869-594901).
    func testRemapInitialValueSine() {
        let particles = system(initializers: """
        , {"name": "remapinitialvalue", "operation": "remap", "inputrangemax": 4, "output": "size",
           "outputrangemax": 10, "transformfunction": "sine", "transforminputscale": 1}
        """, age: 0)
        let expected = (sinf(0.5 * Math.pi * 1 - Math.halfPi) * 0.5 + 0.5) * 10
        XCTAssertEqual(particles.size[0], expected, accuracy: 1e-6)
    }

    /// The child's velocity takes its parent's at birth, its opacity follows the live parent (full.s 596358-596640,
    /// 605733-605879).
    func testInheritFromEventParent() {
        let child = #"{"maxcount": 1, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}], "initializer": [{"name": "inheritinitialvaluefromevent", "input": "setvelocity"}], "operator": [{"name": "inheritvaluefromevent", "input": "setopacity"}]}"#
        var parent = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 1,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5},
                             {"name": "velocityrandom", "min": "1 2 3", "max": "1 2 3"},
                             {"name": "alpharandom", "min": 0.25, "max": 0.25}],
             "children": [{"name": "c.json", "type": "eventspawn"}]}
            """),
            rng: WPEParityMT19937(seed: 1), is3D: true, resolveChild: { _ in Support.json(child) }
        )
        parent.advance(dt: 0.001)
        parent.advance(dt: 0.001)
        let spawned = parent.eventChildren[0][0]
        XCTAssertEqual(spawned.liveCount, 1)
        XCTAssertEqual(spawned.velocity[0], SIMD3(1, 2, 3))
        XCTAssertEqual(spawned.alpha[0], 0.25)
    }

    /// Hidden with live particles: count and object time to 0, no new starttime prewarm (140230650.c:19-50,
    /// D/14022f6c0.c); showing again emits from a zero accumulator.
    func testHiddenResetDoesNotPrewarmAgain() {
        var particles = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 50, "starttime": 1,
             "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}
            """),
            rng: WPEParityMT19937(seed: 3), is3D: true
        )
        XCTAssertEqual(particles.prewarmStepCount, 20)
        particles.advance(dt: 0.5)
        XCTAssertEqual(particles.objectTime, 0.5)
        particles.reset()
        XCTAssertEqual(particles.liveCount, 0)
        XCTAssertEqual(particles.objectTime, 0)
        XCTAssertEqual(particles.prewarmStepCount, 0)
        particles.advance(dt: 0.25)
        XCTAssertEqual(particles.liveCount, 2)
        XCTAssertEqual(particles.objectTime, 0.25)
    }
}
