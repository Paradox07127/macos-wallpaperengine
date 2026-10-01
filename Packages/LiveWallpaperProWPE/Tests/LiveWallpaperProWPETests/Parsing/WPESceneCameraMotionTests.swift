import Foundation
@testable import LiveWallpaperProWPE
import Testing

@Suite("Measured WPE camera curves and execution IR")
struct WPESceneCameraMotionTests {
    @Test("Root paths reproduce four same-draw g_Time/eye/zoom samples with one common phase offset")
    func capturedPathCurve() throws {
        let data = Data(#"{"paths":[{"duration":9,"name":"measured","transforms":[{"timestamp":0,"eye":"0 0 0","center":"0 0 -1","up":"0 1 0","zoom":1},{"timestamp":2,"eye":"80 0 0","center":"80 0 -1","up":"0 1 0","zoom":2}]}]}"#.utf8)
        let path = try #require(WPESceneCameraPath.parse(data: data).first)
        #expect(path.duration == 2)
        #expect(path.authoredDuration == 9)
        let captures = [(8.81788444519043, 27.123668222476955, 1.3390460014343262),
                        (9.177789688110352, 44.93141195028278, 1.5616426467895508),
                        (9.528105735778809, 61.55039920811899, 1.7693798542022705),
                        (9.889918327331543, 75.21465128274605, 1.9401830434799194)]
        // The first sample fixes this segment's phase, the other three constrain
        // the curve; this is not a universal g_Time-to-path-clock offset.
        let phaseOffset = 0.078971
        for (time, eye, zoom) in captures {
            let pose = try #require(path.sample(at: time - 8 - phaseOffset))
            #expect(abs(pose.eye.x - eye) < 0.001)
            #expect(abs(pose.zoom - zoom) < 0.00002)
        }
        #expect(path.sample(at: 3)?.eye.x == 80)
    }

    @Test("Angles animation requires complete channels and participates in frame demand")
    func cameraAnglesAnimation() throws {
        let data = Data(#"{"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},"general":{"orthogonalprojection":{"width":256,"height":128}},"objects":[{"id":3727,"camera":"default","angles":{"value":"0 0 0","animation":{"c0":[{"frame":0,"value":0},{"frame":90,"value":0.2}],"c1":[{"frame":0,"value":0},{"frame":90,"value":0.3}],"c2":[{"frame":0,"value":0},{"frame":90,"value":0.4}],"options":{"fps":18,"length":90,"mode":"single"}}}}]}"#.utf8)
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:], makeTransformScriptResolver: { _, _ in NoScriptResolver() })
        let motion = try #require(document.cameraMotion)
        #expect(motion.needsFrames(at: 1))
        #expect(!motion.needsFrames(at: 6))
        #expect(motion.sample(at: 2.5).angles == SIMD3<Double>(0.1, 0.15, 0.2))
        #expect(motion.sample(at: 6).angles == SIMD3<Double>(0.2, 0.3, 0.4))
        #expect(document.staticCamera.eye == .zero)
    }

    @Test("Three path keys keep each segment's independent easing and do not invent a transverse overshoot")
    func independentPathSegments() throws {
        let data = Data(#"{"paths":[{"duration":9,"name":"three keys","transforms":[{"timestamp":0,"eye":"0 0 0","center":"0 0 -1","up":"0 1 0","zoom":1},{"timestamp":1,"eye":"80 0 0","center":"80 0 -1","up":"0 1 0","zoom":2},{"timestamp":3,"eye":"160 40 0","center":"160 40 -1","up":"0 1 0","zoom":1}]}]}"#.utf8)
        let path = try #require(WPESceneCameraPath.parse(data: data).first)
        #expect(path.sample(at: 0.5)?.eye == SIMD3<Double>(40, 0, 0))
        let second = try #require(path.sample(at: 2))
        #expect(second.eye == SIMD3<Double>(120, 20, 0))
        #expect(second.zoom == 1.5)
    }

    @Test("Authored duration controls a terminal hold with the captured inclusive boundary")
    func capturedPathLoopDuration() throws {
        for (authored, expected) in [(0.0, 1.0), (2, 1), (4, 3), (9, 8)] {
            let json: [String: Any] = ["paths": [["duration": authored, "transforms": [
                ["timestamp": 0, "eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0", "zoom": 1],
                ["timestamp": 1, "eye": "80 0 0", "center": "80 0 -1", "up": "0 1 0", "zoom": 2],
            ]]]]
            let path = try #require(WPESceneCameraPath.parse(data: JSONSerialization.data(withJSONObject: json)).first)
            #expect(path.playbackDuration == expected)
            #expect(path.sample(at: 1.5)?.eye.x == 80)
        }
    }

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
        ]), userValues: ["intro": .bool(false)], makeTransformScriptResolver: { _, _ in NoScriptResolver() })
        #expect(doc.cameraMotion?.objectID == "1")
        #expect(doc.cameraMotion?.seed == .init(origin: SIMD3(3, 4, 0), zoom: 2))
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
            ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScriptResolver() })
            let motion = try #require(doc.cameraMotion)
            #expect(motion.seed.origin == .zero)
            #expect((motion.originAnimation != nil) == complete)
            #expect(motion.sample(at: 2.5).origin == (complete ? SIMD3(40, 20, 0) : .zero))
            #expect(motion.needsFrames(at: 2.5) == complete)
            #expect(doc.authoredCameraObjects[0].sourceJSON["origin"]?["animation"] != nil)
        }
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
