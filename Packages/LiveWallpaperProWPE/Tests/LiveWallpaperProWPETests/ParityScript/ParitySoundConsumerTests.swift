import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParitySoundConsumerTests: XCTestCase {
    func testAcceptedSoundWritesAndCommandsPreserveScopedOrdering() throws {
        let script = #"""
        export function init(value) {
          thisObject.mintime = 2;
          thisObject.maxtime = 4;
          thisObject.volume = 0.3;
          thisObject.mintime = 9;
          thisObject.volume = 0.3;
          thisObject.volume = '0.6';
          const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(thisObject), 'volume').set;
          set.call({ __index: thisObject.__index, __base: thisObject.__base }, 0.8);
          return 0.3;
        }
        export function update(value) {
          thisObject.mintime = 6;
          thisObject.maxtime = 6;
          if (thisObject.play() !== undefined || thisObject.isPlaying() !== true ||
              thisObject.pause() !== undefined || thisObject.stop() !== undefined) throw new Error('sound returns');
          return value;
        }
        export function animationEvent(event, value) {
          thisObject.mintime = 12;
          return value;
        }
        """#
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [
                ["id": 1, "sound": ["tone.wav"], "volume": ["value": 0, "script": script],
                 "mintime": 2, "maxtime": 4],
                ["id": 2, "image": "models/test.json", "alpha": ["value": 1, "script": "export function init(v) { return 0.7; }"]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in SoundNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let base = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? base : nil
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100)
        ))
        var writes: [(String, String, WPEParityScriptEngine.SoundFields)] = []
        var commands: [(String, WPEParityScriptEngine.SoundCommand, WPEParityScriptEngine.SoundFields)] = []
        var soundGeneration = 0
        engine.withSoundConsumers(volume: { writes.append(("outer", $0, $1)) }, command: { id, command, fields in
            commands.append((id, command, fields))
            return command == .isPlaying
        }) {
            XCTAssertNil(engine.start(state: &state))
            soundGeneration = state.generation(.soundGain)
            XCTAssertThrowsError(try engine.withSoundConsumers(volume: { writes.append(("inner", $0, $1)) },
                                                               command: { _, _, _ in false }) {
                    engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
                    throw ScopeExit.forced
                })
            engine.tick(dt: 0, state: &state)
        }
        // Leaving a scope must not retain its consumer or replay an equal return at a later flush.
        engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
        engine.withSoundConsumers(volume: { writes.append(("final", $0, $1)) }, command: { _, _, _ in false }) {
            engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
        }
        XCTAssertEqual(writes.map(\.0), ["outer", "outer", "outer", "inner", "outer", "final"])
        XCTAssertEqual(writes.map(\.1), [String](repeating: "1", count: 6))
        XCTAssertEqual(writes.map(\.2.volume.bitPattern), [UInt32](repeating: Float(0.3).bitPattern, count: 6))
        XCTAssertEqual(writes.map(\.2.minTime), [2, 9, 9, 12, 6, 12])
        XCTAssertEqual(writes.map(\.2.maxTime), [4, 4, 4, 4, 6, 6])
        XCTAssertEqual(commands.map(\.0), [String](repeating: "1", count: 4))
        XCTAssertEqual(commands.map(\.1), [.play, .isPlaying, .pause, .stop])
        XCTAssertEqual(commands.map(\.2.minTime), [6, 6, 6, 6])
        XCTAssertEqual(commands.map(\.2.maxTime), [6, 6, 6, 6])
        XCTAssertEqual(state.generation(.soundGain), soundGeneration)
        XCTAssertEqual(state.scriptField("mintime", of: "1"), .vector(SIMD4(12, 0, 0, 0)))
        XCTAssertEqual(state.object("2")?.alpha, Float(0.7))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }
}

private enum ScopeExit: Error { case forced }

private struct SoundNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
