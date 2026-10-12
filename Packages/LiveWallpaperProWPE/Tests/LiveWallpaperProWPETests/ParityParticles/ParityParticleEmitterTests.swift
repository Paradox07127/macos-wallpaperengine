@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleEmitterTests: XCTestCase {
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
        _ = mirror.unit() // birth u
        _ = mirror.unitAboveZero() // phi
        _ = mirror.unit() // cos theta
        _ = mirror.unitAboveZero() // radius
        let x = 2 * mirror.unit() - 1
        let y = 2 * mirror.unit() - 1
        _ = mirror.unit() // z, masked by directions "1 1 0"
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
}
