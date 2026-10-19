import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// SceneScript ITextureAnimation: getTextureAnimation() on image layers drives the layer's sprite-sheet state.
final class ParityScriptTextureAnimationTests: XCTestCase {
    func testStoppedWrapperIsCachedAndReportsItsOwnFrame() throws {
        let script = """
        export function init(value) {
          const a = thisLayer.getTextureAnimation();
          a.stop();
          a.setFrame(1);
          thisLayer.alpha = (a === thisLayer.getTextureAnimation() && !a.isPlaying() && a.getFrame() === 1) ? 1 : 0;
          return value;
        }
        """
        let (engine, initial, _) = try Self.scene(imageScript: script)
        var state = initial
        var animation = WPEParityTextureAnimation()
        engine.textureAnimationHandler = { id, command, value in
            guard id == "1" else { return nil }
            return animation.perform(command, value: value, shared: (frame: 0, time: 0), durations: [0.5, 0.5])
        }
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 1)
        XCTAssertEqual(animation.frame, 1)
        XCTAssertFalse(animation.isPlaying)
    }

    /// No sprite sheet, or no product consumer, answers null and never throws; other layer kinds have no method.
    func testNoSpriteAnswersNullAndTextLayersHaveNoMethod() throws {
        let script = """
        export function init(value) {
          thisLayer.alpha = thisLayer.getTextureAnimation() === null ? 0.5 : 0;
          return value;
        }
        """
        let textScript = """
        export function init(value) {
          if (thisLayer.getTextureAnimation !== undefined) throw new Error('text layer method');
          return value;
        }
        """
        let (unbound, initial, logs) = try Self.scene(imageScript: script, textScript: textScript)
        var state = initial
        try unbound.start(state: &state)
        XCTAssertEqual(unbound.exceptionCount, 0, unbound.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 0.5)
        XCTAssertEqual(logs().filter { $0.contains("getTextureAnimation is unsupported") }.count, 1)

        let (engine, plain, _) = try Self.scene(imageScript: script)
        state = plain
        engine.textureAnimationHandler = { _, _, _ in nil }
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 0.5)
    }

    private static func scene(imageScript: String, textScript: String? = nil) throws
        -> (WPEParityScriptEngine, WPEParitySceneState, () -> [String]) {
        var objects: [[String: Any]] = [
            ["id": 1, "image": "models/a.json", "size": "64 64", "alpha": 1,
             "brightness": ["value": 1, "script": imageScript]],
        ]
        if let textScript {
            objects.append(["id": 2, "text": ["value": "seed", "script": textScript]])
        }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        final class Log {
            var messages: [String] = []
        }
        let log = Log()
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            log: { _, message in log.messages.append(message) }
        ))
        return (engine, state, { log.messages })
    }
}
