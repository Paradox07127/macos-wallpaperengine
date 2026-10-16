import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParityScriptWorkshopPathTests: XCTestCase {
    /// A string createLayer path is rewritten under the calling module's string `__workshopId`.
    func testCreateLayerStringPathUsesTheCallingModuleWorkshopID() throws {
        let scripts = [
            ("export const __workshopId = '2652493753';", "models/bar.json"),
            ("export const __workshopId = '2981960200';", "models/workshop/2652493753/bar.json"),
            ("export const __workshopId = '2652493753';", "/models\\\\bar.json"),
            ("", "models/bar.json"),
            ("", "//models/plain.json"),
            ("export const __workshopId = 2652493753;", "models/bar.json"),
            ("export const __workshopId = '';", "models/bar.json"),
        ]
        let objects: [[String: Any]] = scripts.enumerated().map { offset, entry in
            let script = entry.0 + "\nexport function init(value) { thisScene.createLayer('\(entry.1)'); return value; }"
            return ["id": offset + 1, "name": "L\(offset + 1)", "image": "models/a.json", "size": "64 64",
                    "alpha": ["value": 1, "script": script]]
        }
        let json: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                   "general": ["orthogonalprojection": ["width": 64, "height": 64]],
                                   "objects": objects]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var received: [String] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            createLayer: { text, _ in
                received.append(text)
                return nil
            }
        ))
        try engine.start(state: &state)
        XCTAssertEqual(received, [
            #"{"image":"models/workshop/2652493753/bar.json"}"#,
            #"{"image":"models/workshop/2981960200/bar.json"}"#,
            #"{"image":"models/workshop/2652493753/bar.json"}"#,
            #"{"image":"models/bar.json"}"#,
            #"{"image":"models/plain.json"}"#,
            #"{"image":"models/bar.json"}"#,
            #"{"image":"models/bar.json"}"#,
        ])
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
