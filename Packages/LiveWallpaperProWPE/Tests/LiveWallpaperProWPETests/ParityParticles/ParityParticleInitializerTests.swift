@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleInitializerTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport

    private func initializers(_ entries: String, is3D: Bool = false) -> [WPEParityParticleInitializer] {
        WPEParityParticleConfig(
            json: Support.json(#"{"maxcount": 1, "initializer": [\#(entries)]}"#),
            is3D: is3D, resolveChild: { _ in nil }
        ).initializers
    }

    private func hsv(_ entry: String) -> WPEParityParticleHSVRandom {
        WPEParityParticleHSVRandom(WPEParityParticleEntry(Support.json(entry)))
    }

    /// `count` births in one frame at `origin` from a sphere emitter with zero distance and speed (8 U each).
    private func burst(
        _ count: Int, initializers: String, origin: String = "0 0 0", extra: String = "",
        rng: WPEParityMT19937 = WPEParityMT19937(), frame: WPEParityParticleFrameContext = .init()
    ) -> WPEParityParticleSystem {
        var system = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": \(count),
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": \(count), "distancemax": 0,
                          "origin": "\(origin)"}],
             "initializer": [\(initializers)]\(extra)}
            """),
            rng: rng, is3D: true
        )
        system.advance(dt: 0.001, frame: frame)
        XCTAssertEqual(system.liveCount, count)
        return system
    }

    private func assertEqual(
        _ actual: SIMD3<Float>, _ expected: SIMD3<Float>, accuracy: Float = 1e-5, line: UInt = #line
    ) {
        for axis in 0 ..< 3 {
            XCTAssertEqual(actual[axis], expected[axis], accuracy: accuracy, "axis \(axis)", line: line)
        }
    }

    func testLifetimeRandomDefaultsToZeroToOne() {
        XCTAssertEqual(initializers(#"{"name": "lifetimerandom"}"#), [.lifetime(min: 0, max: 1, exponent: 1)])
    }

    func testSizeRandomDefaultsDependOnDimension() {
        XCTAssertEqual(initializers(#"{"name": "sizerandom"}"#, is3D: true), [.size(min: 0.001, max: 1, exponent: 1)])
        XCTAssertEqual(initializers(#"{"name": "sizerandom"}"#), [.size(min: 5, max: 50, exponent: 1)])
    }

    func testChildDefaultsToProbabilityOneAndMaxCountTen() {
        let config = WPEParityParticleConfig(
            json: Support.json(#"{"maxcount": 1, "children": [{"name": "c.json", "type": "eventdeath"}]}"#),
            is3D: false, resolveChild: { _ in Support.json(#"{"maxcount": 1}"#) }
        )
        XCTAssertEqual(config.children[0].probability, 1)
        XCTAssertEqual(config.children[0].maxCount, 10)
    }

    func testHSVDefaultsAndStepRule() {
        let defaults = hsv("{}")
        XCTAssertEqual(defaults.hueMin, 0)
        XCTAssertEqual(defaults.steps, 6)
        // A whole turn divides by steps: 1/6.
        XCTAssertEqual(defaults.hueStep, 1.0 / 6, accuracy: 1e-7)
        XCTAssertEqual(defaults.saturation, SIMD2(0.5, 1))
        XCTAssertEqual(defaults.value, SIMD2(0.5, 1))
        XCTAssertEqual(hsv(#"{"huesteps": 1}"#).hueStep, 0)
        XCTAssertEqual(hsv(#"{"huesteps": 0}"#).hueStep, 0)
        XCTAssertEqual(hsv(#"{"huemax": 0.5}"#).hueStep, 0.1, accuracy: 1e-7)
        XCTAssertEqual(hsv(#"{"huemax": 2, "huesteps": 4}"#).hueStep, 0.5, accuracy: 1e-7)
        // fmod(1.001, 1) = 0.001 < 1/360: still range/steps; 0.01 is not.
        XCTAssertEqual(hsv(#"{"huemax": 1.001, "huesteps": 4}"#).hueStep, 1.001 / 4, accuracy: 1e-6)
        XCTAssertEqual(hsv(#"{"huemax": 1.01, "huesteps": 4}"#).hueStep, 1.01 / 3, accuracy: 1e-6)
    }

    func testHSVPicksTheHueStepWithTheCRTRand() {
        let system = burst(3, initializers: """
        {"name": "hsvcolorrandom", "saturationmin": 1, "saturationmax": 1, "valuemin": 1, "valuemax": 1}
        """)
        // rand() = 41, 18467, 6334 → k = ⌊r/32767·7⌋ = 0, 3, 1 → hue 0, 0.5, 1/6.
        assertEqual(system.initialColor[0], SIMD3(1, 0, 0))
        assertEqual(system.initialColor[1], SIMD3(0, 1, 1))
        assertEqual(system.initialColor[2], SIMD3(1, 1, 0))
    }

    func testHSVDrawsTwoUniformsPerBirth() {
        let rng = WPEParityMT19937(), mirror = WPEParityMT19937()
        _ = burst(1, initializers: #"{"name": "hsvcolorrandom"}"#, rng: rng)
        for _ in 0 ..< 8 + 2 {
            _ = mirror.next()
        }
        XCTAssertEqual(rng.next(), mirror.next())
    }

    func testColorListStaysInsideTheNoiseBoundsAndDrawsFourTimes() {
        let rng = WPEParityMT19937(), mirror = WPEParityMT19937()
        let list = #"{"name": "colorlist", "colors": ["1 0 0"], "saturationnoise": 0.3, "valuenoise": 0.2}"#
        let single = burst(1, initializers: list, rng: rng)
        for _ in 0 ..< 8 + 4 {
            _ = mirror.next()
        }
        XCTAssertEqual(rng.next(), mirror.next())
        XCTAssertGreaterThan(single.initialColor[0].x, 0)

        let many = burst(200, initializers: list)
        for slot in 0 ..< 200 {
            // HSV (0, s, v) with s ∈ [0.7, 1], v ∈ [0.8, 1] is (v, v(1 − s), v(1 − s)).
            let color = many.initialColor[slot]
            XCTAssertGreaterThanOrEqual(color.x, 0.8 - 1e-6)
            XCTAssertLessThanOrEqual(color.x, 1 + 1e-6)
            XCTAssertEqual(color.y, color.z, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(color.y, color.x * 0.3 + 1e-6)
        }
    }

    func testColorListDefaultsToWhiteAndConvertsToHSV() {
        XCTAssertEqual(initializers(#"{"name": "colorlist"}"#), [.colorList(hsv: [SIMD3(0, 0, 1)], noise: .zero)])
        XCTAssertEqual(initializers(#"{"name": "colorlist", "colors": []}"#), [.colorList(hsv: [SIMD3(0, 1, 1)], noise: .zero)])
        XCTAssertEqual(
            initializers(#"{"name": "colorlist", "colors": ["0 0 1"]}"#),
            [.colorList(hsv: [SIMD3(2.0 / 3, 1, 1)], noise: .zero)]
        )
    }

    func testPositionOffsetIsDeterministicAndDrawsNothing() {
        let rng = WPEParityMT19937(), mirror = WPEParityMT19937()
        let offset = #"{"name": "positionoffsetrandom", "octaves": 1, "scale": 0.5, "distance": 2}"#
        let frame = WPEParityParticleFrameContext(time: 0.5)
        let system = burst(1, initializers: offset, origin: "1 2 3", rng: rng, frame: frame)
        for _ in 0 ..< 8 {
            _ = mirror.next()
        }
        XCTAssertEqual(rng.next(), mirror.next())
        // One octave: fbm is the bare 2D noise; T = time·timescale.
        let noise = SIMD3(
            WPEParityParticleNoise.simplex2(0.5, 0.5), WPEParityParticleNoise.simplex2(0.5, 1),
            WPEParityParticleNoise.simplex2(1.5, -0.5)
        )
        assertEqual(system.position[0], SIMD3(1, 2, 3) + noise * 2)
        let again = burst(1, initializers: offset, origin: "1 2 3", frame: frame)
        XCTAssertEqual(again.position[0], system.position[0])
    }

    func testSequenceAroundRepeatWrapsAndMirrorReflects() {
        let around = #"{"name": "mapsequencearoundcontrolpoint", "count": 4"#
        let repeating = burst(6, initializers: around + "}", origin: "2 0 0")
        let expectedRepeat: [SIMD3<Float>] = [
            SIMD3(2, 0, 0), SIMD3(0, 2, 0), SIMD3(-2, 0, 0), SIMD3(0, -2, 0), SIMD3(2, 0, 0), SIMD3(0, 2, 0),
        ]
        for (slot, expected) in expectedRepeat.enumerated() {
            assertEqual(repeating.position[slot], expected)
        }
        // Mirror: t = 0, ¼, ½, ¾, 1, then 1¼ reflects to ¾.
        let mirrored = burst(6, initializers: around + #", "limitbehavior": "mirror"}"#, origin: "2 0 0")
        let expectedMirror: [SIMD3<Float>] = [
            SIMD3(2, 0, 0), SIMD3(0, 2, 0), SIMD3(-2, 0, 0), SIMD3(0, -2, 0), SIMD3(2, 0, 0), SIMD3(0, -2, 0),
        ]
        for (slot, expected) in expectedMirror.enumerated() {
            assertEqual(mirrored.position[slot], expected)
        }
    }

    func testSequenceBetweenRepeatRestartsAndMirrorReflects() {
        let points = #", "controlpoint": [{"id": 1, "offset": "4 0 0"}]"#
        let between = #"{"name": "mapsequencebetweencontrolpoints", "count": 5"#
        let repeating = burst(7, initializers: between + "}", extra: points)
        XCTAssertEqual((0 ..< 7).map { repeating.position[$0].x }, [0, 1, 2, 3, 4, 0, 1])
        let mirrored = burst(7, initializers: between + #", "limitbehavior": "mirror"}"#, extra: points)
        XCTAssertEqual((0 ..< 7).map { mirrored.position[$0].x }, [0, 1, 2, 3, 4, 3, 2])
    }
}
