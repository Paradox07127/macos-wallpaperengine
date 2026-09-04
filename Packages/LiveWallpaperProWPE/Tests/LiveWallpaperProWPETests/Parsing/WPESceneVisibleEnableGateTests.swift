import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaperProWPE

/// A `visible` envelope can carry a script **and** a condition-form `user`
/// binding at once: `{script, user:{name:K, condition:"4"}, value:false}`.
/// The binding is the script's enable gate and `value` is the *disabled* state,
/// so seeding from `value` while the gate is satisfied leaves the layer switched
/// off with only the authored script able to turn it on — and that script is
/// frequently written against APIs we do not implement.
///
/// Scene 3470764447 is the case this locks: its day/night parent layer is gated
/// on `display == "4"`, and picking period 4 (which is what a downloaded preset
/// did) left every background layer unrendered while text kept drawing.
@Suite("Script-form visible honours its enable gate")
struct WPESceneVisibleEnableGateTests {

    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script: String,
            properties: [String: WPESceneScriptPropertyValue],
            seed: SIMD3<Double>
        ) -> SIMD3<Double>? { nil }
    }

    /// Mirrors the real object: a parent whose visibility is script-driven and
    /// gated on a combo property, plus a child that inherits from it.
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
        // This is the path that was already working — picking any other period
        // must keep the script layer off, or the fix would double-draw the
        // background it is meant to restore.
        let doc = try scene(display: "1")
        #expect(doc.ownVisibilityByID["130"] == false)
    }

    @Test("Control: with no user value at all the baked state stands")
    func absentUserValueKeepsBakedState() throws {
        // No preset and no override: the envelope's own `value` is the answer,
        // which is what makes a fresh install render correctly today.
        let doc = try scene(display: nil)
        #expect(doc.ownVisibilityByID["130"] == false)
    }
}
