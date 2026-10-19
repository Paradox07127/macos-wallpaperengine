import Foundation
@testable import LiveWallpaperProWPE
import Testing

@Suite("Shared numeric animation curves and camera parsing")
struct WPESceneCameraMotionTests {
    @Test("Camera angles retain their authored animation channels")
    func cameraAnglesAnimation() throws {
        let data = Data(#"{"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},"general":{"orthogonalprojection":{"width":256,"height":128}},"objects":[{"id":3727,"camera":"default","angles":{"value":"0 0 0","animation":{"c0":[{"frame":0,"value":0},{"frame":90,"value":0.2}],"c1":[{"frame":0,"value":0},{"frame":90,"value":0.3}],"c2":[{"frame":0,"value":0},{"frame":90,"value":0.4}],"options":{"fps":18,"length":90,"mode":"single"}}}}]}"#.utf8)
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:])
        let motion = try #require(document.cameraMotion)
        #expect(motion.anglesAnimation?.animation.tracks.count == 3)
        #expect(document.staticCamera.eye == .zero)
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

    @Test("Single-sided tangents match simultaneous Windows alpha controls and hold their last frame")
    func capturedSingleSidedCurves() throws {
        let captures: [(Double, Double, Double)] = [
            (0.6471712887287138, 0.5792588591575623, 0.5334067344665527),
            (1.1332806944847105, 0.5500187873840332, 0.4856032729148865),
            (1.654940918087959, 0.5122692584991455, 0.4361492097377777),
            (2.1462675929069515, 0.472729355096817, 0.39158257842063904),
            (3.641894161701202, 0.33718639612197876, 0.2712104022502899),
            (4.206189587712288, 0.2817400097846985, 0.2348138689994812),
        ]
        for omit in [true, false] {
            for frontEnabled in [true, false] {
                var start: [String: Any] = ["frame": 0, "value": 0.6]
                var end: [String: Any] = ["frame": 90, "value": 0.2]
                if frontEnabled || !omit {
                    start["front"] = ["enabled": frontEnabled, "x": 0.50555557, "y": 0]
                }
                if !frontEnabled || !omit {
                    end["back"] = ["enabled": !frontEnabled, "x": -0.65555555, "y": 0.04]
                }
                let a = try #require(WPEValueParser.animatedValue(["value": 0.6, "animation": [
                    "c0": [start, end], "options": ["fps": 18, "length": 90, "mode": "single"],
                ]] as [String: Any]))
                for (time, front, back) in captures {
                    #expect(abs((a.scalar(at: time) ?? -1) - (frontEnabled ? front : back)) < 0.0001)
                }
                #expect(a.scalar(at: 0) == 0.6)
                #expect(a.scalar(at: 6.5) == 0.2)
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
        ]), userValues: ["intro": .bool(false)])
        #expect(doc.cameraMotion?.objectID == "1")
        #expect(doc.cameraMotion?.origin == SIMD3(3, 4, 0))
        #expect(doc.cameraMotion?.zoom == 2)
        #expect(doc.authoredCameraObjects.last?.sourceJSON["visible"]?["user"] == .string("intro"))
    }

    @Test("Camera origin animation requires all three authored channels, as captured on Windows")
    func cameraOriginRequiresCompleteChannels() throws {
        for complete in [false, true] {
            var animation: [String: Any] = [
                "c0": [["frame": 0, "value": 0], ["frame": 90, "value": 80]],
                "c1": [["frame": 0, "value": 0], ["frame": 90, "value": 40]],
                "options": ["fps": 18, "length": 90, "mode": "single"],
            ]
            if complete {
                animation["c2"] = [["frame": 0, "value": 0], ["frame": 90, "value": 0]]
            }
            let doc = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 256, "height": 128]],
                "objects": [["id": 3727, "camera": "default", "origin": ["value": "0 0 0", "animation": animation], "zoom": 1]],
            ]), userValues: [:])
            let motion = try #require(doc.cameraMotion)
            #expect(motion.origin == .zero)
            #expect((motion.originAnimation != nil) == complete)
            #expect(doc.authoredCameraObjects[0].sourceJSON["origin"]?["animation"] != nil)
        }
    }

    private func curve(front: (Double, Double), back: (Double, Double), magic: Bool) throws -> WPESceneAnimatedValue {
        try #require(WPEValueParser.animatedValue(["value": 0.85, "animation": [
            "c0": [["frame": 0, "value": 0.6, "front": ["enabled": true, "x": front.0, "y": front.1, "magic": magic]],
                   ["frame": 90, "value": 0.2, "back": ["enabled": true, "x": back.0, "y": back.1, "magic": magic]]],
            "options": ["fps": 18, "length": 90, "mode": "single"],
        ]] as [String: Any]))
    }
}
