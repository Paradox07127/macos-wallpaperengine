import Foundation
import Testing
@testable import LiveWallpaperProWPE

/// Contract tests for the official timeline Mirror mode: forward for the
/// configured duration, reverse for the same duration, then repeat.
@Suite("WPE scene numeric animation Mirror mode")
struct WPESceneNumericAnimationMirrorTests {
    private func linearMirror(
        length: Double = 10,
        wrapLoop: Bool = false
    ) -> WPESceneNumericAnimation {
        WPESceneNumericAnimation(
            tracks: [[
                WPESceneAnimationKeyframe(frame: 0, value: 0),
                WPESceneAnimationKeyframe(frame: length, value: 1)
            ]],
            fps: 10,
            length: length,
            mode: "mirror",
            wrapLoop: wrapLoop
        )
    }

    private func scalar(_ animation: WPESceneNumericAnimation, at time: Double) -> Double {
        animation.values(at: time, fallbacks: [-1])[0]
    }

    @Test("Mirror retains both turn-around endpoints")
    func endpoints() {
        let animation = linearMirror()

        #expect(scalar(animation, at: 0) == 0)
        #expect(scalar(animation, at: 1) == 1)
        #expect(scalar(animation, at: 2) == 0)
        #expect(scalar(animation, at: 3) == 1)
        #expect(scalar(animation, at: 4) == 0)
    }

    @Test("Mirror reverses at the same speed as its forward traversal")
    func forwardThenReverseAtEqualSpeed() {
        let animation = linearMirror()

        for forwardTime in [0.125, 0.25, 0.5, 0.75, 0.875] {
            let reverseTime = 2 - forwardTime
            #expect(abs(scalar(animation, at: forwardTime) - scalar(animation, at: reverseTime)) < 1e-12)
        }
    }

    @Test("Mirror takes precedence over wrap-loop at runtime")
    func mirrorWithWrapLoopStillReverses() {
        let animation = linearMirror(wrapLoop: true)

        #expect(abs(scalar(animation, at: 1.25) - 0.75) < 1e-12)
        #expect(abs(scalar(animation, at: 1.75) - 0.25) < 1e-12)
    }

    @Test("Negative time clamps to the first frame")
    func negativeTime() {
        let animation = linearMirror()

        #expect(scalar(animation, at: -0.001) == 0)
        #expect(scalar(animation, at: -10_000) == 0)
    }

    @Test("A zero-length single-frame Mirror animation is stable")
    func zeroLengthSingleFrame() {
        let animation = WPESceneNumericAnimation(
            tracks: [[WPESceneAnimationKeyframe(frame: 0, value: 42)]],
            fps: 30,
            length: 0,
            mode: "mirror",
            wrapLoop: false
        )

        for time in [-10.0, 0, 0.5, 10, 1_000_000] {
            #expect(scalar(animation, at: time) == 42)
        }
    }
}

/// Tracks are positional — c0 is x, c1 is y. A c0 that fails to parse (null,
/// not an array, no valid keyframes) used to be compactMapped away, promoting
/// c1 into slot 0: the y animation drove x. A broken track must instead hold
/// its position and sample its fallback.
@Suite("Track positional alignment")
struct WPESceneAnimationTrackAlignmentTests {
    private func parse(_ text: String) -> WPESceneAnimatedValue? {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return object.flatMap { WPEValueParser.animatedValue($0) }
    }

    @Test("A null c0 does not shift c1 into the x slot")
    func nullTrackHoldsItsPosition() throws {
        let animated = try #require(parse(#"""
        {
            "value": "7 8 9",
            "animation": {
                "c0": null,
                "c1": [
                    {"frame": 0, "value": 100},
                    {"frame": 10, "value": 100}
                ]
            }
        }
        """#))
        let values = animated.animation.values(at: 0, fallbacks: [7, 8, 9])
        #expect(values[0] == 7, "x samples its fallback, not c1's keyframes")
        #expect(values[1] == 100, "y is driven by c1")
    }

    @Test("A gap in the track indices is filled, not collapsed")
    func sparseIndicesKeepPositions() throws {
        let animated = try #require(parse(#"""
        {
            "value": "1 2 3",
            "animation": {
                "c2": [
                    {"frame": 0, "value": 42},
                    {"frame": 10, "value": 42}
                ]
            }
        }
        """#))
        let values = animated.animation.values(at: 0, fallbacks: [1, 2, 3])
        #expect(values[0] == 1)
        #expect(values[1] == 2)
        #expect(values[2] == 42, "c2 drives z from slot 2, not slot 0")
    }
}
