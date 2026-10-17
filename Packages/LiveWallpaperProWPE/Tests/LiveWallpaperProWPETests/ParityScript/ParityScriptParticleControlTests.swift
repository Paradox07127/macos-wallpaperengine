import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// SceneScript IParticleSystem methods on a particle layer, driven against the same scene's particle systems.
final class ParityScriptParticleControlTests: XCTestCase {
    /// Workshop 2097549174's `cursor` visible script, line by line (tabs and trailing spaces kept).
    private static let cursorScript = [
        "'use strict';",
        "// Please note: Do not remove this line or asset references may break.",
        "export let __workshopId = '2097549174';",
        "",
        "export var scriptProperties = createScriptProperties()",
        "\t.addSlider({",
        "\t\tname: 'sleepTimer',",
        "\t\tlabel: 'Snooze Time',",
        "\t\tvalue: 7,",
        "\t\tmin: 0,",
        "\t\tmax: 100,",
        "\t\tinteger: false",
        "\t})",
        "\t.finish();",
        "",
        "let start;",
        "",
        "",
        "/**",
        " * @param {Boolean} value (for property 'visible')",
        " */",
        "export function update(value) {",
        "\tif(((engine.runtime)-start )>=scriptProperties.sleepTimer){",
        "\t\tthisScene.getLayer('zzz').play(); ",
        "} ",
        "    return value;",
        "}",
        "",
        "export function cursorMove(event) {",
        "\tthisScene.getLayer('zzz').stop();",
        "\tstart = engine.runtime;",
        "}",
        "",
        "",
        "",
        "",
    ].joined(separator: "\n")

    private static let zzz = """
    {"maxcount": 3, "material": "materials/plain.json",
     "emitter": [{"name": "sphererandom", "rate": 1.2, "distancemax": 0}],
     "initializer": [{"name": "lifetimerandom", "min": 1, "max": 3}],
     "renderer": [{"name": "sprite"}]}
    """

    private static let cursorPayload = #"{"world":[0,0,0],"local":[0,0,0],"hitBox":null}"#

    final class Particles {
        var scene: WPEParityParticleScene

        init(_ scene: WPEParityParticleScene) {
            self.scene = scene
        }
    }

    func testCursorMoveStopsTheZzzParticlesAndIdlePlayRestartsThem() throws {
        let (engine, initial, _, particles) = try Self.scene()
        var state = initial
        engine.particleSystemHandler = { id, command, count in
            particles.scene.control(objectID: id) { system in
                switch command {
                case .play: system.play()
                case .pause: system.pause()
                case .stop: system.stop()
                case .isPlaying: return system.isPlaying ? 1 : 0
                case .emitParticles: system.emitParticles(count)
                }
                return 0
            }
        }
        try engine.start(state: &state)
        func run(seconds: Int) {
            for _ in 0 ..< seconds * 30 {
                particles.scene.advance(dt: 1 / 30, frames: ["70": .init()])
                engine.tick(dt: 1 / 30, state: &state)
            }
        }
        run(seconds: 3)
        XCTAssertGreaterThan(try XCTUnwrap(particles.scene.liveCount("70")), 0)
        engine.dispatch(.cursorMove, payloadJSON: Self.cursorPayload, target: "75", state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(particles.scene.liveCount("70"), 0)
        run(seconds: 6)
        XCTAssertEqual(particles.scene.liveCount("70"), 0, "stop keeps the emitter off until play")
        for _ in 0 ..< 75 {
            particles.scene.advance(dt: 1 / 30, frames: ["70": .init()])
            engine.tick(dt: 1 / 30, state: &state)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(particles.scene.liveCount("70")), 1, "idle play re-enables the emitter")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testWithoutAParticleConsumerCursorMoveLogsAndDoesNotThrow() throws {
        let (engine, initial, logs, _) = try Self.scene()
        var state = initial
        try engine.start(state: &state)
        engine.dispatch(.cursorMove, payloadJSON: Self.cursorPayload, target: "75", state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertTrue(logs().contains { $0.contains("IParticleSystem methods are unsupported") }, "\(logs())")
    }

    /// Image 75 carries the cursor script; particle 70 is the `zzz` layer it controls.
    private static func scene() throws -> (WPEParityScriptEngine, WPEParitySceneState, () -> [String], Particles) {
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 70, "name": "zzz", "particle": "particles/zzz.json"],
                ["id": 75, "name": "cursor", "image": "models/cursor.json", "size": "64 64",
                 "visible": ["value": true, "script": cursorScript, "scriptproperties": ["sleepTimer": 7]]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let files: [String: Data] = try [
            "scripts/jsclasses/baseclasses.js": Data(contentsOf: fixture),
            "particles/zzz.json": Data(zzz.utf8),
            "materials/plain.json": Data(#"{"passes": [{"shader": "genericparticle"}]}"#.utf8),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { files[$0] }])
        final class Log {
            var messages: [String] = []
        }
        let log = Log()
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            log: { _, message in log.messages.append(message) }
        ))
        let particles = Particles(WPEParityParticleScene(document: document, assets: assets,
                                                         engineFlags: WPEEngineComboFlags(), seed: 7))
        return (engine, state, { log.messages }, particles)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
