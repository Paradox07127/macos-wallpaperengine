import Foundation
@testable import LiveWallpaperCore
import Testing

/// The cap is stored as a target frame rate and resolved per display. These pin
/// the resolution rules; the app-target suite covers how the video path consumes
/// them.
@Suite("FrameRateLimit target resolution")
struct FrameRateLimitTargetResolutionTests {
    /// Why the divisor form had to go: a 240 Hz panel's four divisors were
    /// 240/120/80/60, so 30 was unreachable there and the cheapest option still
    /// cost 60 — on the panel that needs the cap most.
    @Test("A 240 Hz panel reaches every target exactly")
    func targetsAreExactOnAMultipleOf60() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 240) == 60)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 240) == 30)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 240) == 15)
        #expect(FrameRateLimit.matchDisplay.frameRate(forRefreshRate: 240) == 240)
    }

    @Test("A 60 Hz panel is unchanged by the move to targets")
    func targetsOn60Hz() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 60) == 60)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 60) == 30)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 60) == 15)
        #expect(FrameRateLimit.matchDisplay.frameRate(forRefreshRate: 60) == 60)
    }

    /// 144 is not a multiple of 60. `CADisplayLink` only wakes on a divisor, so the
    /// target has to round *down* — asking for 60 and being handed 72 would be the
    /// opposite of a cap.
    @Test("A target never resolves above itself on an awkward panel")
    func targetsRoundDownNotUp() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 144) == 48)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 144) == 29)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 144) == 14)
    }

    @Test("A panel slower than the target cannot be sped up to it")
    func targetAboveTheSlowPanelYieldsThePanel() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 24) == 24)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 24) == 24)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 24) == 12)
    }

    @Test("A display that reports no refresh rate is treated as 60 Hz")
    func unknownRefreshRateFallsBackTo60() {
        #expect(FrameRateLimit.matchDisplay.frameRate(forRefreshRate: 0) == 60)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 0) == 30)
    }

    /// At 60 Hz and below, "match display" runs at the same rate as the 60 step;
    /// offering both would put two identical entries in one menu.
    @Test("Steps that resolve to the same rate are offered once")
    func availableCasesDropDuplicates() {
        #expect(FrameRateLimit.availableCases(forRefreshRate: 60) == [.fps15, .fps30, .fps60])
        #expect(
            FrameRateLimit.availableCases(forRefreshRate: 240)
                == [.fps15, .fps30, .fps60, .matchDisplay]
        )
    }

    /// Video re-times through `AVVideoComposition` rather than vsync, so it holds an
    /// exact 60 where a scene has to fall to 48 — but it is still bounded by the
    /// file, and a target above the file is not a cap at all.
    @Test("Video is bounded by the file and by the panel, not quantised by either")
    func videoClampsToTheSourceAndPanel() {
        #expect(FrameRateLimit.fps60.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 120) == 60)
        #expect(FrameRateLimit.fps60.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30) == 30)
        #expect(FrameRateLimit.fps15.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30) == 15)
        #expect(FrameRateLimit.matchDisplay.videoFrameRate(forRefreshRate: 60, sourceFrameRate: 120) == 60)
    }

    /// The divisor form divided the *source* once the source was slower, so a 30 fps
    /// file at the lowest step was re-timed to 8. A target is a floor as well as a
    /// ceiling: it never lands below what the user asked for.
    @Test("A slow source is never driven below the chosen target")
    func slowSourceIsNotDividedBelowTheTarget() {
        let steps = FrameRateLimit.allCases.map {
            $0.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30)
        }
        #expect(steps == [15, 30, 30, 30])
    }
}

@Suite("FrameRateLimit decoding")
struct FrameRateLimitDecodingTests {
    private func decode(_ raw: Int) throws -> FrameRateLimit {
        try JSONDecoder().decode(FrameRateLimit.self, from: JSONEncoder().encode(raw))
    }

    @Test("Current raw values round-trip")
    func currentValuesRoundTrip() throws {
        for limit in FrameRateLimit.allCases {
            let data = try JSONEncoder().encode(limit)
            #expect(try JSONDecoder().decode(FrameRateLimit.self, from: data) == limit)
        }
    }

    /// The absolute era wrote the fps itself. 24 is the only one without a case: it
    /// measurably snapped to 30 on a 60 Hz panel, so it never bought anything.
    @Test("Absolute-era raw values keep their rate")
    func absoluteEraValues() throws {
        #expect(try decode(0) == .matchDisplay)
        #expect(try decode(60) == .fps60)
        #expect(try decode(30) == .fps30)
        #expect(try decode(24) == .fps30)
        #expect(try decode(15) == .fps15)
    }

    /// The divisor era wrote 1…4. `full` has to land on `matchDisplay`, not `fps60`:
    /// mapping it to 60 would drop every 120/240 Hz display to 60 on the first launch
    /// after this change, which is a setting the user never touched.
    @Test("Divisor-era raw values do not lower a high-refresh display on their own")
    func divisorEraValues() throws {
        #expect(try decode(1) == .matchDisplay)
        #expect(try decode(2) == .fps30)
        #expect(try decode(3) == .fps15)
        #expect(try decode(4) == .fps15)
    }

    @Test("An unknown raw value falls back to the panel's own rate")
    func unknownValue() throws {
        #expect(try decode(999) == .matchDisplay)
    }
}
