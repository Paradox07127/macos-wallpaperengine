import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParitySceneCommonOrderTests: XCTestCase {
    func testCommonSortUsesUnsignedPositionWithoutMovingStableSlotsOrParentPlaceholders() throws {
        let document = try Self.document()
        var state = WPEParitySceneState(document: document, hdr: false)
        let slots = state.ids
        XCTAssertTrue(slots.contains("99"), "the transform parent remains a stable value slot")
        XCTAssertEqual(state.commonOrder, ["1", "2", "3"])
        XCTAssertFalse(state.sortObject("99", to: 0), "a transform-only placeholder is not a common member")
        XCTAssertTrue(state.sortObject("2", to: 0))
        XCTAssertEqual(state.commonOrder, ["2", "1", "3"])
        XCTAssertTrue(state.sortObject("2", to: -1))
        XCTAssertEqual(state.commonOrder, ["1", "3", "2"])
        XCTAssertTrue(state.sortObject("1", to: .min))
        XCTAssertEqual(state.commonOrder, ["3", "2", "1"])
        XCTAssertEqual(state.membershipGeneration, 3)
        XCTAssertTrue(state.removeObject("2"))
        XCTAssertEqual(state.commonOrder, ["3", "1"])
        XCTAssertEqual(state.ids, slots)
        XCTAssertFalse(state.sortObject("2", to: 0))
        XCTAssertFalse(state.removeObject("2"))
        XCTAssertEqual(state.membershipGeneration, 4)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(4, 5, 0))
    }

    /// A State mutation and a script sort both reach the same numeric/index/name/enumeration projection.
    /// Real draw/cursor/present and resize are covered separately by the product sort guard.
    func testScriptQueriesProjectTheCurrentCommonOrderAndKeepWrapperIdentity() throws {
        let script = #"""
        let frame = 0;
        const saved = thisLayer;
        function witness(expected, index) {
          const rows = thisScene.enumerateLayers();
          const names = rows.map(layer => layer.name).join('|');
          thisLayer.color = new Vec3(
            names === expected && thisScene.getLayerCount() === 3 ? 1 : 99,
            thisScene.getLayerIndex(saved) === index && thisScene.getLayer(index) === saved ? 1 : 99,
            thisScene.getLayer('A') === saved && rows[index] === saved ? 1 : 99);
        }
        export function init(v) { witness('C|A|B', 1); return v; }
        export function update(v) {
          ++frame;
          const position = frame === 1 ? -1.25 : 0;
          if (thisScene.sortLayer(saved, position) !== true) throw Error('sort failed');
          witness(frame === 1 ? 'C|B|A' : 'A|C|B', frame === 1 ? 2 : 0);
          return v;
        }
        """#
        let document = try Self.document(script: script)
        var state = WPEParitySceneState(document: document, hdr: false)
        let slots = state.ids
        XCTAssertTrue(state.sortObject("3", to: 0))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            sortLayer: { id, position, state in
                guard let position = Int32(exactly: position) else { return false }
                return state.sortObject(id, to: position)
            }
        ))
        engine.start(state: &state)
        XCTAssertEqual(state.object("1")?.color, .one)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(state.commonOrder, ["3", "2", "1"])
        XCTAssertEqual(state.object("1")?.color, .one)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(state.commonOrder, ["1", "3", "2"])
        XCTAssertEqual(state.object("1")?.color, .one)
        XCTAssertEqual(state.ids, slots)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    private static func document(script: String? = nil) throws -> WPESceneDocument {
        let alpha: Any
        if let script { alpha = ["value": 1, "script": script] }
        else { alpha = 1 }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 1, "name": "A", "image": "models/a.json", "parent": 99,
                 "origin": "4 5 0", "size": "16 16", "alpha": alpha],
                ["id": 2, "name": "B", "text": "word"],
                ["id": 3, "name": "C", "image": "models/c.json", "size": "16 16"],
            ],
        ]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? { nil }
}
