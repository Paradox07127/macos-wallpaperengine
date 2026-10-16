import Foundation
import LiveWallpaperProWPE
import Testing

struct ParitySceneAnimationParentTests {
    @Test func childBindsToTheRootWhosePropertyNameIsTheParentKey() throws {
        let state = try advancedState(objects: [camera(zoom: [
            "value": 3,
            "animation": ["c0": [key(0, 3), key(8, 1)], "options": options(fps: 8, length: 8)],
        ])])
        guard case let .vector(zoom)? = state.scriptField("zoom", of: "2") else {
            Issue.record("zoom field missing")
            return
        }
        #expect(abs(zoom.x - 2) <= 0.02)
        try expectOrigin(state)
    }

    @Test func childWithoutAMatchingRootRunsOnItsOwnClock() throws {
        try expectOrigin(advancedState(objects: [camera(zoom: 1)]))
    }

    @Test func parentKeyIgnoresOptionsNameOfOtherProperties() throws {
        let constant: [[String: Any]] = [key(0, 1), key(8, 1)]
        let layer = imageLayer(extra: [
            "origin": ["value": "0 0 0", "animation": ["c0": constant, "c1": constant, "c2": constant,
                                                       "options": options(fps: 8, length: 8)]],
            "scale": ["value": "1 1 1", "animation": ["c0": constant, "c1": constant, "c2": constant,
                                                      "options": options(fps: 4, length: 4, name: "origin")]],
            "alpha": ["value": 1, "animation": ["c0": [key(0, 0), key(8, 1)],
                                                "options": options(fps: 8, length: 8, parent: "origin")]],
        ])
        let state = try advancedState(objects: [layer])
        #expect(abs((state.object("1")?.alpha ?? 0) - 0.5) <= 0.01)
    }

    private func expectOrigin(_ state: WPEParitySceneState) throws {
        let origin = try #require(state.value(.origin, of: "2"))
        #expect(abs(origin.x + 4) <= 0.02 && abs(origin.y - 4) <= 0.02 && abs(origin.z - 500) <= 0.02)
    }

    private func camera(zoom: Any) -> [String: Any] {
        [
            "id": 2, "camera": "default", "zoom": zoom,
            "origin": ["value": "-8 8 500", "animation": [
                "relative": true,
                "c0": [key(0, 0), key(8, 8)], "c1": [key(0, 0), key(8, -8)], "c2": [key(0, 0), key(8, 0)],
                "options": options(fps: 8, length: 8, parent: "zoom"),
            ]],
        ]
    }

    private func imageLayer(extra: [String: Any] = [:]) -> [String: Any] {
        let layer: [String: Any] = ["id": 1, "name": "A", "image": "models/a.json", "size": "10 10"]
        return layer.merging(extra) { $1 }
    }

    private func options(fps: Int, length: Int, name: String? = nil, parent: String? = nil) -> [String: Any] {
        var options: [String: Any] = ["fps": fps, "length": length, "mode": "single"]
        options["name"] = name
        options["parent"] = parent.map { ["key": $0] }
        return options
    }

    private func key(_ frame: Int, _ value: Double) -> [String: Any] {
        ["frame": frame, "value": value]
    }

    private func advancedState(objects: [[String: Any]]) throws -> WPEParitySceneState {
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [imageLayer()].filter { _ in !objects.contains { $0["id"] as? Int == 1 } } + objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        var animations = WPEParitySceneAnimations(document: document, state: state, constantComponents: [:])
        animations.advance(dt: 0.5, state: &state)
        return state
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
