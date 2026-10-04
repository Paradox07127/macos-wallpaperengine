import Foundation
@testable import LiveWallpaperProWPE
import Testing

@Suite("WPE scene origin animation channel padding")
struct WPESceneOriginAnimationTests {
    private func origin(channels: [String: [Double]], relative: Bool) throws -> WPESceneAnimatedValue {
        var animation: [String: Any] = [
            "options": ["fps": 10.0, "length": 10.0, "mode": "single"],
            "relative": relative,
        ]
        for (key, values) in channels {
            animation[key] = [
                ["frame": 0.0, "value": values[0]],
                ["frame": 10.0, "value": values[1]],
            ]
        }
        return try #require(WPEValueParser.animatedValue(["value": "100 200 300", "animation": animation]))
    }

    @Test("Absolute origin animating only c0 keeps authored y and z")
    func absoluteC0Only() throws {
        let animated = try origin(channels: ["c0": [0, 10]], relative: false)

        #expect(animated.originVector(at: 0) == [0, 200, 300])
        #expect(animated.originVector(at: 0.5) == [5, 200, 300])
        #expect(animated.originVector(at: 1) == [10, 200, 300])
    }

    @Test("Absolute origin animating c0 and c1 keeps authored z")
    func absoluteC0C1() throws {
        let animated = try origin(channels: ["c0": [0, 10], "c1": [20, 40]], relative: false)

        #expect(animated.originVector(at: 0) == [0, 20, 300])
        #expect(animated.originVector(at: 0.5) == [5, 30, 300])
        #expect(animated.originVector(at: 1) == [10, 40, 300])
    }

    @Test("Relative origin animating only c0 offsets x from the authored origin")
    func relativeC0Only() throws {
        let animated = try origin(channels: ["c0": [0, 10]], relative: true)

        #expect(animated.originVector(at: 0) == [100, 200, 300])
        #expect(animated.originVector(at: 0.5) == [105, 200, 300])
        #expect(animated.originVector(at: 1) == [110, 200, 300])
    }
}
