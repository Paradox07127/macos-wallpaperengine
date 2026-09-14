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
}
