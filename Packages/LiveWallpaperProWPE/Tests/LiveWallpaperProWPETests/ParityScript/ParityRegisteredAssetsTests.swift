import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityRegisteredAssetsTests: XCTestCase {
    func testRegistrationCanonicalizesNativePathBeforeDuplicateAndPhaseMutation() async throws {
        let script = #"""
        const plain = 'materials/prefix.json';
        if (engine.registerAsset(plain + '\u0000suffix', true) !== plain) throw Error('NUL return');
        if (engine.registerAsset(plain + '\u0000other', false) !== undefined) throw Error('NUL duplicate');
        if (engine.registerAsset(plain, false) !== undefined) throw Error('plain duplicate');
        for (const path of ['materials/caf\u00e9.json', 'materials/cafe\u0301.json', 'materials/\ud83d\ude00.json']) {
          if (engine.registerAsset(path, true) !== path) throw Error('Unicode identity');
        }
        const malformed = 'materials/\ud800-high-\udc00.json\u0000\ud800';
        const repaired = 'materials/\ufffd-high-\ufffd.json';
        if (engine.registerAsset(malformed, true) !== repaired) throw Error('surrogate replacement');
        if (engine.registerAsset(repaired, false) !== undefined) throw Error('repaired duplicate');
        export function init() {
          try {
            engine.registerAsset({toString(){throw Error('coercion');}}, true);
          } catch (e) {
            return e instanceof SyntaxError && e.message === 'registerAsset can only be called from global scope.' ? 7 : 99;
          }
          return 99;
        }
        """#
        let source: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "image": "models/a.json", "alpha": ["value": 1, "script": script]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in RegisteredAssetNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let paths = ["materials/prefix.json", "materials/caf\u{e9}.json", "materials/cafe\u{301}.json",
                     "materials/\u{1f600}.json", "materials/\u{fffd}-high-\u{fffd}.json"]
        let pathBytes = paths.map { Data($0.utf8) }
        let material = Data(#"{"passes":[{"shader":"native-path-consumer"}]}"#.utf8)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            if path == "scripts/jsclasses/baseclasses.js" {
                return baseClasses
            }
            return pathBytes.contains(Data(path.utf8)) ? material : nil
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64)
        ))
        let binding = try XCTUnwrap(engine.bindings.first)
        XCTAssertEqual(binding.registeredAssets.map { Data($0.path.utf8) }, pathBytes)
        XCTAssertTrue(binding.registeredAssets.allSatisfy(\.flag), "canonical duplicates preserve the first true flag")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        var consumed: [Data] = []
        try await engine.prepareRegisteredAssets { _, declarations in
            for declaration in declarations {
                let json = try XCTUnwrap(assets.json(declaration.path), "the actual asset consumer must read the canonical path")
                XCTAssertEqual(json["passes"]?[0]?["shader"], .string("native-path-consumer"))
                consumed.append(Data(declaration.path.utf8))
            }
        }
        XCTAssertEqual(consumed, pathBytes)
        XCTAssertNil(engine.start(state: &state))
        XCTAssertEqual(state.object("1")?.alpha, 7)
        XCTAssertEqual(engine.bindings[0].registeredAssets.map { Data($0.path.utf8) }, pathBytes,
                       "non-global rejection precedes any declaration mutation")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    /// This guards binding ownership and the load/init barrier with shipped JS. Shader/GPU preparation is the
    /// product owner's separate gate; reading a material JSON here does not qualify a rendered model.
    func testGlobalRegistrationBelongsToEachBindingAndInitRequiresSuccessfulPreparation() async throws {
        let script = #"""
        const path = 'materials/registered.json';
        if (engine.registerAsset(path, false) !== path) throw Error('first registration');
        if (engine.registerAsset(path, true) !== undefined) throw Error('duplicate registration');
        if (engine.registerAsset({toString(){throw Error('coercion');}}) !== undefined) throw Error('strict string');
        let global = false;
        try { thisScene.createModelData({}); } catch(e) { global = e.message === 'createModelData cannot be called from global scope.'; }
        export function init() {
          let phase = false;
          try { engine.registerAsset('materials/late.json'); }
          catch(e) { phase = typeof e === 'object' && e.name === 'SyntaxError' && e instanceof Error
            && e.message === 'registerAsset can only be called from global scope.'; }
          return global && phase ? 3 : 99;
        }
        export function update() {
          let phase = false;
          try { engine.registerAsset('materials/late-update.json'); }
          catch(e) { phase = typeof e === 'object' && e.name === 'SyntaxError' && e instanceof Error
            && e.message === 'registerAsset can only be called from global scope.'; }
          return phase ? 4 : 99;
        }
        """#
        let objects: [[String: Any]] = [1, 2].map { id in
            ["id": id, "image": "models/a.json", "alpha": ["value": 1, "script": script]]
        }
        let source: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                     "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": objects]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in RegisteredAssetNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let material = Data(#"{"passes":[{"shader":"modeldata-test"}]}"#.utf8)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            switch path {
            case "scripts/jsclasses/baseclasses.js": baseClasses
            case "materials/registered.json": material
            default: nil
            }
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64)
        ))
        XCTAssertEqual(engine.bindings.map(\.assetContext.objectID), ["1", "2"])
        XCTAssertEqual(engine.bindings.map(\.assetContext.propertyPath), ["alpha", "alpha"])
        XCTAssertEqual(engine.bindings.map(\.assetContext.bindingIndex), [0, 1])
        XCTAssertEqual(engine.bindings.map(\.assetContext.modulePath), ["scripts/image_alpha.js", "scripts/image_alpha.js"])
        XCTAssertEqual(engine.bindings.map(\.registeredAssets.count), [1, 1])
        XCTAssertTrue(engine.bindings.allSatisfy { $0.registeredAssets.first?.flag == false }, "a duplicate keeps the first flag")
        let blocked = WPEParityScriptEngine.Failure.registeredAssetsNotPrepared(Array(repeating: "materials/registered.json", count: 2))
        XCTAssertEqual(engine.start(state: &state), blocked)
        XCTAssertFalse(engine.started)
        do {
            try await engine.prepareRegisteredAssets { _, _ in throw PreparationFailure.rejected }
            XCTFail("A resource failure must propagate to the owning load transaction")
        } catch PreparationFailure.rejected {}
        XCTAssertEqual(engine.start(state: &state), blocked)
        var prepared: [String] = []
        try await engine.prepareRegisteredAssets { context, declarations in
            XCTAssertEqual(state.object(context.objectID)?.alpha, 1, "init cannot precede this loader")
            for declaration in declarations {
                let json = try XCTUnwrap(assets.json(declaration.path))
                XCTAssertEqual(json["passes"]?[0]?["shader"], .string("modeldata-test"))
            }
            prepared.append(context.objectID)
        }
        XCTAssertEqual(prepared, ["1", "2"])
        XCTAssertNil(engine.start(state: &state))
        XCTAssertEqual(state.object("1")?.alpha, 3)
        XCTAssertEqual(state.object("2")?.alpha, 3)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(state.object("1")?.alpha, 4)
        XCTAssertEqual(state.object("2")?.alpha, 4)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }
}

private enum PreparationFailure: Error { case rejected }

private struct RegisteredAssetNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
