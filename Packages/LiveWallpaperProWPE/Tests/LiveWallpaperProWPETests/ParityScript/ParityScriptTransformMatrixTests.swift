import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityScriptTransformMatrixTests: XCTestCase {
    /// A same-callback origin write reaches the handler's state before it answers; text logs and returns undefined.
    func testGetTransformMatrixSeesSameCallbackWriteAndTextIsUnsupported() throws {
        let imageScript = """
        export function init(value) {
          thisLayer.origin = new Vec3(3, 4, 5);
          thisLayer.alpha = thisLayer.getTransformMatrix().m[12] / 10;
          return value;
        }
        """
        let textScript = """
        export function init(value) {
          if (thisLayer.getTransformMatrix() !== undefined) throw new Error('text matrix');
          return value;
        }
        """
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 1, "image": "models/a.json", "size": "64 64", "alpha": 1,
                 "brightness": ["value": 1, "script": imageScript]],
                ["id": 2, "text": ["value": "seed", "script": textScript]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var logs: [String] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            log: { _, message in logs.append(message) }
        ))
        var queried: [(String, WPEParityScriptLayerKind)] = []
        engine.transformMatrixHandler = { id, kind, state in
            queried.append((id, kind))
            guard let origin = state.object(id)?.origin else { return nil }
            var matrix = matrix_identity_float4x4
            matrix.columns.3 = SIMD4(origin, 1)
            return matrix
        }
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(state.object("1")?.alpha), 0.3, accuracy: 0.000001)
        XCTAssertEqual(queried.map(\.0), ["1"])
        XCTAssertEqual(queried.map(\.1), [.image])
        XCTAssertEqual(logs.filter { $0.contains("getTransformMatrix") }.count, 1, logs.joined(separator: "\n"))
    }
}
