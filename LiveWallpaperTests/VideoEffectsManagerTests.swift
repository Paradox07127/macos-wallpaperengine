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
