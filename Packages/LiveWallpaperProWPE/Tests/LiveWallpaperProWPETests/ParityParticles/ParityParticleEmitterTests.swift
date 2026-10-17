@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleEmitterTests: XCTestCase {
    /// 237a21..237acd: a positive timer crossing below zero still emits; zero goes directly to another on phase.
    /// These finite MT schedules use nonzero box launches (six words per birth) and independent word ordinals.
    func testPeriodicSignedClockKeepsTheCrossingFrameAndExactZeroBoundary() {
        for (duration, counts, birthWords, words) in [
            (Float(0.1), [1, 2, 3, 3, 4], [6, 12, 19, 26], 27),
            (Float(0.125), [1, 2, 3, 4, 5], [6, 12, 18, 25, 31], 32),
        ] {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount":20,"emitter":[{"name":"boxrandom","rate":16,"flags":4,
              "distancemin":"1 1 1","distancemax":"1 1 1",
              "minperiodicduration":\(duration),"maxperiodicduration":\(duration),
              "minperiodicdelay":0.1,"maxperiodicdelay":0.1}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
            """), rng: WPEParityMT19937(seed: 7))
            for expected in counts {
                particles.advance(dt: 0.0625)
                XCTAssertEqual(particles.liveCount, expected)
            }
            let expected = WPEParityMT19937(seed: 7)
            var samples: [Float] = []
            for ordinal in 1 ... words {
                let raw = expected.next()
                if birthWords.contains(ordinal) {
                    samples.append(Float(raw >> 8) * 0x1p-24)
                }
            }
            XCTAssertEqual(Array(particles.birthU.prefix(samples.count)), samples)
            XCTAssertEqual(particles.rng.next(), expected.next())
        }
    }

    func testPeriodicClockPausesAtDelayAndCapacityAndRateCapDropsRequestedExcess() {
        for delayed in [false, true] {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount":1,"emitter":[{"name":"boxrandom","rate":16,"flags":4,
              "delay":\(delayed ? 0.1 : 0),"distancemin":"1 1 1","distancemax":"1 1 1",
              "minperiodicduration":0.1,"maxperiodicduration":0.1}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
            """), rng: WPEParityMT19937(seed: 7))
            for frame in 0 ..< 5 {
                particles.advance(dt: 0.0625)
                XCTAssertEqual(particles.liveCount, delayed && frame < 2 ? 0 : 1)
            }
            let expected = WPEParityMT19937(seed: 7)
            for _ in 0 ..< 7 {
                _ = expected.next()
            }
            XCTAssertEqual(particles.rng.next(), expected.next(), "full capacity does not advance the periodic clock")
        }
        var capped = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
        {"maxcount":20,"emitter":[{"name":"boxrandom","rate":64,"flags":2,
          "distancemin":"1 1 1","distancemax":"1 1 1"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
        """), rng: WPEParityMT19937(seed: 7))
        for frame in 1 ... 3 {
            capped.advance(dt: 0.0625)
            XCTAssertEqual(capped.liveCount, frame)
            XCTAssertEqual(capped.emitterStates[0].accumulator, 0)
        }
    }

    private func burst(_ emitter: String, count: Int = 1000) -> WPEParityParticleSystem {
        var particles = WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": \(count), "emitter": [\(emitter)]}
            """),
            rng: WPEParityMT19937()
        )
        particles.advance(dt: 0.001)
        XCTAssertEqual(particles.liveCount, count)
        return particles
    }

    func testSphereOffsetsLieInTheShellOnTheDirectionPlane() {
        let particles = burst(#"{"name": "sphererandom", "rate": 0, "instantaneous": 1000, "distancemin": 10, "distancemax": 20}"#)
        for slot in ParityParticleTestSupport.liveSlots(particles) {
            let offset = particles.position[slot]
            XCTAssertEqual(offset.z, 0)
            XCTAssertGreaterThanOrEqual(simd_length(offset), 10 - 1e-3)
            XCTAssertLessThanOrEqual(simd_length(offset), 20 + 1e-3)
        }
    }

    func testSphereSignForcesTheAxisSign() {
        let particles = burst(#"{"name": "sphererandom", "rate": 0, "instantaneous": 200, "distancemax": 5, "sign": "0 -1 0"}"#, count: 200)
        for slot in ParityParticleTestSupport.liveSlots(particles) {
            XCTAssertLessThanOrEqual(particles.position[slot].y, 0)
        }
    }

    func testBoxOffsetsAreHollowWithBothSignsPerAxis() {
        let particles = burst(#"{"name": "boxrandom", "rate": 0, "instantaneous": 1000, "directions": "1 1 1", "distancemin": "5 6 7", "distancemax": "10 12 14"}"#)
        let low = SIMD3<Float>(5, 6, 7), high = SIMD3<Float>(10, 12, 14)
        var negative = SIMD3<Int>(repeating: 0), positive = SIMD3<Int>(repeating: 0)
        for slot in ParityParticleTestSupport.liveSlots(particles) {
            let offset = particles.position[slot]
            for axis in 0 ..< 3 {
                XCTAssertGreaterThanOrEqual(abs(offset[axis]), low[axis] - 1e-4)
                XCTAssertLessThanOrEqual(abs(offset[axis]), high[axis] + 1e-4)
                if offset[axis] < 0 {
                    negative[axis] += 1
                } else {
                    positive[axis] += 1
                }
            }
        }
        for axis in 0 ..< 3 {
            XCTAssertGreaterThan(negative[axis], 300)
            XCTAssertGreaterThan(positive[axis], 300)
        }
    }

    func testZeroOffsetFallsBackToARandomDirectionOnTheMask() {
        let particles = burst(#"{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0, "speedmin": 5, "speedmax": 5}"#, count: 1)
        let mirror = WPEParityMT19937()
        _ = mirror.unitAboveZero() // phi
        _ = mirror.unit() // cos theta
        _ = mirror.unitAboveZero() // radius
        let x = 2 * nativeLaunchUnit(mirror) - 1
        let y = 2 * nativeLaunchUnit(mirror) - 1
        _ = mirror.next() // z, masked by directions "1 1 0"
        let expected = simd_normalize(SIMD3<Float>(x, y, 0)) * 5
        let velocity = particles.velocity[0]
        XCTAssertEqual(particles.position[0], .zero)
        XCTAssertEqual(simd_length(velocity), 5, accuracy: 1e-5)
        XCTAssertEqual(velocity.x, expected.x, accuracy: 1e-5)
        XCTAssertEqual(velocity.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(velocity.z, 0)
    }

    func testBoxZeroOffsetFallsBackOnTheDirections() {
        let particles = burst(#"{"name": "boxrandom", "rate": 0, "instantaneous": 50, "distancemax": "0 0 0", "speedmin": 3, "speedmax": 3}"#, count: 50)
        for slot in ParityParticleTestSupport.liveSlots(particles) {
            XCTAssertEqual(simd_length(particles.velocity[slot]), 3, accuracy: 1e-5)
            XCTAssertEqual(particles.velocity[slot].z, 0)
        }
    }

    /// A real birth, with ordinary local points and a radians instance input. Expectations below use fixed
    /// axes/centers and native draw counts, never the CP/sample helpers being exercised.
    private func ordinaryBirth(shape: String, index: Int? = nil, distance: Float = 1,
                               minimum: String? = nil, maximum: String? = nil,
                               origin: String = "2 0 0", directions: String = "1 0 0", speed: Float = 3, speedMax: Float? = nil,
                               controlPoints: String = #"{"id": 0, "offset": "10 20 0"}, {"id": 1, "offset": "10 20 0"}, {"id": 7, "offset": "70 80 0"}"#,
                               rotate: Bool = true) -> WPEParityParticleSystem {
        let cp = index.map { #", "controlpoint": \#($0)"# } ?? ""
        let distances = shape == "sphererandom" ? "\(distance)" : "\"\(distance) \(distance) \(distance)\""
        let low = minimum.map { "\"\($0)\"" } ?? distances
        let high = maximum.map { "\"\($0)\"" } ?? distances
        let config = WPEParityParticleConfig(json: ParityParticleTestSupport.json("""
        {"maxcount": 1, "controlpoint": [\(controlPoints)],
         "emitter": [{"name": "\(shape)", "rate": 0, "instantaneous": 1, "origin": "\(origin)",
                      "directions": "\(directions)", "sign": "1 0 0", "distancemin": \(low),
                      "distancemax": \(high), "speedmin": \(speed), "speedmax": \(speedMax ?? speed)\(cp)}],
         "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}],
         "renderer": [{"name": "sprite"}]}
        """), is3D: false, resolveChild: { _ in nil })
        var instance = WPEParityParticleSystem.Instance()
        if rotate {
            for point in [0, 1, 7] {
                instance.controlPointAngles[point] = SIMD3(0, 0, .pi / 2)
            }
        }
        var particles = WPEParityParticleSystem(config: config, instance: instance,
                                                rng: WPEParityMT19937(seed: 7), crt: WPEParityCRTRandom())
        particles.advance(dt: 0.001)
        XCTAssertEqual(particles.liveCount, 1)
        return particles
    }

    private func assertNextWord(_ particles: WPEParityParticleSystem, after draws: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< draws {
            _ = expected.next()
        }
        XCTAssertEqual(particles.rng.next(), expected.next(), file: file, line: line)
    }

    /// Independent conversion from fresh17c715/71c +229320 raw instructions, not rng.unitAboveZero().
    private func nativeLaunchUnit(_ rng: WPEParityMT19937) -> Float {
        let low = Float(bitPattern: 0x3727_C5AC)
        let raw = Float(rng.next() >> 8) * 0x1p-24
        return low + (1 - low) * raw
    }

    func testOrdinaryEmitterPointUsesUnsignedMinAndLocalZeroIgnoresBasis() {
        // 1c6008/1c6910 cmovb: missing/0 => 0; 1 => 1; -1/7/8 => 7.
        for shape in ["sphererandom", "boxrandom"] {
            for (authored, resolved) in [(nil, 0), (0, 0), (1, 1), (-1, 7), (7, 7), (8, 7)] as [(Int?, Int)] {
                let particles = ordinaryBirth(shape: shape, index: authored)
                XCTAssertEqual(particles.config.emitters[0].controlPoint, resolved)
                let center = resolved == 7 ? SIMD3<Float>(72, 80, 0) : SIMD3<Float>(12, 20, 0)
                let offset = particles.position[0] - center
                let velocity = particles.velocity[0]
                let activeAxis = resolved == 0 ? 0 : 1
                let otherAxis = resolved == 0 ? 1 : 0
                XCTAssertEqual(abs(offset[activeAxis]), 1, accuracy: 1e-5, "\(shape) CP\(resolved)")
                XCTAssertEqual(offset[otherAxis], 0, accuracy: 1e-5)
                XCTAssertEqual(offset.z, 0)
                XCTAssertEqual(velocity[activeAxis], offset[activeAxis] * 3, accuracy: 1e-5)
                XCTAssertEqual(velocity[otherAxis], 0, accuracy: 1e-5)
                XCTAssertEqual(velocity.z, 0)
                XCTAssertEqual(simd_length(velocity), 3, accuracy: 1e-5)
                if shape == "sphererandom" {
                    XCTAssertEqual(offset[activeAxis], 1, accuracy: 1e-5)
                }
                // Three shape words + speed + birthU + lifetime; translating/rotating the CP draws nothing.
                assertNextWord(particles, after: 6)
            }
        }
    }

    func testOrdinaryNonzeroPointRotatesFallbackThenNormalizesItsSpeed() {
        for shape in ["sphererandom", "boxrandom"] {
            let particles = ordinaryBirth(shape: shape, index: 1, distance: 0)
            XCTAssertEqual(particles.position[0], SIMD3(12, 20, 0), "origin 2 stays on x despite the CP rotation")
            XCTAssertEqual(particles.velocity[0].x, 0, accuracy: 1e-5)
            XCTAssertEqual(abs(particles.velocity[0].y), 3, accuracy: 1e-5)
            XCTAssertEqual(particles.velocity[0].z, 0)
            // Shape degeneracy adds three direction words before the speed/lifetime words.
            assertNextWord(particles, after: 9)
        }
    }

    func testDefaultZeroPointPreservesBirthBytesAndDrawSchedule() {
        // Fixed authored bytes are independent of the sampling/packing implementation.
        let floats: [Float] = [2, 0, 0, 0, 0, 0, 0.5, 1, 1, 1, 1]
        let expected = floats.flatMap { value -> [UInt8] in
            let bits = value.bitPattern
            return (0 ..< 4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        for shape in ["sphererandom", "boxrandom"] {
            for index in [nil, 0] as [Int?] {
                var particles = ordinaryBirth(shape: shape, index: index, distance: 0, speed: 0,
                                              controlPoints: "", rotate: false)
                let renderer = particles.renderers[0]
                XCTAssertEqual(particles.vertices(for: renderer).bytes, expected)
                assertNextWord(particles, after: 9)
            }
        }
    }

    func testBoxPositionCancellationConsumesFallbackWordsButSphereDoesNot() {
        // At 2^24 the Float spacing is >=1: every component of a radius .25 is lost on the position write.
        // Native box subtracts the center again; sphere tests the offset before that write (2378a0).
        for shape in ["sphererandom", "boxrandom"] {
            let particles = ordinaryBirth(shape: shape, distance: 0.25, origin: "16777216 16777216 16777216",
                                          directions: "1 1 1", speed: 2, controlPoints: "", rotate: false)
            XCTAssertEqual(particles.position[0], SIMD3(repeating: Float(16_777_216)))
            XCTAssertEqual(simd_length(particles.velocity[0]), 2, accuracy: 1e-5)
            assertNextWord(particles, after: shape == "boxrandom" ? 9 : 6)
        }
    }

    func testFallbackDrawAxesSpeedAndBirthUFollowTheNativeLaunchOrder() {
        for shape in ["sphererandom", "boxrandom"] {
            var particles = ordinaryBirth(shape: shape, index: 1, distance: 0,
                                          directions: "2 3 5", speed: 2, speedMax: 6)
            let expected = WPEParityMT19937(seed: 7)
            for _ in 0 ..< 3 {
                _ = expected.next()
            } // Shape consumes the first three words, before birthU.
            let first = 2 * nativeLaunchUnit(expected) - 1
            let second = 2 * nativeLaunchUnit(expected) - 1
            let third = 2 * nativeLaunchUnit(expected) - 1
            // ASM 238077–082 packs sphere XYZ; 238a43–afa assigns box ZYX.
            let raw = shape == "boxrandom"
                ? SIMD3<Float>(third * 2, second * 3, first * 5)
                : SIMD3<Float>(first * 2, second * 3, third * 5)
            let rotated = SIMD3(-raw.y, raw.x, raw.z) // Independent exact Rz(π/2), not the product CP helper.
            let length = (rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z).squareRoot()
            let speed = 2 + 4 * nativeLaunchUnit(expected) // Word7, after fallback, before birthU.
            let expectedVelocity = rotated * (speed / length)
            let birthU = Float(expected.next() >> 8) * 0x1p-24 // Word8: separate scene+0x20/+0x24 range.
            _ = expected.next() // Word9: lifetime initializer.
            XCTAssertEqual(particles.position[0], SIMD3(12, 20, 0))
            for axis in 0 ..< 3 {
                XCTAssertEqual(particles.velocity[0][axis], expectedVelocity[axis], accuracy: 1e-5, "\(shape) axis\(axis)")
            }
            XCTAssertEqual(simd_length(particles.velocity[0]), speed, accuracy: 2e-6)
            XCTAssertEqual(particles.birthU[0], birthU)
            particles.advance(dt: 0.001)
            XCTAssertEqual(particles.position[0], SIMD3(12, 20, 0), "sampling must not revisit a live slot")
            for axis in 0 ..< 3 {
                XCTAssertEqual(particles.velocity[0][axis], expectedVelocity[axis], accuracy: 1e-5)
            }
            XCTAssertEqual(particles.birthU[0], birthU)
            XCTAssertEqual(particles.rng.next(), expected.next())
        }
    }

    func testBoxShapeDrawsZYXBeforeSpeedAndBirthUWithDistinctBoundsAndBasis() {
        let particles = ordinaryBirth(shape: "boxrandom", index: 1, minimum: "1 2 3", maximum: "5 8 11",
                                      directions: "2 3 5", speed: 2, speedMax: 6)
        let expected = WPEParityMT19937(seed: 7)
        let first = 2 * nativeLaunchUnit(expected) - 1
        let second = 2 * nativeLaunchUnit(expected) - 1
        let third = 2 * nativeLaunchUnit(expected) - 1
        // Native shape 2385a0/5d8/610 assigns the first word to Z, second to Y, third to X.
        let sample = SIMD3<Float>(third * 2, second * 3, first * 5)
        let offset = SIMD3<Float>(
            (sample.x > 0 ? 1 : -1) * (1 + abs(sample.x) * 4),
            (sample.y > 0 ? 1 : -1) * (2 + abs(sample.y) * 6),
            (sample.z > 0 ? 1 : -1) * (3 + abs(sample.z) * 8)
        )
        let rotated = SIMD3(-offset.y, offset.x, offset.z)
        let position = SIMD3<Float>(12, 20, 0) + rotated
        let length = (rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z).squareRoot()
        let speed = 2 + 4 * nativeLaunchUnit(expected) // Word4; nonzero shape cannot take fallback words.
        let velocity = rotated * (speed / length)
        let birthU = Float(expected.next() >> 8) * 0x1p-24 // Word5, independent [0,1) conversion.
        _ = expected.next() // Word6: lifetime.
        for axis in 0 ..< 3 {
            XCTAssertEqual(particles.position[0][axis], position[axis], accuracy: 1e-5)
            XCTAssertEqual(particles.velocity[0][axis], velocity[axis], accuracy: 1e-5)
        }
        XCTAssertEqual(simd_length(particles.velocity[0]), speed, accuracy: 2e-6)
        XCTAssertEqual(particles.birthU[0], birthU)
        XCTAssertEqual(particles.rng.next(), expected.next())
    }

    func testZeroInstanceCountDoesNotSampleShapeOrBirthU() {
        for shape in ["sphererandom", "boxrandom"] {
            let rng = WPEParityMT19937(seed: 7)
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount": 4, "emitter": [{"name": "\(shape)", "rate": 20,
                                      "directions": "2 3 5", "distancemax": 0, "speedmin": 2, "speedmax": 6}],
             "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}]}
            """), instanceOverride: .init(count: 0), rng: rng)
            particles.advance(dt: 0.1)
            XCTAssertEqual(particles.liveCount, 0)
            XCTAssertEqual(particles.capacity, 4, "count scales emission, not the maxcount slots")
            XCTAssertEqual(rng.next(), WPEParityMT19937(seed: 7).next(), "zero count leaves the shared stream at word1")
        }
    }

    /// count binds only rate and maxtoemitperperiod; the burst reads the raw instantaneous (2378a0.c:423-427).
    func testInstanceCountLeavesTheInstantaneousBurstUnscaled() {
        for (instantaneous, count) in [(1, 0.2), (4, 0.5)] {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": \(instantaneous),
                                      "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}
            """), instanceOverride: .init(count: count), rng: WPEParityMT19937())
            particles.advance(dt: 0.1)
            XCTAssertEqual(particles.liveCount, instantaneous, "count \(count)")
        }
    }

    func testAudioProcessingRateEmitterStaysSilentWithoutSpectrumAndEmitsWhenLoud() {
        func alive(_ frame: WPEParityParticleFrameContext) -> Int {
            var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
            {"maxcount":100,"emitter":[{"name":"boxrandom","rate":20,"audioprocessingmode":3}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
            """), rng: WPEParityMT19937(seed: 7))
            for _ in 0 ..< 60 {
                particles.advance(dt: 1.0 / 60, frame: frame)
            }
            return particles.liveCount
        }
        XCTAssertEqual(alive(WPEParityParticleFrameContext()), 0)
        let loud = SIMD16<Float>(repeating: 1)
        XCTAssertGreaterThan(alive(WPEParityParticleFrameContext(spectrumLeft: loud, spectrumRight: loud)), 0)
    }

    func testAudioProcessingKeysUseNativeDefaultsAndClampTheBandRange() {
        let config = WPEParityParticleConfig(json: ParityParticleTestSupport.json("""
        {"maxcount":1,"emitter":[{"name":"boxrandom","audioprocessingmode":1},
          {"name":"boxrandom","audioprocessingmode":2,"audioprocessingexponent":1,"audioprocessingbounds":"0 0.5",
           "audioprocessingfrequencystart":20,"audioprocessingfrequencyend":3}]}
        """), is3D: true, resolveChild: { _ in nil })
        let defaults = config.emitters[0].audio, authored = config.emitters[1].audio
        XCTAssertEqual(defaults, WPEParityParticleAudioResponse(mode: 1, exponent: 2, low: 0.8, high: 1, start: 0, end: 1))
        XCTAssertEqual(authored, WPEParityParticleAudioResponse(mode: 2, exponent: 1, low: 0, high: 0.5, start: 3, end: 15))

        var left = SIMD16<Float>.zero, right = SIMD16<Float>.zero
        left[1] = 0.9
        right[0] = 0.5
        // Band 1 = 0.9: (0.9 − 0.8)/0.2 = 0.5 → smoothstep 0.5 → 0.5² = 0.25; bands past `end` are ignored.
        XCTAssertEqual(defaults.level(left: left, right: right), 0.25, accuracy: 1e-6)
        left[2] = 1
        XCTAssertEqual(defaults.level(left: left, right: right), 0.25, accuracy: 1e-6)
        var average = defaults
        average.mode = 3
        // max((0.5 + 0.9)/2 = 0.7, 0.45) is below the lower bound.
        XCTAssertEqual(average.level(left: left, right: right), 0)
        XCTAssertEqual(authored.level(left: left, right: right), 0, "right channel, bands 3…15 are silent")
    }
}
