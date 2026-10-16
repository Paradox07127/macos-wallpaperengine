import Foundation
import JavaScriptCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptInputBoundaryTests: XCTestCase {
    private func exportedNames(_ source: String) -> [String] {
        let context = JSContext()!
        let names = context.evaluateScript("""
        (function () { const names = []; const module = \(WPEParityScriptModule.lower(source));
        module(null, name => names.push(name), null, null); return names.join(','); })()
        """).toString() ?? ""
        return names.split(separator: ",").map(String.init)
    }

    func testExportedDeclarationRegistersEveryDeclarator() {
        XCTAssertEqual(exportedNames("export const init = v => v, update = v => v + 1;"), ["init", "update"])
        XCTAssertEqual(exportedNames("export let a = Math.max(1, 2), b = [3, 4], c = { d: 5, e: 6 }, g;"), ["a", "b", "c", "g"])
        XCTAssertEqual(exportedNames("export var s = 'x,y', t = `${1},${2}`\nconst z = 1, w = 2;"), ["s", "t"])
        XCTAssertEqual(exportedNames("export const { p } = { p: 1 }, q = 2;"), ["q"])
    }

    func testScriptSetterIgnoresNonfiniteNumbers() throws {
        let script = """
        export function init(value) {
            thisLayer.pointsize = NaN;
            thisLayer.maxwidth = -Infinity;
            thisLayer.padding = new Vec2(Infinity, NaN);
            thisLayer.padding = new Vec2(1e39, 1);
            thisLayer.spacing = NaN;
            return value;
        }
        """
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "name": "T", "text": "Hi", "alpha": ["value": 1, "script": script]]],
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
        let engine = try WPEParityScriptEngine.prepare(
            document: document, state: &state,
            configuration: .init(assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64)),
            volume: { _, _ in }, command: { _, _, _ in false }
        )
        try engine.start(state: &state)
        XCTAssertEqual(state.scriptField("pointsize", of: "1"), .vector(SIMD4(32, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("maxwidth", of: "1"), .vector(SIMD4(500, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("padding", of: "1"), .vector(SIMD4(32, 32, 0, 0)))
        XCTAssertEqual(state.scriptField("spacing", of: "1"), .vector(.zero))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
