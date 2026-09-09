import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import Testing

/// 2955378002 "Blinking Stars 23" (object 1607) and "Blinking Stars 00" (1610)
/// author `instanceoverride.alpha` as `{ script, value }`, gating the whole
/// system on `engine.timeOfDay`. `unwrap("alpha")` returned the seed `1.0` and
/// the script itself was dropped, so Mac drew both systems at full alpha at noon
/// (measured means 0.57 / 0.59) while the Windows capture has COLOR.a = 0.
@Suite("Particle instanceoverride alpha script")
struct WPEParticleInstanceAlphaScriptTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script _: String,
            properties _: [String: WPESceneScriptPropertyValue],
            seed _: SIMD3<Double>
        ) -> SIMD3<Double>? {
            nil
        }
    }

    /// Verbatim shape of 1607's override, trimmed to the alpha envelope.
    private static let alphaScriptSource = """
    'use strict';
    import * as WEMath from 'WEMath';
    export function update(value) {
    \treturn WEMath.smoothStep(0.83329, 0.83333, engine.timeOfDay);
    }
    """

    private func parse(_ payload: [String: Any]) throws -> WPESceneDocument {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try WPESceneDocumentParser.parse(
            data: data,
            userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    private func document(alphaOverride: Any) throws -> WPESceneDocument {
        try parse([
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [[
                "id": 1607,
                "name": "Blinking Stars 23",
                "particle": "particles/stars.json",
                "origin": "0 0 0",
                "instanceoverride": [
                    "id": 1609,
                    "alpha": alphaOverride,
                    "lifetime": 2.0,
                    "size": 1.01,
                ],
            ]],
        ])
    }

    @Test("A scripted alpha override survives parsing with its script properties")
    func scriptedAlphaSurvivesParsing() throws {
        let doc = try document(alphaOverride: [
            "script": Self.alphaScriptSource,
            "value": 1.0,
            "scriptproperties": ["nightOnly": ["value": true]],
        ])
        let override = try #require(doc.particleObjects.first?.instanceOverride)
        #expect(override.alphaScript == Self.alphaScriptSource)
        #expect(override.alphaScriptProperties["nightOnly"] != nil)
        // The seed is still read: it is the argument WPE hands `update(value)`.
        #expect(override.alpha == 1.0)
        // Other override fields must not regress while the alpha envelope changes shape.
        #expect(override.lifetime == 2.0)
        #expect(override.size == 1.01)
    }

    @Test("A plain numeric alpha override keeps working")
    func plainAlphaHasNoScript() throws {
        let doc = try document(alphaOverride: 0.25)
        let override = try #require(doc.particleObjects.first?.instanceOverride)
        #expect(override.alphaScript == nil)
        #expect(override.alpha == 0.25)
    }

    @Test("A user-bound alpha override keeps working")
    func userBoundAlphaHasNoScript() throws {
        let doc = try document(alphaOverride: ["user": "starfade", "value": 0.5])
        let override = try #require(doc.particleObjects.first?.instanceOverride)
        #expect(override.alphaScript == nil)
        #expect(override.alpha == 0.5)
    }

    /// The seed must not be baked into spawn alpha when a script drives the
    /// property — `update(value)` REPLACES it, so baking would square it.
    @Test("A scripted alpha override leaves the definition's spawn alpha unbaked")
    func scriptedAlphaIsNotBaked() {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 4,
            "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [
                ["name": "alpharandom", "min": 1, "max": 1],
                ["name": "lifetimerandom", "min": 10, "max": 10],
                ["name": "sizerandom", "min": 8, "max": 8],
            ],
        ])
        let scripted = definition.applying(instanceOverride: WPESceneParticleInstanceOverride(
            alpha: 0.5, alphaScript: Self.alphaScriptSource
        ))
        #expect(scripted.alphaMax == definition.alphaMax)
        // Control: the same seed with no script still bakes, as it always has.
        let baked = definition.applying(instanceOverride: WPESceneParticleInstanceOverride(alpha: 0.5))
        #expect(baked.alphaMax == definition.alphaMax * 0.5)
    }
}
