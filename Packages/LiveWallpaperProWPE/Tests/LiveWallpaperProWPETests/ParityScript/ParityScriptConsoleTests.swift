import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptConsoleTests: XCTestCase {
    /// log/info/debug report level 0, warn 1, error 2; arguments go through String() joined by single spaces.
    func testConsoleMethodsReportTheirLevelAndStringifiedArguments() throws {
        let script = """
        export function init(value) {
          console.log('a', 1, { x: 1 });
          console.info('b', true);
          console.debug('c', null);
          console.warn('d', undefined);
          console.error('e', [1, 2]);
          return value;
        }
        """
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "image": "models/a.json", "size": "64 64",
                         "alpha": ["value": 1, "script": script]]],
        ]), userValues: [:])
        var state = WPEParitySceneState(document: document, hdr: false)
        var logs: [String] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.assets(), canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            log: { level, message in logs.append("\(level) \(message)") }
        ))
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(logs, ["0 a 1 [object Object]", "0 b true", "0 c null", "1 d undefined", "2 e 1,2"])
    }

    private static func assets() throws -> WPEParityProgramAssets {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        return WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
    }
}
