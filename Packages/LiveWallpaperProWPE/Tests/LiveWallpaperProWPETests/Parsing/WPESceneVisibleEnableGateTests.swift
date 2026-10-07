import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaperProWPE

/// A `visible` envelope can carry a script **and** a condition-form `user` binding at once:
/// the binding is the script's enable gate and `value` is the *disabled* state, so seeding
/// from `value` while the gate is satisfied would leave the layer switched off.
@Suite("Script-form visible honours its enable gate")
struct WPESceneVisibleEnableGateTests {

    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script: String,
            properties: [String: WPESceneScriptPropertyValue],
            seed: SIMD3<Double>
        ) -> SIMD3<Double>? { nil }
    }

    private func scene(display: String?) throws -> WPESceneDocument {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": [
                [
                    "id": 130,
                    "name": "myLayer",
                    "origin": "0 0 0",
                    "visible": [
                        "script": "scene.on(\"update\", function() {});",
                        "user": ["name": "display", "condition": "4"],
                        "value": false
                    ] as [String: Any]
                ],
                [
                    "id": 221,
                    "name": "mddn",
                    "parent": 130,
                    "image": "models/combined.json",
                    "origin": "0 0 0",
                    "size": "3840 2160"
                ]
            ]
        ]
        var userValues: [String: WallpaperEngineProjectPropertyValue] = [:]
        if let display { userValues["display"] = .string(display) }
        return try WPESceneDocumentParser.parse(
            data: try JSONSerialization.data(withJSONObject: payload),
            userValues: userValues,
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    @Test("A satisfied gate seeds the layer visible")
    func satisfiedGateSeedsVisible() throws {
        let doc = try scene(display: "4")
        #expect(doc.ownVisibilityByID["130"] == true)
    }

    @Test("Control: an unsatisfied gate still seeds hidden")
    func unsatisfiedGateSeedsHidden() throws {
        // Any other period must keep the script layer off, or the background would double-draw.
        let doc = try scene(display: "1")
        #expect(doc.ownVisibilityByID["130"] == false)
    }

    @Test("Control: with no user value at all the baked state stands")
    func absentUserValueKeepsBakedState() throws {
        let doc = try scene(display: nil)
        #expect(doc.ownVisibilityByID["130"] == false)
    }

    private func boundScene(userValue: Bool?) throws -> WPESceneDocument {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": [[
                "id": 2077,
                "name": "bound",
                "image": "models/combined.json",
                "origin": "0 0 0",
                "visible": [
                    "script": "export function update(value) { return value; }",
                    "scriptproperties": ["speed": ["value": 1]],
                    "user": "_3d",
                    "value": false,
                ] as [String: Any],
            ]],
        ]
        var userValues: [String: WallpaperEngineProjectPropertyValue] = [:]
        if let userValue {
            userValues["_3d"] = .bool(userValue)
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try WPESceneDocumentParser.parse(
            data: data,
            userValues: userValues,
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    @Test("A scripted visible bound to a user property seeds from that property")
    func scriptedVisibleSeedsFromUserProperty() throws {
        let doc = try boundScene(userValue: true)
        #expect(doc.ownVisibilityByID["2077"] == true)
        #expect(doc.imageObjects.first?.visibleScript != nil)
    }

    @Test("Control: a scripted visible with no user value keeps the authored value")
    func scriptedVisibleWithoutUserValueKeepsAuthoredValue() throws {
        let doc = try boundScene(userValue: nil)
        #expect(doc.ownVisibilityByID["2077"] == false)
    }
}
