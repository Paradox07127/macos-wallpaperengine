import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import Testing

@Suite("Particle instanceoverride rate script bindings")
struct WPEParticleRateScriptBindingTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script _: String,
            properties _: [String: WPESceneScriptPropertyValue],
            seed _: SIMD3<Double>
        ) -> SIMD3<Double>? {
            nil
        }
    }

    private func document(overrideKey: String) throws -> WPESceneDocument {
        let data = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": [
                "orthogonalprojection": ["width": 1920, "height": 1080],
                "cameraparallaxamount": ["user": "speed", "value": 1],
            ],
            "objects": [[
                "id": 7,
                "name": "Stars",
                "particle": "particles/stars.json",
                "origin": "0 0 0",
                overrideKey: [
                    "rate": [
                        "script": "export function update(value) { return value * scriptProperties.multiplier; }",
                        "value": 1.0,
                        "scriptproperties": ["multiplier": ["user": "speed", "value": 2]],
                    ],
                ],
            ]],
        ])
        return try WPESceneDocumentParser.parse(
            data: data,
            userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    @Test("A rate-script property shared with an incremental binding forces a reload", arguments: ["instanceoverride", "instanceOverride"])
    func rateScriptPropertyForcesReload(overrideKey: String) throws {
        let doc = try document(overrideKey: overrideKey)
        let patch = WPEScenePropertyPatch(
            bindingsByProperty: doc.propertyBindings,
            oldValues: ["speed": .number(1)],
            newValues: ["speed": .number(3)]
        )
        #expect(patch.requiresReload)
    }
}
