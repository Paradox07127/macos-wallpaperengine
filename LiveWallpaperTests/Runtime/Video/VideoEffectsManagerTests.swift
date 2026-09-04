import Foundation
@testable import LiveWallpaper
import Testing

@Suite("VideoEffectsManager: blur radius clamp")
struct VideoEffectsManagerTests {
    @Test("Blur radius is capped at the UI slider's max (30)")
    func clampsAboveMax() {
        #expect(VideoEffectsManager.clampedBlurRadius(31) == 30)
        #expect(VideoEffectsManager.clampedBlurRadius(1_000_000) == 30)
        #expect(VideoEffectsManager.clampedBlurRadius(.infinity) == 0)
    }

    @Test("Non-finite or non-positive blur radius falls back to 0 (off)")
    func nonFiniteOrNonPositiveFallsBackToZero() {
        #expect(VideoEffectsManager.clampedBlurRadius(.nan) == 0)
        #expect(VideoEffectsManager.clampedBlurRadius(-5) == 0)
        #expect(VideoEffectsManager.clampedBlurRadius(0) == 0)
    }

    @Test("In-range blur radius passes through unchanged")
    func inRangePassesThrough() {
        #expect(VideoEffectsManager.clampedBlurRadius(12.5) == 12.5)
        #expect(VideoEffectsManager.clampedBlurRadius(30) == 30)
    }
}

@Suite("VideoEffectsManager: autoTimeTint hour cache", .serialized)
struct VideoEffectsManagerWarmthCacheTests {
    private static let calendar = Calendar(identifier: .gregorian)

    private static func date(hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    @Test("Repeated calls within the same hour recompute only once")
    func sameHourRecomputesOnce() {
        defer { VideoEffectsManager.currentDateProvider = Date.init }
        VideoEffectsManager.resetWarmthCacheForTesting()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10) }
        let first = VideoEffectsManager.warmthForCurrentHour()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10, minute: 30) }
        let second = VideoEffectsManager.warmthForCurrentHour()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10, minute: 59, second: 59) }
        let third = VideoEffectsManager.warmthForCurrentHour()

        #expect(first == 6500)
        #expect(second == 6500)
        #expect(third == 6500)
        #expect(VideoEffectsManager.warmthRecomputeCount == 1)
    }

    @Test("Crossing an hour boundary triggers a fresh recompute")
    func crossingHourBoundaryRecomputes() {
        defer { VideoEffectsManager.currentDateProvider = Date.init }
        VideoEffectsManager.resetWarmthCacheForTesting()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 8, minute: 59) }
        let beforeNine = VideoEffectsManager.warmthForCurrentHour()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 9, second: 1) }
        let afterNine = VideoEffectsManager.warmthForCurrentHour()

        #expect(beforeNine == 5500)
        #expect(afterNine == 6500)
        #expect(VideoEffectsManager.warmthRecomputeCount == 2)
    }

    @Test("Warmth value matches the original per-hour table across all buckets")
    func warmthValuesMatchTable() {
        defer { VideoEffectsManager.currentDateProvider = Date.init }
        VideoEffectsManager.resetWarmthCacheForTesting()

        // Ascending hours so the injected clock never rewinds relative to the cache.
        let expectations: [(hour: Int, warmth: Double)] = [
            (0, 3000), (5, 3000),
            (6, 5500), (8, 5500),
            (9, 6500), (16, 6500),
            (17, 4500), (19, 4500),
            (20, 3500), (22, 3500),
            (23, 3000)
        ]

        for expectation in expectations {
            VideoEffectsManager.currentDateProvider = { Self.date(hour: expectation.hour) }
            #expect(
                VideoEffectsManager.warmthForCurrentHour() == expectation.warmth,
                "hour \(expectation.hour)"
            )
        }
    }

    @Test("A time zone change invalidates the cache even though the clock moved forward")
    func timeZoneChangeInvalidates() {
        defer { VideoEffectsManager.currentDateProvider = Date.init }
        VideoEffectsManager.resetWarmthCacheForTesting()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10) }
        let before = VideoEffectsManager.warmthForCurrentHour()

        // The clock keeps moving forward, so both bounds still hold; only the
        // local hour changed underneath, which is what the observer is for.
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10, minute: 30) }
        let after = VideoEffectsManager.warmthForCurrentHour()

        #expect(before == 6500)
        #expect(after == 6500)
        #expect(VideoEffectsManager.warmthRecomputeCount == 2)
    }

    @Test("A backwards clock jump invalidates the cache instead of serving the stale hour")
    func clockRewindInvalidates() {
        defer { VideoEffectsManager.currentDateProvider = Date.init }
        VideoEffectsManager.resetWarmthCacheForTesting()

        VideoEffectsManager.currentDateProvider = { Self.date(hour: 18) }
        let evening = VideoEffectsManager.warmthForCurrentHour()

        // NTP correction or a westward timezone change: the expiry is still in
        // the future, so an upper-bound-only check would keep returning 4500.
        VideoEffectsManager.currentDateProvider = { Self.date(hour: 10) }
        let rewound = VideoEffectsManager.warmthForCurrentHour()

        #expect(evening == 4500)
        #expect(rewound == 6500)
        #expect(VideoEffectsManager.warmthRecomputeCount == 2)
    }
}
