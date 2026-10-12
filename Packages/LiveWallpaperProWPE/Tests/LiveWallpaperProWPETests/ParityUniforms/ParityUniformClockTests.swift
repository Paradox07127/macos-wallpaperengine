@testable import LiveWallpaperProWPE
import XCTest

final class ParityUniformClockTests: XCTestCase {
    func testStepIsClampedAtBothEnds() {
        var clock = WPEParityClock()
        clock.advance(elapsed: 0, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.frametime, 1e-4)
        clock.advance(elapsed: 10, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.frametime, 0.25)
        clock.advance(elapsed: 0.1, ratePercent: 1000, paused: false)
        XCTAssertEqual(clock.frametime, 0.25)
        clock.advance(elapsed: 1e-4, ratePercent: 10, paused: false)
        XCTAssertEqual(clock.frametime, 1e-4)
    }

    func testRateBelowTenPercentFloorsToOneTenth() {
        XCTAssertEqual(WPEParityClock.rate(percent: 5), 0.1)
        XCTAssertEqual(WPEParityClock.rate(percent: 0), 0.1)
        XCTAssertEqual(WPEParityClock.rate(percent: 50), 0.5)
        var clock = WPEParityClock()
        clock.advance(elapsed: 0.1, ratePercent: 5, paused: false)
        XCTAssertEqual(clock.frametime, 0.01, accuracy: 1e-7)
    }

    func testPauseRampsDownThenHoldsAndRampsBack() {
        var clock = WPEParityClock()
        let step = 1.0 / 60
        XCTAssertTrue(clock.advance(elapsed: step, ratePercent: 100, paused: true))
        XCTAssertEqual(clock.pauseRamp, 0.9, accuracy: 1e-6)
        XCTAssertEqual(clock.frametime, 0.9 * Float(step), accuracy: 1e-7)
        var frames = 1
        while clock.advance(elapsed: step, ratePercent: 100, paused: true) {
            frames += 1
            XCTAssertLessThan(frames, 1000)
        }
        XCTAssertEqual(clock.pauseRamp, 0)
        let held = clock.time
        XCTAssertFalse(clock.advance(elapsed: step, ratePercent: 100, paused: true))
        XCTAssertEqual(clock.time, held)
        XCTAssertTrue(clock.advance(elapsed: step, ratePercent: 100, paused: false))
        XCTAssertEqual(clock.pauseRamp, 0.1, accuracy: 1e-6)
        XCTAssertEqual(clock.frametime, max(1e-4, 0.1 * Float(step)), accuracy: 1e-7)
    }

    func testRampSnapsToTargetWithinOneHundredth() {
        var clock = WPEParityClock()
        while clock.advance(elapsed: 0.1, ratePercent: 100, paused: true) {}
        XCTAssertEqual(clock.pauseRamp, 0)
        // r += (1 - r) * 0.6 gives 0.6 ... 0.98976, 0.995904; |1 - 0.995904| < 0.01 snaps on the seventh step.
        for _ in 0 ..< 6 {
            clock.advance(elapsed: 0.1, ratePercent: 100, paused: false)
        }
        XCTAssertEqual(clock.pauseRamp, 0.995904, accuracy: 1e-5)
        clock.advance(elapsed: 0.1, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.pauseRamp, 1)
    }

    func testTimeWrapsToZeroAbove432000() {
        var clock = WPEParityClock()
        var previous = 0.0
        for _ in 0 ..< 2_000_000 {
            clock.advance(elapsed: 1, ratePercent: 100, paused: false)
            if clock.time < previous {
                break
            }
            previous = clock.time
        }
        XCTAssertEqual(clock.time, 0)
        XCTAssertEqual(previous, 432_000)
    }

    func testDoubleAccumulationKeepsSubMillisecondPrecision() {
        var clock = WPEParityClock()
        let steps = 1_000_000
        for _ in 0 ..< steps {
            clock.advance(elapsed: 1.0 / 60, ratePercent: 100, paused: false)
        }
        let expected = Double(steps) * Double(Float(1.0 / 60))
        XCTAssertEqual(clock.time, expected, accuracy: 1e-4)
    }

    func testDaytimeIncludesMilliseconds() {
        let value = WPEParityClock.daytime(hour: 12, minute: 30, second: 15, millisecond: 500)
        XCTAssertEqual(value, Float(0.5 + 30.0 / 1440 + 15.5 / 86400), accuracy: 1e-7)
        XCTAssertNotEqual(value, WPEParityClock.daytime(hour: 12, minute: 30, second: 15, millisecond: 0))
    }
}
