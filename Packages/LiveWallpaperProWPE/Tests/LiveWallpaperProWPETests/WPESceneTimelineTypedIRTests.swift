import Foundation
import Testing
@testable import LiveWallpaperProWPE

@Suite("WPE scene timeline typed lossless IR")
struct WPESceneTimelineTypedIRTests {
    @Test("Parses named, paused, event, and Bézier metadata without changing sampling")
    func parsesFullAuthoredShape() throws {
        let animated = try #require(parseAnimated(#"""
        {
          "value": 0,
          "animation": {
            "c0": [
              {
                "frame": 10,
                "value": 1,
                "lockangle": false,
                "locklength": true,
                "front": {"enabled": true, "x": 1.5, "y": -2, "magic": true},
                "back": {"enabled": false, "x": -1, "y": 0}
              },
              {
                "frame": 0,
                "value": 0,
                "lockangle": true,
                "locklength": false,
                "front": {"enabled": false, "x": 0, "y": 0},
                "back": {"enabled": true, "x": -0.5, "y": 0.25, "magic": false}
              }
            ],
            "options": {
              "fps": 10,
              "length": 10,
              "mode": "single",
              "wraploop": false,
              "name": "hover",
              "startpaused": true,
              "events": [
                {"name": "begin", "frame": 0},
                {"name": "finish", "frame": 10}
              ]
            }
          }
        }
        """#))

        #expect(animated.animation.name == .value("hover"))
        #expect(animated.animation.startPaused == .value(true))
        #expect(animated.animation.events == .value([
            WPESceneAnimationEvent(name: .value("begin"), frame: .value(0)),
            WPESceneAnimationEvent(name: .value("finish"), frame: .value(10))
        ]))

        let first = try #require(animated.animation.tracks.first?.first)
        #expect(first.frame == 0, "Sorting keyframes must carry their typed metadata with them")
        #expect(first.lockAngle == .value(true))
        #expect(first.lockLength == .value(false))
        #expect(first.front == .value(WPESceneAnimationTangent(
            enabled: .value(false),
            x: .value(0),
            y: .value(0)
        )))
        #expect(first.back == .value(WPESceneAnimationTangent(
            enabled: .value(true),
            x: .value(-0.5),
            y: .value(0.25),
            magic: .bool(false)
        )))

        // Tangents are metadata-only in this patch: current linear sampling is unchanged.
        #expect(animated.scalar(at: 0.5) == 0.5)
    }

    @Test("Distinguishes missing metadata from explicit false and empty events")
    func missingVersusAuthoredEmpty() throws {
        let missing = try #require(parseAnimated(minimalOptions: ""))
        #expect(missing.animation.name == nil)
        #expect(missing.animation.startPaused == nil)
        #expect(missing.animation.events == nil)
        let missingKey = try #require(missing.animation.tracks.first?.first)
        #expect(missingKey.lockAngle == nil)
        #expect(missingKey.lockLength == nil)
        #expect(missingKey.front == nil)
        #expect(missingKey.back == nil)

        let authored = try #require(parseAnimated(
            minimalOptions: #", "name": "", "startpaused": false, "events": []"#,
            keyMetadata: #", "lockangle": false, "locklength": false, "front": {}, "back": {}"#
        ))
        #expect(authored.animation.name == .value(""))
        #expect(authored.animation.startPaused == .value(false))
        #expect(authored.animation.events == .value([]))
        let authoredKey = try #require(authored.animation.tracks.first?.first)
        #expect(authoredKey.lockAngle == .value(false))
        #expect(authoredKey.lockLength == .value(false))
        #expect(authoredKey.front == .value(WPESceneAnimationTangent()))
        #expect(authoredKey.back == .value(WPESceneAnimationTangent()))
    }

    @Test("Preserves explicit null and unexpected JSON without inventing defaults")
    func nullAndUnexpectedShapes() throws {
        let animated = try #require(parseAnimated(
            minimalOptions: #", "name": null, "startpaused": "false", "events": null"#,
            keyMetadata: #", "lockangle": null, "locklength": 0, "front": null, "back": 7"#
        ))

        #expect(animated.animation.name == .null)
        #expect(animated.animation.startPaused == .unparsed(.string("false")))
        #expect(animated.animation.events == .null)
        let key = try #require(animated.animation.tracks.first?.first)
        #expect(key.lockAngle == .null)
        #expect(key.lockLength == .unparsed(.number(0)))
        #expect(key.front == .null)
        #expect(key.back == .unparsed(.number(7)))
    }

    @Test("Timeline IR remains value-copyable, Equatable, and Sendable")
    func valueContracts() throws {
        let animated = try #require(parseAnimated(
            minimalOptions: #", "name": "copy", "startpaused": true, "events": []"#
        ))
        let copy = animated.animation

        #expect(copy == animated.animation)
        requireSendable(copy)
        requireSendable(WPESceneAnimationEvent(name: .value("event"), frame: .value(1)))
        requireSendable(WPESceneAnimationTangent(enabled: .value(true)))
    }

    private func parseAnimated(_ json: String) -> WPESceneAnimatedValue? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WPEValueParser.animatedValue(root)
    }

    private func parseAnimated(
        minimalOptions: String,
        keyMetadata: String = ""
    ) -> WPESceneAnimatedValue? {
        parseAnimated("""
        {
          "value": 0,
          "animation": {
            "c0": [{"frame": 0, "value": 0\(keyMetadata)}],
            "options": {"fps": 30, "length": 0, "mode": "single", "wraploop": false\(minimalOptions)}
          }
        }
        """)
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
