import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEParityPropertyAnimationTests {
    @Test(arguments: [Float(0.725), Float(30)])
    func linearKeysInterpolateCachedIntegerFrames(fps: Float) throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(1, 2), key(3, 10)]],
                               fps: Double(fps), length: 4), valueType: .float
        ))
        animation.advance(dt: 0.25 / fps)
        try expectValue(animation, [0.5])
        animation.advance(dt: 1 / fps)
        try expectValue(animation, [3])
        animation.advance(dt: 1 / fps)
        try expectValue(animation, [7])
    }

    @Test func bezierUsesIntegerSamplesAndImplicitlyEnabledTangents() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[
                key(0, 1, front: ["x": 1.4, "y": 5]),
                key(4, 3, back: ["enabled": true, "x": -0.7, "y": -2]),
            ]], fps: 30, length: 6), valueType: .float
        ))
        animation.advance(dt: 1.25 / 30)
        let expected = bezier(frame: 1) * 0.75 + bezier(frame: 2) * 0.25
        try expectValue(animation, [expected], tolerance: 0.00001)
        #expect(abs(expected - bezier(frame: 1.25)) > 0.01)
    }

    @Test func stepHoldsPreviousValueUntilTheKeyAndThenInterpolatesSamples() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 2), key(2, 10, step: true), key(4, 10)]],
                               fps: 4, length: 5), valueType: .float
        ))
        animation.advance(dt: 0.25)
        try expectValue(animation, [2])
        animation.advance(dt: 0.0625)
        try expectValue(animation, [4])
        animation.advance(dt: 0.1875)
        try expectValue(animation, [10])
    }

    @Test func wraploopAppendsTheFirstValueAtLength() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 2), key(2, 10)]], fps: 4, length: 4,
                               options: ["wraploop": true]), valueType: .float
        ))
        animation.advance(dt: 0.875)
        try expectValue(animation, [4])
        animation.advance(dt: 0.125)
        try expectValue(animation, [2])
    }

    @Test func wraploopMirrorsTheFirstFrontTangentIntoTheClosingBackTangent() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 1, front: ["x": 1.4, "y": 5]), key(2, 3)]],
                               fps: 4, length: 4, options: ["wraploop": true]), valueType: .float
        ))
        animation.advance(dt: 0.75)
        let expected = curve(frame: 3, x: [2, 2, 2.6, 4], y: [3, 3, -4, 1])
        try expectValue(animation, [expected], tolerance: 0.00001)
    }

    @Test func mirrorReversesAtBothEndsAndAcrossSeveralDurations() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["mode": "mirror"]), valueType: .float
        ))
        animation.advance(dt: 1.25)
        #expect(animation.time == 0.75)
        #expect(animation.direction == -1)
        try expectValue(animation, [3])
        animation.advance(dt: 1)
        #expect(animation.time == 0.25)
        #expect(animation.direction == 1)
        try expectValue(animation, [1])
        animation.advance(dt: 3)
        #expect(animation.time == 0.75)
        #expect(animation.direction == -1)
    }

    /// WPE divides by a stored 1/fps for the frame and the fraction; these are its values at dt 1/60, including
    /// the one-frame jumps at k = 6 and 10 and the last-bit differences from t·fps at k = 5 and 9.
    @Test func samplingDividesByTheStoredFrameDurationAsWPEDoes() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 1), key(30, 0)]], fps: 30, length: 30), valueType: .float
        ))
        var values: [Float] = []
        for _ in 0 ..< 10 {
            animation.advance(dt: 1 / 60)
            try values.append(#require(animation.value).x)
        }
        #expect(values == [0.98339605, 0.9667921, 0.9500709, 0.9333497, 0.91653657,
                           0.8664166, 0.88307, 0.8664166, 0.8499504, 0.7997922])
    }

    /// 1401a9f60: mirror adds the signed dt to t directly and reflects only at the ends.
    @Test func mirrorStepsBackByExactlyDtUntilItReachesZero() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(30, 1)]], fps: 30, length: 30,
                               options: ["mode": "mirror"]), valueType: .float
        ))
        let dt: Float = 1 / 60
        while animation.direction > 0 {
            animation.advance(dt: dt)
        }
        var reversed = 0
        while animation.direction < 0 {
            let before = animation.time
            animation.advance(dt: dt)
            if animation.direction < 0 {
                #expect(animation.time == -dt + before)
                reversed += 1
            }
        }
        #expect(reversed > 50)
    }

    @Test func singleClampsAndRetainsTheSpecifiedEndpointSampling() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["mode": "single"]), valueType: .float
        ))
        animation.advance(dt: 2)
        #expect(animation.time == 1)
        #expect(animation.finished)
        // At D the specified f0 clamp selects length - 1 and the remainder is zero.
        try expectValue(animation, [3])
        animation.advance(dt: 2)
        #expect(animation.time == 1)
        #expect(animation.finished)
        try expectValue(animation, [3])
    }

    @Test func requiredOptionsMustBeNumbersAndDurationMustBePositive() throws {
        let valid = property(channels: [[key(0, 1)]], fps: 30, length: 30)
        #expect(WPEParityPropertyAnimation(property: valid, valueType: .float) != nil)
        for field in ["fps", "length"] {
            for replacement in [nil, WPESceneJSONValue.bool(true), .string("30"), .number(0)] {
                var object = try #require(objectValue(valid))
                var animation = try #require(objectValue(object["animation"]))
                var options = try #require(objectValue(animation["options"]))
                options[field] = replacement
                animation["options"] = .object(options)
                object["animation"] = .object(animation)
                #expect(WPEParityPropertyAnimation(property: .object(object), valueType: .float) == nil)
            }
        }
    }

    @Test(arguments: [nil, "unknown"] as [String?])
    func missingOrUnknownModeLoops(mode: String?) throws {
        let options: [String: Any] = mode.map { ["mode": $0] } ?? [:]
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: options), valueType: .float
        ))
        animation.advance(dt: 1.25)
        #expect(animation.time == 0.25)
        #expect(!animation.finished)
        try expectValue(animation, [1])
    }

    @Test func channelMismatchDoesNotOverrideVec3() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 1)], [key(0, 2)]], fps: 30, length: 30),
            valueType: .vec3
        ))
        animation.advance(dt: 0.25)
        #expect(animation.value == nil)
    }

    @Test func relativeOffsetsOnlyThreeStringComponents() throws {
        let channels = [[key(0, 1)], [key(0, 2)], [key(0, 3)], [key(0, 4)]]
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: channels, fps: 30, length: 30,
                               value: "10 20 30 40", relative: true), valueType: .vec4
        ))
        try expectValue(animation, [11, 22, 33, 4])
        for value: Any in [5, "10 20", [10, 20, 30]] {
            let ignored = try #require(WPEParityPropertyAnimation(
                property: property(channels: channels, fps: 30, length: 30,
                                   value: value, relative: true), valueType: .vec4
            ))
            try expectValue(ignored, [1, 2, 3, 4])
        }
    }

    @Test func eventsCrossOnceAndIncludeTheStartAfterWrap() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 1)]], fps: 4, length: 4, options: [
                "events": [["frame": 0, "name": "start"], ["frame": 1, "name": "quarter"],
                           ["frame": 3, "name": "late"]],
            ]), valueType: .float
        ))
        animation.advance(dt: 0.3)
        #expect(animation.firedEvents.map(\.name) == ["start", "quarter"])
        animation.advance(dt: 0.1)
        #expect(animation.firedEvents.isEmpty)
        // 1401a9f60: the unwrapped step [0.4, 1.3) first, then [0, 0.3) after the wrap.
        animation.advance(dt: 0.9)
        #expect(animation.firedEvents.map(\.name) == ["late", "start", "quarter"])
        animation.advance(dt: 0)
        #expect(animation.firedEvents.isEmpty)
    }

    @Test func eventAtFrameKFiresOncePerLoopAcrossTheBoundary() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(10, 1)]], fps: 10, length: 10, options: [
                "events": [["frame": 8, "name": "k"]],
            ]), valueType: .float
        ))
        var fired: [[String]] = []
        for dt: Float in [0.5, 0.4, 0.3, 0.7, 0.3] {
            animation.advance(dt: dt)
            fired.append(animation.firedEvents.map(\.name))
        }
        #expect(fired == [[], ["k"], [], ["k"], []])
        animation.advance(dt: 0.1)
        #expect(animation.firedEvents == [])
        #expect(abs(animation.time - 0.3) < 1e-5)
    }

    @Test func eventTimeMultipliesStoredFrameDurationBeforeCrossing() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 1)]], fps: 3, length: 8,
                               options: ["events": [["frame": 5, "name": "boundary"]]]), valueType: .float
        ))
        // 1401a9540 mulss: Float32(5) * Float32(1/3) = 0x3fd55556.
        // Float32(5/3) is the preceding float, which would dispatch this event one step too early.
        animation.advance(dt: Float(bitPattern: 0x3FD5_5556))
        #expect(animation.firedEvents.isEmpty)
        animation.advance(dt: 0.0001)
        #expect(animation.firedEvents.map(\.name) == ["boundary"])
    }

    @Test func mirrorFiresBackwardsOnlyInsideTheStep() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 1)]], fps: 4, length: 4, options: [
                "mode": "mirror", "events": [["frame": 3, "name": "e"]],
            ]), valueType: .float
        ))
        animation.advance(dt: 0.9)
        #expect(animation.firedEvents.first?.frame == 3)
        // 0.9 + 0.3 reflects to 0.8 without firing; backwards from 0.8 the span is (0.6, 0.8].
        animation.advance(dt: 0.3)
        #expect(animation.firedEvents.isEmpty)
        animation.advance(dt: 0.2)
        #expect(animation.firedEvents.map(\.name) == ["e"])
    }

    @Test func rateScalesTheRootStep() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 1)]], fps: 4, length: 4), valueType: .float
        ))
        animation.rate = 0.5
        animation.advance(dt: 0.5)
        #expect(animation.time == 0.25)
    }

    @Test func startPausedKeepsProducingItsInitialValue() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 2), key(4, 10)]], fps: 4, length: 4,
                               options: ["startpaused": true, "random": true]), valueType: .float
        ))
        animation.advance(dt: 5)
        #expect(animation.time == 0)
        try expectValue(animation, [2])
        #expect(animation.firedEvents.isEmpty)
    }

    @Test func playStartsAStartPausedClockAndPauseHoldsIt() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["startpaused": true]), valueType: .float
        ))
        #expect(!animation.isPlaying)
        animation.play()
        #expect(animation.isPlaying)
        animation.advance(dt: 0.25)
        #expect(animation.time == 0.25)
        animation.pause()
        #expect(!animation.isPlaying)
        animation.advance(dt: 0.25)
        #expect(animation.time == 0.25)
        try expectValue(animation, [1])
    }

    /// 140170830 and 1401707f0: stop clears finished and reverse and rewinds; play rewinds only a finished clock.
    @Test func stopRewindsAndClearsReverseWhilePlayKeepsDirection() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["mode": "mirror"]), valueType: .float
        ))
        animation.advance(dt: 1.25)
        #expect(animation.direction == -1)
        animation.pause()
        animation.play()
        #expect(animation.time == 0.75 && animation.direction == -1)
        animation.stop()
        #expect(!animation.isPlaying)
        #expect(animation.time == 0 && animation.direction == 1)
        animation.advance(dt: 0.5)
        #expect(animation.time == 0)
    }

    @Test func playAfterSingleFinishedRestartsAtZero() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["mode": "single"]), valueType: .float
        ))
        animation.advance(dt: 2)
        #expect(animation.finished && !animation.isPlaying)
        animation.play()
        #expect(!animation.finished && animation.time == 0)
        animation.advance(dt: 0.5)
        #expect(animation.time == 0.5)
    }

    /// 140170880 / 1401708a0: time = frame · stored 1/fps without a clamp; the frame is time / stored 1/fps.
    @Test func framesConvertThroughTheStoredFrameDurationWithoutClamping() throws {
        let animation = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(30, 1)]], fps: 30, length: 30), valueType: .float
        ))
        animation.frame = 45
        #expect(animation.time == Float(1) / 30 * 45)
        #expect(animation.frame == animation.time / (Float(1) / 30))
        #expect(animation.fps == 1 / (Float(1) / 30))
        #expect(animation.frameCount == 30)
        #expect(animation.duration == 1)
        animation.advance(dt: 0)
        #expect(abs(animation.time - 0.5) < 1e-5)
    }

    @Test func childUsesRootClockFpsLengthAndFrameStamp() throws {
        let root = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 0), key(4, 4)]], fps: 4, length: 4,
                               options: ["name": "root"]), valueType: .float
        ))
        let child = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 10), key(4, 18)]], fps: 100, length: 100,
                               options: ["name": "child", "parent": ["key": "root"]]),
            valueType: .float, parent: root
        ))
        let grandchild = try #require(WPEParityPropertyAnimation(
            property: property(channels: [[key(0, 20), key(4, 32)]], fps: 1, length: 1,
                               options: ["parent": ["key": "child"]]), valueType: .float, parent: child
        ))
        child.advance(dt: 0.25, frameStamp: 1)
        child.advance(dt: 0.25, frameStamp: 1)
        root.advance(dt: 0.25, frameStamp: 1)
        grandchild.advance(dt: 0.25, frameStamp: 1)
        #expect(root.time == 0.25 && child.time == 0.25 && grandchild.time == 0.25)
        try expectValue(child, [12])
        try expectValue(grandchild, [23])
        root.advance(dt: 0.25, frameStamp: 2)
        child.advance(dt: 0.25, frameStamp: 2)
        try expectValue(child, [14])
        child.advance(dt: 0.75, frameStamp: 3)
        #expect(child.time == 0.25)
        try expectValue(child, [12])
    }

    @Test func parsingStopsAtChannelGapAndSkipsNonIncreasingIntegerFrames() throws {
        var raw = try #require(objectValue(property(channels: [], fps: 4, length: 4)))
        var animation = try #require(objectValue(raw["animation"]))
        animation["c0"] = json([key(0, 2), key(0.9, 99), key(-1, 99),
                                ["frame": true, "value": 99], ["frame": 1, "value": true],
                                key(2, 6, front: ["enabled": false, "x": 100, "y": 100])])
        animation["c1"] = .null
        animation["c2"] = json([key(0, 99)])
        raw["animation"] = .object(animation)
        let parsed = try #require(WPEParityPropertyAnimation(property: .object(raw), valueType: .float))
        parsed.advance(dt: 0.25)
        try expectValue(parsed, [4])
        parsed.advance(dt: 0.5)
        try expectValue(parsed, [6])
    }

    @Test func onlyFourChannelsAreReadAndVec2IsSupported() throws {
        let channels = (1 ... 5).map { [key(0, Double($0))] }
        let four = try #require(WPEParityPropertyAnimation(
            property: property(channels: channels, fps: 30, length: 30), valueType: .vec4
        ))
        try expectValue(four, [1, 2, 3, 4])
        let two = try #require(WPEParityPropertyAnimation(
            property: property(channels: Array(channels.prefix(2)), fps: 30, length: 30), valueType: .vec2
        ))
        try expectValue(two, [1, 2])
    }

    private func property(channels: [[[String: Any]]], fps: Double, length: Double,
                          options: [String: Any] = [:], value: Any = 0,
                          relative: Bool = false) -> WPESceneJSONValue {
        var options = options
        options["fps"] = fps
        options["length"] = length
        var animation: [String: Any] = ["options": options, "relative": relative]
        for (index, channel) in channels.enumerated() {
            animation["c\(index)"] = channel
        }
        return json(["value": value, "animation": animation])
    }

    private func key(_ frame: Double, _ value: Double, front: [String: Any]? = nil,
                     back: [String: Any]? = nil, step: Bool = false) -> [String: Any] {
        var key: [String: Any] = ["frame": frame, "value": value, "step": step]
        key["front"] = front
        key["back"] = back
        return key
    }

    private func json(_ value: Any) -> WPESceneJSONValue {
        WPESceneJSONValue(jsonValue: value)!
    }

    private func objectValue(_ value: WPESceneJSONValue?) -> [String: WPESceneJSONValue]? {
        guard case let .object(object) = value else { return nil }
        return object
    }

    private func expectValue(_ animation: WPEParityPropertyAnimation, _ expected: [Float],
                             tolerance: Float = 0.04) throws {
        let value = try #require(animation.value)
        #expect((expected.count ..< 4).allSatisfy { value[$0] == 0 })
        for (lane, golden) in expected.enumerated() {
            #expect(abs(value[lane] - golden) < tolerance)
        }
    }

    private func bezier(frame: Float) -> Float {
        curve(frame: frame, x: [0, 2.8, 2.6, 4], y: [1, 6, 1, 3])
    }

    private func curve(frame: Float, x: [Float], y: [Float]) -> Float {
        func cubic(_ points: [Float], _ u: Float) -> Float {
            let v = 1 - u
            return v * v * v * points[0] + 3 * v * v * u * points[1]
                + 3 * v * u * u * points[2] + u * u * u * points[3]
        }
        var u: Float = 0
        var step: Float = 0.4995
        for _ in 0 ..< 1000 {
            let position = cubic(x, u)
            if abs(position - frame) < 0.01 {
                break
            }
            if position > frame {
                u -= step
            } else {
                u += step
            }
            step *= 0.5
        }
        return cubic(y, min(1, max(0, u)))
    }
}
