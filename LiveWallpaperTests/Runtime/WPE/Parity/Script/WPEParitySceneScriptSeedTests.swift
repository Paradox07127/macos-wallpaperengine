#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import simd
import Testing

/// Scene script seeds come from the user-resolved scene JSON with WPE's native defaults, not the parser's.
@Suite(.timeLimit(.minutes(1)))
struct WPEParitySceneScriptSeedTests {
    private static func document(general: [String: Any] = [:], objects: [[String: Any]] = [],
                                 userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPESceneDocument {
        var resolvedGeneral = general
        resolvedGeneral["orthogonalprojection"] = ["width": 100, "height": 100]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0"], "general": resolvedGeneral, "objects": objects,
        ]), userValues: userValues)
    }

    private static func script(_ document: WPESceneDocument,
                               fieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:])
        throws -> WPEParitySceneScript {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js")
            .standardizedFileURL
        let bytes = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? bytes : nil
        }])
        return try WPEParitySceneScript(document: document, state: WPEParitySceneState(document: document, hdr: false),
                                        assets: assets, canvasSize: SIMD2(100, 100), screenResolution: SIMD2(100, 100),
                                        fieldDefaults: fieldDefaults, host: .init())
    }

    private static func sceneFields(_ script: WPEParitySceneScript) -> [String: SIMD4<Float>] {
        var fields: [String: SIMD4<Float>] = [:]
        for (key, value) in script.engine.configuration.fieldDefaults where key.objectID.isEmpty {
            if case let .vector(vector) = value {
                fields[key.name] = vector
            }
        }
        return fields
    }

    private static func candidates(_ script: WPEParitySceneScript) -> [String: WPEParitySceneScript.CursorCandidate] {
        Mirror(reflecting: script).children.first { $0.label == "cursorCandidates" }?.value
            as? [String: WPEParitySceneScript.CursorCandidate] ?? [:]
    }

    private static let source = "export function update(value) { return value; }"

    @Test("A script key at any depth of general or objects marks the scene as scripted")
    func scriptKeysAtAnyDepth() throws {
        #expect(try !WPEParitySceneScript.hasScripts(Self.document(objects: [["id": 1, "alpha": 1]])))
        let origin: [String: Any] = ["value": "0 0 0", "script": Self.source]
        #expect(try WPEParitySceneScript.hasScripts(Self.document(objects: [["id": 1, "origin": origin]])))
        let strength: [String: Any] = ["value": 2, "script": Self.source]
        #expect(try WPEParitySceneScript.hasScripts(Self.document(general: ["bloomstrength": strength])))
        #expect(try WPEParitySceneScript.hasScripts(Self.document(objects: [["id": 1, "effects": [
            ["id": 2, "passes": [["constantshadervalues": ["speed": ["value": 1, "script": Self.source]]]]],
        ]]])))
        #expect(try WPEParitySceneScript.hasScripts(Self.document(general: ["custom": ["script": NSNull()]])),
                "a null script key still counts")
    }

    @Test("Scene vector seeds parse strings, arrays, numbers and envelopes over native defaults")
    func sceneVectorSeeds() throws {
        let parsed = try Self.sceneFields(Self.script(Self.document(general: [
            "bloomstrength": "1 2 3", "bloomthreshold": "1,2",
            "ambientcolor": [0.1, 0.2, 0.3, 0.4, 0.5], "skylightcolor": ["value": 0.5],
        ])))
        #expect(parsed["bloomstrength"] == SIMD4(1, 2, 3, 0))
        #expect(parsed["bloomthreshold"] == SIMD4(1, 2, 0, 0))
        #expect(parsed["ambientcolor"] == SIMD4(0.1, 0.2, 0.3, 0.4))
        #expect(parsed["skylightcolor"] == SIMD4(0.5, 0, 0, 0))
        #expect(parsed["bloom"] == SIMD4(1, 0, 0, 0))

        let fallback = try Self.sceneFields(Self.script(Self.document(general: [
            "bloomstrength": 3, "bloomthreshold": "abc", "ambientcolor": [0.5, "x"], "skylightcolor": "",
            "bloom": false,
        ])))
        #expect(fallback["bloomstrength"] == SIMD4(3, 0, 0, 0))
        #expect(fallback["bloomthreshold"] == SIMD4(0.65, 0, 0, 0))
        #expect(fallback["ambientcolor"] == .zero)
        #expect(fallback["skylightcolor"] == .zero)
        #expect(fallback["bloom"] == .zero)

        let native = try Self.sceneFields(Self.script(Self.document(general: [
            "ambientcolor": ["value": "0.1 0.2 0.3"], "skylightcolor": "1 2 3 4 5 6", "bloom": 1,
        ])))
        #expect(native["bloomstrength"] == SIMD4(2, 0, 0, 0))
        #expect(native["bloomthreshold"] == SIMD4(0.65, 0, 0, 0))
        #expect(native["ambientcolor"] == SIMD4(0.1, 0.2, 0.3, 0))
        #expect(native["skylightcolor"] == SIMD4(1, 2, 3, 4))
        #expect(native["bloom"] == SIMD4(1, 0, 0, 0), "a numeric bloom flag is not a seed")
    }

    @Test("Scene seeds read user values, and caller field defaults win")
    func sceneSeedsReadResolvedValues() throws {
        let document = try Self.document(general: [
            "bloomstrength": ["user": "strength", "value": 1], "bloom": ["user": "glow", "value": true],
            "ambientcolor": "0.3 0.3 0.3",
        ], userValues: ["strength": .number(4), "glow": .bool(false)])
        let ambient = WPEParitySceneState.ScriptFieldKey(objectID: "", name: "ambientcolor")
        let fields = try Self.sceneFields(Self.script(document, fieldDefaults: [ambient: .vector(SIMD4(9, 8, 7, 0))]))
        #expect(fields["bloomstrength"] == SIMD4(4, 0, 0, 0))
        #expect(fields["bloom"] == .zero)
        #expect(fields["ambientcolor"] == SIMD4(9, 8, 7, 0))
    }

    @Test("Object headers: ids, camera class, and solid / disablepropagation flags with their defaults")
    func objectHeaders() throws {
        let script = try Self.script(Self.document(objects: [
            ["id": 1],
            ["id": "s2", "solid": false, "disablepropagation": true],
            ["id": 3, "solid": "false", "disablepropagation": "true"],
            ["id": 4, "solid": ["value": false], "disablepropagation": ["value": 1]],
            ["id": 5, "solid": 0, "disablepropagation": 2],
            ["name": "named", "camera": "cam"],
            ["id": 7, "camera": true],
            ["id": true, "name": "flagged", "camera": "other"],
            ["id": "", "name": "unnamed"],
            ["id": 9, "solid": ["user": "solidity", "value": true]],
        ], userValues: ["solidity": .bool(false)]))
        #expect(script.cameraIDs == ["named", "flagged"])
        let candidates = Self.candidates(script)
        let flags = candidates.mapValues { [$0.solid, $0.disablePropagation] }
        #expect(flags == [
            "1": [true, false], "s2": [false, true], "3": [true, false], "4": [false, true], "5": [false, true],
            "named": [true, false], "7": [true, false], "flagged": [true, false], "unnamed": [true, false],
            "9": [false, false],
        ])
        #expect(candidates.allSatisfy { $0.key == $0.value.id })
    }
}
#endif
