@testable import LiveWallpaperProWPE
import XCTest

/// Expectations come from an independent double-precision transcription of the reference algorithms.
final class ParityParticleNoiseTests: XCTestCase {
    typealias Noise = WPEParityParticleNoise

    func testSimplex1MatchesReference() {
        XCTAssertEqual(Noise.simplex1(0.3), 0.631_384_85, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex1(1.7), 0.181_228_44, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex1(-2.25), 0.316_289_01, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex1(3), 0)
        XCTAssertEqual(Noise.simplex1(-4), 0)
    }

    func testSimplex2MatchesReference() {
        XCTAssertEqual(Noise.simplex2(0.3, 0.7), -0.661_497_94, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex2(1.5, -2.25), 0.521_220_73, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex2(10.1, 3.3), -0.542_310_24, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex2(0, 0), 0)
        // The simplex vertex (1, 2) unskewed by G2·3.
        let g2: Float = 0.211_324_865
        XCTAssertEqual(Noise.simplex2(1 - 3 * g2, 2 - 3 * g2), 0, accuracy: 1e-5)
    }

    func testSimplex3MatchesReference() {
        XCTAssertEqual(Noise.simplex3(0.1, 0.2, 0.3), 0.635_890_37, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex3(1.5, -2.25, 3.75), -0.569_405_21, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex3(-0.7, 4.2, 0.9), -0.227_570_10, accuracy: 1e-5)
        XCTAssertEqual(Noise.simplex3(0, 0, 0), 0)
        XCTAssertEqual(Noise.simplex3(1, 2, 3), 0, accuracy: 1e-6)
    }

    func testMSVCRandSeedOne() {
        let crt = WPEParityCRTRandom()
        XCTAssertEqual(crt.next(), 41)
        XCTAssertEqual(crt.next(), 18467)
        XCTAssertEqual(crt.next(), 6334)
    }

    func testIntegerDrawIsMultiplyShiftOfOneRawOutput() {
        let rng = WPEParityMT19937(), mirror = WPEParityMT19937()
        // 3499211612·5 >> 32 = 4.
        XCTAssertEqual(rng.integer(0, 4), Int32((UInt64(mirror.next()) * 5) >> 32))
        XCTAssertEqual(rng.next(), mirror.next())
    }
}
