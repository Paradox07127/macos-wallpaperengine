import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParityScriptPropertyTests: XCTestCase {
    private typealias Invalidation = WPEParitySceneState.Invalidation

    /// Each script write lands in its field through the engine's slots and moves only its descriptor's hook counter.
    func testEachWriteBackRowLandsInItsFieldAndInvalidation() throws {
        let rows: [(write: String, invalidation: Invalidation)] = [
            ("thisLayer.origin = new Vec3(3, 4, 5)", .transform),
            ("thisLayer.scale = new Vec3(2, 2, 2)", .transform),
            ("thisLayer.angles = new Vec3(0, 0, 90)", .transform),
            ("thisLayer.visible = false", .visibility),
            ("thisLayer.alpha = 0.25", .none),
            ("thisLayer.color = new Vec3(0.5, 0.25, 1)", .none),
            ("thisLayer.brightness = 0.25", .none),
            ("thisLayer.size = new Vec2(20, 30)", .none),
            ("thisLayer.getEffect(0).getMaterial(0).k = new Vec2(1, 2)", .materialConstants),
            ("thisLayer.getEffect(0).visible = false", .effectPasses),
            ("thisScene.bloomstrength = 0.25", .bloom),
            ("thisScene.ambientcolor = new Vec3(3, 4, 5)", .lighting),
            ("thisScene.getLayer('P').instance.count = 0.25", .particleInstance),
            ("thisScene.getLayer('P').instance.rate = 0.25", .none),
            ("thisScene.getLayer('C').fov = 0.25", .none),
            ("thisLayer.getVideoTexture().rate = 0.25", .mediaPlayer),
        ]
        let script = "const rows = [\(rows.map { "() => { \($0.write); }" }.joined(separator: ", "))];\n"
            + "let row = 0;\nexport function update() { rows[row++](); }"
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [
                ["id": 1, "name": "A", "image": "models/a.json", "size": "10 10", "video": [String: Any](),
                 "alpha": ["value": 1, "script": script],
                 "effects": [["id": 5, "file": "effects/x.json", "visible": true,
                              "passes": [["constantshadervalues": ["k": "0 0"]]]]]],
                ["id": 2, "name": "P", "particle": "particles/p.json"],
                ["id": 3, "name": "C", "camera": "cam"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let pass = WPEParityMaterialPassKey(objectID: "1", effectID: "5")
        var state = WPEParitySceneState(document: document, hdr: false, constants: [pass: ["k": [0, 0]]])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let engine = try WPEParityScriptEngine.prepare(
            document: document, state: &state,
            configuration: .init(assets: assets, canvasSize: SIMD2(100, 100), screenResolution: SIMD2(100, 100),
                                 resolvedEffectRecords: [.init(objectID: "1", effectID: "5"): [
                                     WPEParityEffectPassRecord(filePassIndex: 0, materialPass: pass),
                                 ]]),
            volume: { _, _ in }, command: { _, _, _ in false }
        )
        XCTAssertNil(engine.start(state: &state))
        for row in rows {
            let before = Invalidation.allCases.map(state.generation)
            engine.tick(dt: 0, state: &state)
            let after = Invalidation.allCases.map(state.generation)
            for kind in Invalidation.allCases where kind != .none {
                XCTAssertEqual(after[kind.rawValue] - before[kind.rawValue], kind == row.invalidation ? 1 : 0,
                               "\(row.write): \(kind)")
            }
        }
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        let object = try XCTUnwrap(state.object("1"))
        XCTAssertEqual(object.origin, SIMD3(3, 4, 5))
        XCTAssertEqual(object.scale, SIMD3(2, 2, 2))
        XCTAssertEqual(object.angles, SIMD3(0, 0, 90 * WPEParityScriptProperty.degreesToRadians))
        XCTAssertFalse(object.visible)
        XCTAssertEqual(object.alpha, 0.25)
        XCTAssertEqual(object.color, SIMD3(0.5, 0.25, 1))
        XCTAssertEqual(object.brightness, 0.25)
        XCTAssertEqual(state.scriptField("size", of: "1"), .vector(SIMD4(20, 30, 0, 0)))
        XCTAssertEqual(state.constant("k", of: pass)?.value, SIMD4(1, 2, 0, 0))
        XCTAssertEqual(state.isEffectVisible("5", of: "1"), false)
        XCTAssertEqual(state.scriptField("bloomstrength", of: ""), .vector(SIMD4(0.25, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("ambientcolor", of: ""), .vector(SIMD4(3, 4, 5, 0)))
        XCTAssertEqual(state.scriptField("instance.count", of: "2"), .vector(SIMD4(0.25, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("instance.rate", of: "2"), .vector(SIMD4(0.25, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("fov", of: "3"), .vector(SIMD4(0.25, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("video.rate", of: "1"), .vector(SIMD4(0.25, 0, 0, 0)))
    }

    func testDegreesToRadiansIsTheNativeConstant() {
        XCTAssertEqual(WPEParityScriptProperty.degreesToRadians.bitPattern, 0x3C8E_FA35)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
