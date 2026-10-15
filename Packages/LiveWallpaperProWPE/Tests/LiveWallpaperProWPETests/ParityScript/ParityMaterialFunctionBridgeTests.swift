import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityMaterialFunctionBridgeTests: XCTestCase {
    /// Native ordinary-method conversion is independent of scene phase, effect visibility and pass metadata.
    /// This verifies the real JSC bridge; the corresponding product tests verify the FBO clear consumer.
    func testGlobalDefaultConversionVoidIdentityAndConsumerReplacement() throws {
        let script = #"""
        const effect = thisLayer.getEffect(0);
        const call = effect.executeMaterialFunction;
        let coerced = false;
        if (call.call(effect, 'Global') !== undefined) throw Error('void');
        effect.executeMaterialFunction('');
        effect.executeMaterialFunction();
        for (const value of [undefined, null, true, 1, {}, [], new String('boxed'),
          {toString() { coerced = true; return 'coerced'; }}]) effect.executeMaterialFunction(value);
        if (coerced) throw Error('coercion');
        call.call({__s: effect.__s}, 'forged');
        call.call(null, 'null');
        const slot = effect.__s;
        for (const value of [NaN, Infinity, -1, 0.5, 1e300]) {
          effect.__s = value; call.call(effect, 'bad-slot');
        }
        effect.__s = slot;
        export function init(value) { effect.executeMaterialFunction('Init'); return value; }
        export function update(value) { effect.executeMaterialFunction('Update', 'ignored'); return value; }
        """#
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "image": "models/a.json", "size": "64 64",
                         "alpha": ["value": 1, "script": script],
                         "effects": [["id": 5, "visible": false, "file": "effects/a.json"]]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let key = WPEParitySceneState.EffectKey(objectID: "1", effectID: "5")
        var initial: [(WPEParitySceneState.EffectKey, String)] = []
        var replacement: [(WPEParitySceneState.EffectKey, String)] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            executeMaterialFunction: { initial.append(($0, $1)) }
        ))
        XCTAssertEqual(initial.map(\.0), Array(repeating: key, count: 11))
        XCTAssertEqual(initial.map(\.1), ["Global"] + Array(repeating: "", count: 10))
        engine.start(state: &state)
        XCTAssertEqual(initial.last?.1, "Init")
        engine.materialFunctionHandler = { replacement.append(($0, $1)) }
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(initial.count, 12)
        XCTAssertEqual(replacement.map(\.0), [key])
        XCTAssertEqual(replacement.map(\.1), ["Update"])
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
