import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("FrameRateLimit target resolution")
struct FrameRateLimitTargetResolutionTests {
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

    /// The runtime handles fractional cadence; settings retain the requested rate.
    @Test("A target never resolves above itself on an awkward panel")
    func targetsAreNotQuantized() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 144) == 60)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 144) == 30)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 144) == 15)
        #expect(FrameRateLimit.matchDisplay.frameRate(forRefreshRate: 144) == 144)
    }

    @Test("A panel slower than the target cannot be sped up to it")
    func targetAboveTheSlowPanelYieldsThePanel() {
        #expect(FrameRateLimit.fps60.frameRate(forRefreshRate: 24) == 24)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 24) == 24)
        #expect(FrameRateLimit.fps15.frameRate(forRefreshRate: 24) == 15)
    }

    @Test("A display that reports no refresh rate is treated as 60 Hz")
    func unknownRefreshRateFallsBackTo60() {
        #expect(FrameRateLimit.matchDisplay.frameRate(forRefreshRate: 0) == 60)
        #expect(FrameRateLimit.fps30.frameRate(forRefreshRate: 0) == 30)
    }

    @Test("Presets fit the configured display rate and Max stays distinct")
    func presetsKeepTheirIdentity() {
        let presets: [FrameRateLimit] = [.fps15, .fps24, .fps30, .fps45, .fps60, .fps120, .matchDisplay]
        #expect(FrameRateLimit.availableCases(forRefreshRate: 60) == presets.filter { $0 != .fps120 })
        #expect(FrameRateLimit.availableCases(forRefreshRate: 240) == presets)
        #expect(FrameRateLimit.fps120.title != FrameRateLimit.matchDisplay.title)
    }

    /// Landing a drag on the top step must not overwrite a saved `.matchDisplay`, or a
    /// later 120 Hz display would sit capped at 60 for a value the user never touched.
    @Test("Same-rate steps at 60 Hz are recognized; distinct rates and higher panels are not")
    func resolvesToSameRate() {
        #expect(FrameRateLimit.matchDisplay.resolvesToSameRate(as: .fps60, forRefreshRate: 60))
        #expect(FrameRateLimit.fps60.resolvesToSameRate(as: .matchDisplay, forRefreshRate: 60))
        #expect(FrameRateLimit.matchDisplay.resolvesToSameRate(as: .fps60, forRefreshRate: 120) == false)
        #expect(FrameRateLimit.fps30.resolvesToSameRate(as: .fps60, forRefreshRate: 60) == false)
    }

    /// Video remains bounded by the source file as well as the display.
    @Test("Video is bounded by the file and by the panel, not quantised by either")
    func videoClampsToTheSourceAndPanel() {
        #expect(FrameRateLimit.fps60.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 120) == 60)
        #expect(FrameRateLimit.fps60.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30) == 30)
        #expect(FrameRateLimit.fps15.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30) == 15)
        #expect(FrameRateLimit.matchDisplay.videoFrameRate(forRefreshRate: 60, sourceFrameRate: 120) == 60)
    }

    /// A target is a floor as well as a ceiling: it never lands below what the user
    /// asked for, even when the source is slower.
    @Test("A slow source is never driven below the chosen target")
    func slowSourceIsNotDividedBelowTheTarget() {
        let steps = FrameRateLimit.allCases.map {
            $0.videoFrameRate(forRefreshRate: 144, sourceFrameRate: 30)
        }
        #expect(steps == [15, 24, 30, 30, 30, 30, 30])
    }
}

@Suite("FrameRateLimit decoding")
struct FrameRateLimitDecodingTests {
    private func decode(_ raw: Int) throws -> FrameRateLimit {
        try JSONDecoder().decode(FrameRateLimit.self, from: JSONEncoder().encode(raw))
    }

    @Test("Current raw values round-trip")
    func currentValuesRoundTrip() throws {
        for limit in FrameRateLimit.allCases + [1, 2, 3, 4, 23, 37, 144, 999, 1000].compactMap({ FrameRateLimit(rawValue: $0) }) {
            let data = try JSONEncoder().encode(limit)
            #expect(try JSONDecoder().decode(FrameRateLimit.self, from: data) == limit)
        }
    }

    @Test("Absolute-era raw values keep their rate")
    func absoluteEraValues() throws {
        #expect(try decode(0) == .matchDisplay)
        #expect(try decode(60) == .fps60)
        #expect(try decode(30) == .fps30)
        #expect(try decode(24) == .fps24)
        #expect(try decode(15) == .fps15)
    }

    /// Legacy `full` must decode to `matchDisplay`, not `fps60`: mapping it to 60 would
    /// drop every 120/240 Hz display to 60 on the first launch after the change.
    @Test("Divisor-era raw values do not lower a high-refresh display on their own")
    func divisorEraValues() throws {
        #expect(try decode(1) == .matchDisplay)
        #expect(try decode(2) == .fps30)
        #expect(try decode(3) == .fps15)
        #expect(try decode(4) == .fps15)
    }

    @Test("An unknown raw value falls back to the panel's own rate")
    func unknownValue() throws {
        #expect(try decode(-1) == .matchDisplay)
    }
}
