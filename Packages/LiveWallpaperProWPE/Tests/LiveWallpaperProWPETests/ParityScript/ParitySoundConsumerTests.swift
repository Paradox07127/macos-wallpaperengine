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
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        // The original Windows 22-event script is unchanged; this extra Mac witness checks lexical capture.
        let observationsScript = try String(contentsOf: fixture.deletingLastPathComponent()
            .appendingPathComponent("sound-globals-v1.js"), encoding: .utf8)
        let probeScript = "const savedSoundGlobal = thisObject;\n" + observationsScript + #"""

        let aliasTimerQueued = false;
        let aliasTimerObserved = false;
        export function animationEvent(event, value) {
          if (savedSoundGlobal !== null || thisObject === null || thisObject !== thisLayer)
            throw new Error('sound alias capture');
          if (aliasTimerQueued && !aliasTimerObserved) throw new Error('sound alias timer missing');
          if (!aliasTimerQueued) {
            aliasTimerQueued = true;
            engine.setTimeout(function () {
              if (savedSoundGlobal !== null || thisObject === null || thisObject !== thisLayer)
                throw new Error('sound timer aliases');
              aliasTimerObserved = true;
            }, 0);
          }
        }
        """#
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [
                ["id": 1, "sound": ["tone.wav"], "volume": ["value": 0, "script": script],
                 "mintime": 2, "maxtime": 4],
                ["id": 2, "image": "models/test.json", "alpha": ["value": 1, "script": "export function init(v) { return 0.7; }"]],
                ["id": 3, "sound": ["tone.wav"], "volume": ["value": 0, "script": probeScript],
                 "playbackmode": "loop", "mintime": 0.25, "maxtime": 0.75],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in SoundNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let base = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? base : nil
        }])
        var writes: [(String, String, WPEParityScriptEngine.SoundFields)] = []
        var commands: [(String, WPEParityScriptEngine.SoundCommand, WPEParityScriptEngine.SoundFields)] = []
        var observations: [[String: Any]] = []
        let engine = try WPEParityScriptEngine.prepare(document: document, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100), log: { _, message in
                let prefix = "AUDIT_SS_01A13310 "
                if message.hasPrefix(prefix), let data = message.dropFirst(prefix.count).data(using: .utf8),
                   let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    observations.append(row)
                }
            }
        ), volume: { writes.append(("prepare", $0, $1)) }, command: { id, command, fields in
            commands.append((id, command, fields))
            return id == "1" && command == .isPlaying
        })
        XCTAssertEqual(observations.count, 11)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(state.scriptField("volume", of: "3"), .vector(.zero))
        var soundGeneration = 0
        try engine.withSoundConsumers(volume: { writes.append(("outer", $0, $1)) }, command: { id, command, fields in
            commands.append((id, command, fields))
            return id == "1" && command == .isPlaying
        }, body: {
            XCTAssertNil(engine.start(state: &state))
            soundGeneration = state.generation(.soundGain)
            let inner = {
                try engine.withSoundConsumers(volume: { writes.append(("inner", $0, $1)) },
                                              command: { _, _, _ in false }, body: {
                                                  engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
                                                  throw ScopeExit.forced
                                              })
            }
            XCTAssertThrowsError(try inner())
            engine.tick(dt: 0, state: &state)
        })
        // Leaving a scope must not retain its consumer or replay an equal return at a later flush.
        engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
        engine.withSoundConsumers(volume: { writes.append(("final", $0, $1)) }, command: { _, _, _ in false }, body: {
            engine.dispatch(.animationEvent, payloadJSON: "{}", state: &state)
        })
        XCTAssertEqual(writes.map(\.0), ["outer", "outer", "outer", "inner", "outer", "final"])
        XCTAssertEqual(writes.map(\.1), [String](repeating: "1", count: 6))
        XCTAssertEqual(writes.map(\.2.volume.bitPattern), [UInt32](repeating: Float(0.3).bitPattern, count: 6))
        XCTAssertEqual(writes.map(\.2.minTime), [2, 9, 9, 12, 6, 12])
        XCTAssertEqual(writes.map(\.2.maxTime), [4, 4, 4, 4, 6, 6])
        let soundCommands = commands.filter { $0.0 == "1" }
        XCTAssertEqual(soundCommands.map(\.1), [.play, .isPlaying, .pause, .stop])
        XCTAssertEqual(soundCommands.map(\.2.minTime), [6, 6, 6, 6])
        XCTAssertEqual(soundCommands.map(\.2.maxTime), [6, 6, 6, 6])
        let probeCommands = commands.filter { $0.0 == "3" }
        XCTAssertEqual(probeCommands.map(\.1), [.isPlaying, .isPlaying, .isPlaying, .isPlaying])
        XCTAssertEqual(probeCommands.map(\.2.volume), [0, 0, 0, 0])
        XCTAssertEqual(state.scriptField("volume", of: "3"), .vector(.zero))
        XCTAssertEqual(state.generation(.soundGain), soundGeneration)
        XCTAssertEqual(state.scriptField("mintime", of: "1"), .vector(SIMD4(12, 0, 0, 0)))
        XCTAssertEqual(state.object("2")?.alpha, Float(0.7))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))

        let fields = ["thisObject.volume", "thisLayer.volume", "thisObject.isPlaying", "thisLayer.isPlaying"]
        let events = ["module-global", "global.alias-identity"] + fields.map { "global.before." + $0 }
            + ["global.thisObject.volume-write"] + fields.map { "global.after." + $0 }
            + ["init.enter"] + fields.map { "init." + $0 } + ["update.enter"] + fields.map { "update." + $0 }
            + ["case-complete-observations-only"]
        XCTAssertEqual(observations.compactMap { $0["event"] as? String }, events)
        XCTAssertEqual(observations.compactMap { $0["seq"] as? Int }, Array(1 ... 22))
        XCTAssertEqual(observations.compactMap { $0["frame"] as? Int }, [Int](repeating: 0, count: 16) + [Int](repeating: 1, count: 6))
        let module = try XCTUnwrap(observations.first?["detail"] as? [String: Any])
        XCTAssertEqual(module["thisObjectType"] as? String, "object")
        XCTAssertEqual(module["thisLayerType"] as? String, "object")
        for row in observations {
            let event = try XCTUnwrap(row["event"] as? String)
            let detail = try XCTUnwrap(row["detail"] as? [String: Any])
            if event == "global.alias-identity" {
                XCTAssertEqual(detail["value"] as? Bool, true)
            } else if event.hasPrefix("global.") {
                XCTAssertEqual(detail["outcome"] as? String, "exception")
                let error = try XCTUnwrap(detail["error"] as? [String: Any])
                XCTAssertEqual(error["name"] as? String, "TypeError")
                XCTAssertEqual(error["instanceofError"] as? Bool, true)
                let message = try XCTUnwrap(error["message"] as? String)
                XCTAssertFalse(message.isEmpty)
                // JavaScriptCore supplies this message; it is not manually matched to V8's wording.
                print("S10 sound globals JSC \(event): \(message)")
            } else if event.hasPrefix("init.this") || event.hasPrefix("update.this") {
                XCTAssertEqual(detail["outcome"] as? String, "return")
                if event.hasSuffix("volume") {
                    XCTAssertEqual(detail["resultType"] as? String, "number")
                    XCTAssertEqual(detail["value"] as? Double, 0)
                } else {
                    XCTAssertEqual(detail["resultType"] as? String, "boolean")
                    XCTAssertEqual(detail["value"] as? Bool, false)
                }
            }
        }
    }
}

private enum ScopeExit: Error { case forced }

private struct SoundNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
