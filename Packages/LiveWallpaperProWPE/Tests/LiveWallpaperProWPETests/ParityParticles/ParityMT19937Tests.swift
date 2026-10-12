@testable import LiveWallpaperProWPE
import XCTest

final class ParityMT19937Tests: XCTestCase {
    func testSeed5489MatchesStdMt19937() {
        let rng = WPEParityMT19937()
        XCTAssertEqual(rng.next(), 3_499_211_612)
        XCTAssertEqual(rng.next(), 581_869_302)
        XCTAssertEqual(rng.next(), 3_890_346_734)
        XCTAssertEqual(rng.next(), 3_586_334_585)
        XCTAssertEqual(rng.next(), 545_404_204)
    }

    func testTenThousandthOutputMatchesStandard() {
        let rng = WPEParityMT19937(seed: 5489)
        var value: UInt32 = 0
        for _ in 0 ..< 10000 {
            value = rng.next()
        }
        XCTAssertEqual(value, 4_123_659_995)
    }

    func testUnitDrawUsesTopTwentyFourBits() {
        let rng = WPEParityMT19937()
        let expected = Float(3_499_211_612 >> 8) / 16_777_216
        XCTAssertEqual(rng.unit(), expected)
        XCTAssertEqual(expected, 0.814_723_6, accuracy: 1e-6)
        let second = Float(581_869_302 >> 8) / 16_777_216
        XCTAssertEqual(rng.unitAboveZero(), 1e-5 + (1 - 1e-5) * second)
    }

    func testReseedRestartsTheStream() {
        let rng = WPEParityMT19937()
        _ = rng.next()
        rng.reseed(5489)
        XCTAssertEqual(rng.next(), 3_499_211_612)
    }
}
