@testable import LiveWallpaperProWPE
import XCTest

final class ParityUniformClockTests: XCTestCase {
    func testStoredRateScalesTheClampedStep() {
        var clock = WPEParityClock()
        XCTAssertEqual(clock.normalizedRate, 1)
        clock.setRate(percent: 1250)
        XCTAssertTrue(clock.advance(elapsed: 0.1, paused: false))
        XCTAssertEqual(clock.frametime, 0.25)
        XCTAssertTrue(clock.advance(elapsed: 0.04, paused: false))
        XCTAssertEqual(clock.normalizedRate, 12.5, "an update without a settings write keeps the normalized rate")
        clock.setRate(percent: 0)
        XCTAssertTrue(clock.advance(elapsed: 0.0001, paused: false))
        XCTAssertEqual(clock.frametime, 0.0001)
    }

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

    func testHeldPausePreservesPublishedIntervalsUntilNextUpdate() {
        var clock = WPEParityClock()
        XCTAssertEqual(clock.previousFrametime.bitPattern, 0x3D08_8889)
        clock.advance(elapsed: 0.02, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.previousFrametime, 0)
        clock.advance(elapsed: 0.03, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.previousFrametime, Float(0.02))
        var held: (Float, Float, Double) = (clock.frametime, clock.previousFrametime, clock.time)
        while clock.advance(elapsed: 1.0 / 60, ratePercent: 100, paused: true) {
            held = (clock.frametime, clock.previousFrametime, clock.time)
        }
        XCTAssertEqual(clock.frametime, held.0)
        XCTAssertEqual(clock.previousFrametime, held.1)
        XCTAssertEqual(clock.time, held.2)
        XCTAssertFalse(clock.advance(elapsed: 1.0 / 60, ratePercent: 100, paused: true))
        XCTAssertEqual(clock.frametime, held.0)
        XCTAssertEqual(clock.previousFrametime, held.1)
        XCTAssertTrue(clock.advance(elapsed: 0.1, ratePercent: 100, paused: false))
        XCTAssertEqual(clock.previousFrametime, held.0)
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

    func testTimeWrapsOnlyWhenPublishedFloatExceeds432000() {
        var clock = WPEParityClock()
        for _ in 0 ..< 1_728_000 {
            clock.advance(elapsed: 1, ratePercent: 100, paused: false)
        }
        XCTAssertEqual(clock.time, 432_000)
        XCTAssertEqual(clock.timeUniform, 432_000)
        // The stored sum has exceeded five days, but its published float still equals the boundary.
        clock.advance(elapsed: 0.01, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.time, 432_000)
        XCTAssertEqual(clock.timeUniform, 432_000)
        clock.advance(elapsed: 0.01, ratePercent: 100, paused: false)
        XCTAssertEqual(clock.time, 0)
        XCTAssertEqual(clock.timeUniform, 0)
        XCTAssertEqual(clock.frametime, Float(0.01), "wrapping the shader clock must not reverse animation dt")
    }

    func testTimeAccumulatesBinary64AndPublishesBinary32() {
        var clock = WPEParityClock()
        for _ in 0 ..< 10 {
            clock.advance(elapsed: 0.1, ratePercent: 100, paused: false)
        }
        // Original instructions widen each step, addsd/store at +0x148, then cvtpd2ps at +0x140.
        XCTAssertEqual(clock.timeUniform.bitPattern, 0x3F80_0000)
        XCTAssertEqual(clock.time, 1)
    }

    func testSmallStepsKeepAdvancingWhenPublishedFloatCannotRepresentEachStep() {
        var clock = WPEParityClock()
        for _ in 0 ..< 524_288 {
            clock.advance(elapsed: 0.25, ratePercent: 100, paused: false)
        }
        XCTAssertEqual(clock.timeUniform, 131_072)
        for _ in 0 ..< 1000 {
            clock.advance(elapsed: 0.001, ratePercent: 100, paused: false)
        }
        // A float accumulator stalls here: its ULP is 0.015625, larger than this frame's step.
        XCTAssertEqual(clock.timeUniform, 131_073)
        XCTAssertEqual(clock.time, 131_073)
    }

    func testDaytimeIncludesMilliseconds() {
        let value = WPEParityClock.daytime(hour: 12, minute: 30, second: 15, millisecond: 500)
        XCTAssertEqual(value, Float(0.5 + 30.0 / 1440 + 15.5 / 86400), accuracy: 1e-7)
        XCTAssertNotEqual(value, WPEParityClock.daytime(hour: 12, minute: 30, second: 15, millisecond: 0))
    }
}
