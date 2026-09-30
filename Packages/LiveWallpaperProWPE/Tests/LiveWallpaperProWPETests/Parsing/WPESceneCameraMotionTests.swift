import Foundation
@testable import LiveWallpaperProWPE
import Testing

@Suite("Measured WPE camera curves and execution IR")
struct WPESceneCameraMotionTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue], seed _: SIMD3<Double>) -> SIMD3<Double>? {
            nil
        }
    }

    @Test("Bézier uses half-span X and absolute Y, matching three simultaneous Windows controls")
    func capturedCurves() throws {
        let cases: [(Double, [Double])] = [
            (0.06897494196891757, [0.5996187329292297, 0.5998867750167847, 0.5995767116546631, 0.6082172393798828]),
            (1.6678363829851148, [0.4877917766571045, 0.518441379070282, 0.4869729280471802, 0.4844955801963806]),
            (3.9975465089082713, [0.2549363076686859, 0.22597818076610565, 0.25141677260398865, 0.2358802855014801]),
        ]
        let handles: [(Double, Double, Double, Double)] = [(0.50555557, 0, -0.65555555, 0.04), (1, 0, -1, 0), (0.5, 0, -0.5, 0), (0.2, 0.1, -0.4, -0.07)]
        for (time, expected) in cases {
            for (index, h) in handles.enumerated() {
                for magic in [true, false] {
                    let a = try curve(front: (h.0, h.1), back: (h.2, h.3), magic: magic)
                    #expect(abs((a.scalar(at: time) ?? -1) - expected[index]) < 0.0004)
                }
            }
        }
    }

    @Test("An explicit single length wins over editor keys outside the playable range")
    func explicitLength() {
        let a = WPESceneNumericAnimation(tracks: [[.init(frame: 0, value: 0), .init(frame: 10, value: 1), .init(frame: 20, value: 3)]], fps: 10, length: 10, mode: "single", wrapLoop: false)
        #expect(a.values(at: 4, fallbacks: [0]) == [1])
    }

    @Test("Resolved visibility selects the bottom camera while its authored envelope remains lossless")
    func cameraSelection() throws {
        let doc = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [["id": 1, "camera": "default", "origin": "3 4 0", "zoom": 2],
                        ["id": 2, "camera": "default", "origin": "5 6 0", "visible": ["value": true, "user": "intro"], "zoom": 3]],
        ]), userValues: ["intro": .bool(false)], makeTransformScriptResolver: { _, _ in NoScriptResolver() })
        #expect(doc.cameraMotion?.objectID == "1")
        #expect(doc.cameraMotion?.seed == .init(origin: SIMD3(3, 4, 0), zoom: 2))
        #expect(doc.authoredCameraObjects.last?.sourceJSON["visible"]?["user"] == .string("intro"))
    }

    @Test("Relative sparse origin tracks follow the root clock and hold after completion")
    func relativeParentClock() throws {
        let origin = try #require(WPEValueParser.animatedValue(["value": "10 20 30", "animation": ["c0": [["frame": 0, "value": -4], ["frame": 10, "value": 0]], "options": ["fps": 100, "length": 100, "mode": "single"]]]))
        let zoom = try #require(WPEValueParser.animatedValue(["value": 4.5, "animation": ["c0": [["frame": 0, "value": 3], ["frame": 10, "value": 1]], "options": ["fps": 10, "length": 10, "mode": "single"]]]))
        let motion = WPESceneCameraMotion(objectID: "cam", origin: SIMD3(10, 20, 30), zoom: 4.5, originAnimation: origin, zoomAnimation: zoom, originIsRelative: true, originFollowsZoom: true)
        #expect(motion.sample(at: 0.5).origin == SIMD3(8, 20, 30))
        #expect(motion.sample(at: 0.5).zoom == 2)
        #expect(motion.sample(at: 10).origin == SIMD3(10, 20, 30))
        #expect(!motion.needsFrames(at: 10))
        // A missing parent keeps the origin's own clock, including frame demand.
        let orphan = WPESceneCameraMotion(objectID: "cam", origin: SIMD3(10, 20, 30), zoom: 1, originAnimation: origin, originIsRelative: true, originFollowsZoom: true)
        #expect(orphan.needsFrames(at: 0.05))
        #expect(orphan.sample(at: 0.05).origin == SIMD3(8, 20, 30))
        #expect(!orphan.needsFrames(at: 2))
    }

    private func curve(front: (Double, Double), back: (Double, Double), magic: Bool) throws -> WPESceneAnimatedValue {
        try #require(WPEValueParser.animatedValue(["value": 0.85, "animation": [
            "c0": [["frame": 0, "value": 0.6, "front": ["enabled": true, "x": front.0, "y": front.1, "magic": magic]],
                   ["frame": 90, "value": 0.2, "back": ["enabled": true, "x": back.0, "y": back.1, "magic": magic]]],
            "options": ["fps": 18, "length": 90, "mode": "single"],
        ]] as [String: Any]))
    }
}
