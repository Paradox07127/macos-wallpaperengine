@testable import LiveWallpaperProWPE
import Testing

/// One case per ITextureAnimation method body (1401fa2a0-1401fa4a0) and the image update step (14015fdd0).
struct WPEParityTextureAnimationTests {
    private static let shared = (frame: 2, time: Float(0.25))
    private static let durations: [Float] = [0.5, 1, 0.25]

    @Test func startsJoinedAndPlayingAtRateOne() {
        let animation = WPEParityTextureAnimation()
        #expect(!animation.individual && animation.playing && animation.rate == 1)
        #expect(animation.frame == 0 && animation.time == 0)
        #expect(animation.isPlaying)
    }

    @Test func playOnlySetsPlaying() {
        var animation = WPEParityTextureAnimation()
        animation.stop()
        animation.play()
        #expect(animation.playing && animation.individual)
    }

    @Test func pauseCopiesTheSharedFrameOnlyWhenJoined() {
        var joined = WPEParityTextureAnimation()
        joined.pause(shared: Self.shared)
        #expect(joined.frame == 2 && joined.time == 0.25 && joined.individual && !joined.playing)

        var own = WPEParityTextureAnimation()
        own.setFrame(1)
        own.pause(shared: Self.shared)
        #expect(own.frame == 1 && own.time == 0 && !own.playing)
    }

    @Test func stopRewindsAndHolds() {
        var animation = WPEParityTextureAnimation()
        animation.setFrame(2)
        animation.step(dt: 0.1, durations: Self.durations)
        animation.stop()
        #expect(animation.frame == 0 && animation.time == 0 && animation.individual && !animation.playing)
    }

    @Test func isPlayingIsFalseOnlyWhenIndividualAndNotPlaying() {
        var animation = WPEParityTextureAnimation()
        animation.pause(shared: Self.shared)
        #expect(!animation.isPlaying)
        animation.join()
        #expect(animation.isPlaying)
    }

    @Test func setFrameDetachesAJoinedAnimationAndKeepsAPausedOneHeld() {
        var joined = WPEParityTextureAnimation()
        joined.setFrame(30)
        #expect(joined.frame == 30 && joined.time == 0 && joined.individual && joined.playing)

        var held = WPEParityTextureAnimation()
        held.stop()
        held.setFrame(1)
        #expect(held.frame == 1 && !held.playing)
    }

    @Test func getFrameIsTheSharedFrameWhileJoined() {
        var animation = WPEParityTextureAnimation()
        #expect(animation.frame(shared: 2) == 2)
        animation.setFrame(1)
        #expect(animation.frame(shared: 2) == 1)
    }

    @Test func joinReturnsToTheSharedClock() {
        var animation = WPEParityTextureAnimation()
        animation.setFrame(1)
        animation.join()
        #expect(!animation.individual && animation.frame(shared: 2) == 2)
    }

    @Test func aRateOtherThanOneDetachesAtTheSharedFrameAndKeepsPlaying() {
        var same = WPEParityTextureAnimation()
        same.setRate(1, shared: Self.shared)
        #expect(!same.individual)

        var fast = WPEParityTextureAnimation()
        fast.setRate(9, shared: Self.shared)
        #expect(fast.rate == 9 && fast.individual && fast.playing && fast.frame == 2 && fast.time == 0.25)
    }

    @Test func frameCountAndDurationComeFromTheSheet() {
        var animation = WPEParityTextureAnimation()
        #expect(animation.perform(.frameCount, value: 0, shared: Self.shared, durations: Self.durations) == 3)
        #expect(animation.perform(.duration, value: 0, shared: Self.shared, durations: Self.durations) == 1.75)
    }

    @Test func stepAdvancesAtMostOneFrameAndClampsIntoTheNext() {
        var animation = WPEParityTextureAnimation()
        animation.step(dt: 0.4, durations: Self.durations)
        #expect(animation.frame == 0 && animation.time == 0, "a joined animation follows the shared clock")

        animation.setFrame(0)
        animation.step(dt: 0.4, durations: Self.durations)
        #expect(animation.frame == 0 && animation.time == 0.4)
        animation.step(dt: 2, durations: Self.durations)
        #expect(animation.frame == 1 && animation.time == 1, "one frame per update, time clamped to frame 1")
        animation.setFrame(2)
        animation.step(dt: 0.25, durations: Self.durations)
        #expect(animation.frame == 0 && animation.time == 0, "wraps to frame 0")
    }

    @Test func rateScalesAndNegativeStepsBackwards() {
        var animation = WPEParityTextureAnimation()
        animation.setRate(-1, shared: (frame: 0, time: 0.125))
        animation.step(dt: 0.25, durations: Self.durations)
        #expect(animation.frame == 2 && animation.time == 0.125, "frame -1 wraps to the last frame")

        var held = WPEParityTextureAnimation()
        held.pause(shared: (frame: 1, time: 0.5))
        held.step(dt: 1, durations: Self.durations)
        #expect(held.frame == 1 && held.time == 0.5, "a paused animation holds")
    }
}
