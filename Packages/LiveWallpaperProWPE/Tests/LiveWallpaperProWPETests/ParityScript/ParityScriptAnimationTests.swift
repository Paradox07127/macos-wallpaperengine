import Foundation
import LiveWallpaperProWPE
import XCTest

/// SceneScript IAnimation: getAnimation(name) on layers and material wrappers drives the scene's keyframe bindings.
final class ParityScriptAnimationTests: XCTestCase {
    private struct Scene {
        var state: WPEParitySceneState
        var animations: WPEParitySceneAnimations
        let engine: WPEParityScriptEngine

        mutating func frame(_ dt: Float) {
            animations.advance(dt: dt, state: &state)
            engine.tick(dt: dt, state: &state)
        }
    }

    func testLookupReturnsOneCachedWrapperPerBindingAndUndefinedForAnUnknownName() throws {
        var scene = try Self.scene(alpha: Self.animated(name: "fade", script: """
        export function init(value) {
            const fade = thisLayer.getAnimation('fade');
            if (!fade || fade !== thisObject.getAnimation('fade')) throw new Error('identity');
            if (thisLayer.getAnimation('missing') !== undefined) throw new Error('missing name');
            const plain = thisLayer.getAnimation();
            if (!plain || plain === fade || plain !== thisLayer.getAnimation(7)) throw new Error('empty name');
            if (plain.name !== '' || fade.name !== 'fade') throw new Error('names');
            return 0.75;
        }
        """), brightness: Self.animated(name: nil))
        try scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(scene.state.object("1")?.alpha, 0.75)
    }

    func testMembersAndPlaybackMethodsDriveTheBindingClock() throws {
        var scene = try Self.scene(alpha: Self.animated(name: "fade", script: """
        let n = 0, fade;
        export function init(value) {
            fade = thisLayer.getAnimation('fade');
            if (fade.fps !== 8 || fade.frameCount !== 8 || fade.duration !== 1 || fade.rate !== 1)
                throw new Error('members ' + [fade.fps, fade.frameCount, fade.duration, fade.rate]);
            if (fade.isPlaying()) throw new Error('startpaused plays');
            fade.setFrame(2);
            if (fade.getFrame() !== 2) throw new Error('setFrame ' + fade.getFrame());
            fade.play();
            if (!fade.isPlaying()) throw new Error('play');
        }
        export function update(value) {
            n += 1;
            if (n === 1) fade.pause();
            if (n === 2) {
                if (fade.isPlaying() || fade.getFrame() !== 3) throw new Error('pause ' + fade.getFrame());
                fade.stop();
            }
            if (n === 3) {
                if (fade.isPlaying() || fade.getFrame() !== 0) throw new Error('stop');
                fade.play();
            }
        }
        """))
        try scene.engine.start(state: &scene.state)
        var alphas: [Float] = []
        for _ in 0 ..< 4 {
            scene.frame(0.125)
            try alphas.append(XCTUnwrap(scene.state.object("1")?.alpha))
        }
        for (alpha, expected) in zip(alphas, [Float(0.375), 0.375, 0, 0.125]) {
            XCTAssertEqual(alpha, expected, accuracy: Self.accuracy, "\(alphas)")
        }
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testPlayAfterAFinishedSingleRestartsAtZero() throws {
        var scene = try Self.scene(alpha: Self.animated(name: "once", mode: "single", paused: false, script: """
        let n = 0;
        export function update(value) {
            const once = thisLayer.getAnimation('once');
            if (++n !== 1) return;
            if (once.isPlaying()) throw new Error('finished plays');
            once.play();
        }
        """))
        try scene.engine.start(state: &scene.state)
        scene.frame(1.5)
        XCTAssertGreaterThan(scene.state.object("1")?.alpha ?? 0, 0.85)
        scene.frame(0.25)
        XCTAssertEqual(scene.state.object("1")?.alpha ?? 0, 0.25, accuracy: Self.accuracy)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testRateTwoDoublesProgress() throws {
        var scene = try Self.scene(alpha: Self.animated(name: "fade", paused: false, script: """
        export function init(value) {
            const fade = thisLayer.getAnimation('fade');
            fade.rate = 2;
            fade.rate = 'fast';
            if (fade.rate !== 2) throw new Error('rate ' + fade.rate);
        }
        """))
        try scene.engine.start(state: &scene.state)
        scene.frame(0.125)
        XCTAssertEqual(scene.state.object("1")?.alpha ?? 0, 0.25, accuracy: Self.accuracy)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// A constant script's bare getAnimation() reaches its own pass's animation, not the layer's.
    func testConstantScriptReachesItsOwnPassAnimation() throws {
        let pass = WPEParityMaterialPassKey(objectID: "1", effectID: "5")
        let constant = Self.animated(name: nil, script: """
        export function init(value) {
            const own = thisObject.getAnimation();
            if (!own || own === thisLayer.getAnimation()) throw new Error('owner');
            if (Object.keys(thisObject).includes('getAnimation')) throw new Error('enumerable');
            own.play();
        }
        """)
        var scene = try Self.scene(alpha: Self.animated(name: nil), effects: [
            ["id": 5, "file": "effects/x.json", "visible": true, "passes": [["constantshadervalues": ["k": constant]]]],
        ], constants: [pass: ["k": [0]]])
        try scene.engine.start(state: &scene.state)
        scene.frame(0.375)
        XCTAssertEqual(scene.state.constant("k", of: pass)?.value.x ?? 0, 0.375, accuracy: Self.accuracy)
        XCTAssertEqual(scene.state.object("1")?.alpha ?? 1, 0, accuracy: Self.accuracy)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// The keyframe sampler's inverse search stops within 0.01 frame, i.e. 0.00125 of this ramp.
    private static let accuracy: Float = 2e-3

    /// 0→1 over frames 0…8 at 8 fps, so 1 s long; 1/8 keeps the stored frame duration exact.
    private static func animated(name: String?, mode: String = "loop", paused: Bool = true,
                                 script: String? = nil) -> [String: Any] {
        var options: [String: Any] = ["fps": 8, "length": 8, "mode": mode, "startpaused": paused]
        options["name"] = name
        var property: [String: Any] = [
            "value": 0,
            "animation": ["c0": [["frame": 0, "value": 0], ["frame": 8, "value": 1]], "options": options],
        ]
        property["script"] = script
        return property
    }

    private static func scene(alpha: [String: Any], brightness: [String: Any]? = nil, effects: [[String: Any]] = [],
                              constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:]) throws -> Scene {
        var layer: [String: Any] = ["id": 1, "name": "A", "image": "models/a.json", "size": "10 10", "alpha": alpha,
                                    "effects": effects]
        layer["brightness"] = brightness
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [layer],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let state = WPEParitySceneState(document: document, hdr: false, constants: constants)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let animations = WPEParitySceneAnimations(document: document, state: state,
                                                  constantComponents: constants.mapValues { $0.mapValues(\.count) })
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(100, 100), screenResolution: SIMD2(100, 100)
        ))
        engine.propertyAnimationLookup = { animations.animation(objectID: $0, pass: $1, name: $2) }
        return Scene(state: state, animations: animations, engine: engine)
    }
}
