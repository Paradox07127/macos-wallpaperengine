import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import Testing

@Suite("Particle instanceoverride rate script bindings")
struct WPEParticleRateScriptBindingTests {
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
                        "script": "export var scriptProperties = createScriptProperties().addSlider({name: 'multiplier', value: 2}).finish(); export function update(value) { return scriptProperties.multiplier; }",
                        "value": 1.0,
                        "scriptproperties": ["multiplier": ["user": "speed", "value": 2]],
                    ],
                ],
            ]],
        ])
        return try WPESceneDocumentParser.parse(
            data: data,
            userValues: [:]
        )
    }

    @Test("Both authored override spellings preserve the rate script and property seed", arguments: ["instanceoverride", "instanceOverride"])
    func rateScriptMetadataSurvivesParsing(overrideKey: String) throws {
        let doc = try document(overrideKey: overrideKey)
        let rate = try #require(doc.particleObjects.first?.instanceOverride?.rateScript)
        #expect(rate.scriptProperties["multiplier"] == .number(2))
        #expect(rate.script.contains("return scriptProperties.multiplier"))
    }

    @Test("A shared user property updates the running canonical rate script without a reload")
    func rateScriptPropertyUpdatesRunningInstance() throws {
        let doc = try document(overrideKey: "instanceoverride")
        let bindings = WPEParityUserProperties.bindings(document: doc)
        let patch = WPEScenePropertyPatch(
            bindingsByProperty: bindings,
            oldValues: ["speed": .number(1)],
            newValues: ["speed": .number(3)]
        )
        #expect(!patch.requiresReload)
        #expect(patch.changedBindings.count == 2)
        #expect(patch.changedBindings.contains {
            $0.kind == .scriptProperty
                && $0.target == .objectResource(objectID: "7", field: "instanceoverride.rate.scriptproperties.multiplier")
        })

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var state = WPEParitySceneState(document: doc, hdr: false)
        let engine = try WPEParityScriptEngine.prepare(
            document: doc, state: &state,
            configuration: .init(assets: assets, canvasSize: SIMD2(1920, 1080), screenResolution: SIMD2(1920, 1080)),
            volume: { _, _ in }, command: { _, _, _ in false }
        )
        #expect(engine.bindings.contains { $0.path == "instanceoverride/rate" && $0.compiled })
        try engine.start(state: &state)
        engine.tick(dt: 0, state: &state)
        #expect(state.scriptField("instance.rate", of: "7") == .vector(SIMD4(2, 0, 0, 0)))

        engine.applyUserProperties(changedJSON: #"{"speed":{"type":"slider","value":3}}"#,
                                   mergedJSON: #"{"speed":{"type":"slider","value":3}}"#, state: &state)
        engine.tick(dt: 0, state: &state)
        #expect(state.scriptField("instance.rate", of: "7") == .vector(SIMD4(3, 0, 0, 0)))
        #expect(engine.exceptionCount == 0, "\(engine.exceptions.joined(separator: "; "))")
    }
}
