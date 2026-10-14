import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityRegisteredAssetsTests: XCTestCase {
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
          catch(e) { phase = e.message === 'registerAsset can only be called from global scope.'; }
          return global && phase ? 3 : 99;
        }
        """#
        let objects: [[String: Any]] = [1, 2].map { id in
            ["id": id, "image": "models/a.json", "alpha": ["value": 1, "script": script]]
        }
        let source: [String: Any] = ["general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": objects]
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
