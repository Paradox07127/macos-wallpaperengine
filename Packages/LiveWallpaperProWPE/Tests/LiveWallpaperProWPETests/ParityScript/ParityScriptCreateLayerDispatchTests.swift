import Foundation
import LiveWallpaperProWPE
import XCTest

/// thisScene.createLayer converts its argument to the factory's JSON before the host sees it (0x181633290.c).
final class ParityScriptCreateLayerDispatchTests: XCTestCase {
    func testCreateLayerArgumentsMapToFactoryTypeKeys() throws {
        let script = """
        export function init(value) {
          const results = [
            thisScene.createLayer('models/a.json'),
            thisScene.createLayer('models/a.mdl'),
            thisScene.createLayer('particles/p.json'),
            thisScene.createLayer('materials/m.json'),
            thisScene.createLayer('sounds/s.mp3'),
            thisScene.createLayer('foo/x.json'),
            thisScene.createLayer('/models/b.JSON'),
            thisScene.createLayer('Models/c.json'),
            thisScene.createLayer('{"image":"models/d.json","alpha":0.5}'),
            thisScene.createLayer({ color: '1 0 0' }),
            thisScene.createLayer({ color: '1 0 0', image: 'models/e.json' }),
            thisScene.createLayer(),
            thisScene.createLayer('models/a.json', 1),
            thisScene.createLayer(5),
            thisScene.createLayer(true),
            thisScene.createLayer(null),
            thisScene.createLayer('{"color":"0 1 0"}')
          ];
          if (!results.every(result => result === null)) throw Error('host rejected every layer');
          return value;
        }
        """
        let received = try dispatch(script)
        let solid = "models/util/solidlayer.json"
        let expected: [[String: Any]] = [
            ["image": "models/a.json"],
            ["model": "models/a.mdl"],
            ["particle": "particles/p.json"],
            ["sprite": "materials/m.json"],
            ["sound": "sounds/s.mp3"],
            ["image": "models/b.JSON"],
            ["image": "models/d.json", "alpha": 0.5],
            ["color": "1 0 0", "image": solid],
            ["color": "1 0 0", "image": "models/e.json"],
            ["image": solid],
            ["image": solid],
            ["color": "0 1 0", "image": solid],
        ]
        XCTAssertEqual(received.count, expected.count, "\(received)")
        for (index, (actual, wanted)) in zip(received, expected).enumerated() {
            XCTAssertEqual(actual as NSDictionary, wanted as NSDictionary, "call \(index)")
        }
    }

    private func dispatch(_ script: String) throws -> [[String: Any]] {
        let objects: [[String: Any]] = [["id": 1, "name": "L1", "image": "models/a.json", "size": "64 64",
                                         "alpha": ["value": 1, "script": script]]]
        let json: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                   "general": ["orthogonalprojection": ["width": 64, "height": 64]],
                                   "objects": objects]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var received: [[String: Any]] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            createLayer: { text, _ in
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                received.append(object ?? ["unparsed": text])
                return nil
            }
        ))
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        return received
    }
}
