import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptSetParentTests: XCTestCase {
    func testScriptSetParentMovesUnderLayerAndRejectsItself() throws {
        let script = #"""
        export function init(v) {
          const b = thisScene.getLayer('B');
          let ok = true;
          thisLayer.setParent(b, false);
          ok = ok && thisLayer.getParent() === b && b.getChildren().includes(thisLayer);
          let rejected = false;
          try { thisLayer.setParent(thisLayer); } catch (e) { rejected = e.message === 'Invalid parent configuration.'; }
          ok = ok && rejected && thisLayer.getParent() === undefined;
          thisLayer.setParent('B');
          ok = ok && thisLayer.getParent() === b;
          thisLayer.setParent(undefined);
          ok = ok && thisLayer.getParent() === undefined;
          thisLayer.setParent(b, 'hand');
          ok = ok && thisLayer.getParent() === undefined;
          if (ok) thisLayer.color = new Vec3(1, 1, 1);
          thisLayer.setParent(2, false);
          return v;
        }
        """#
        let document = try Self.document(script: script)
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let logs = LogLines()
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            log: { _, message in logs.lines.append(message) }
        ))
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.color, .one)
        XCTAssertEqual(state.parentID(of: "1"), "3")
        XCTAssertTrue(logs.lines.contains("setParent with an attachment or adjustTransforms is unsupported"),
                      "\(logs.lines)")
    }

    func testStateSetParentRejectsSelfAndCycle() throws {
        var state = try WPEParitySceneState(document: Self.document(), hdr: false)
        let membership = state.membershipGeneration
        XCTAssertTrue(state.setParent("1", to: "2"))
        XCTAssertEqual(state.parentID(of: "1"), "2")
        XCTAssertGreaterThan(state.membershipGeneration, membership)
        state.set(.visible, of: "2", to: .zero)
        XCTAssertFalse(state.isVisible("1"), "a hidden parent hides its child")
        XCTAssertFalse(state.setParent("2", to: "1"))
        XCTAssertNil(state.parentID(of: "2"))
        XCTAssertFalse(state.setParent("1", to: "1"))
        XCTAssertNil(state.parentID(of: "1"))
    }

    private static func document(script: String? = nil) throws -> WPESceneDocument {
        let alpha: Any = if let script {
            ["value": 1, "script": script]
        } else {
            1
        }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 1, "name": "A", "image": "models/a.json", "origin": "4 5 0", "size": "16 16",
                 "color": "0 0 0", "alpha": alpha],
                ["id": 2, "name": "B", "image": "models/b.json", "size": "16 16"],
                ["id": 3, "name": "C", "image": "models/c.json", "size": "16 16"],
            ],
        ]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoTransformScripts() })
    }
}

private final class LogLines {
    var lines: [String] = []
}

private struct NoTransformScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
