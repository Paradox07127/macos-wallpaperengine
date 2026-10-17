import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// SceneScript bindings on puppet `animationlayers[i]` fields, whose thisObject is the IAnimationLayer.
final class ParityScriptAnimationLayerTests: XCTestCase {
    /// Workshop 3808922316's wing-layer script.
    private static let witness = """
    'use strict';

    export var scriptProperties = createScriptProperties()
        .addSlider({
            name: 'percentage',
            label: 'Initial progress',
            value: 1,
            min: 0,
            max: 1,
            integer: false
        })
        .finish();

    export function init(value) {
        const ani = 'addEndedCallback' in thisObject ? thisObject : thisObject.getAnimation()
        ani.play()
        ani.setFrame(ani.frameCount * scriptProperties.percentage)
        return value;
    }
    """

    func testAnimationLayerFieldScriptCompilesAsABinding() throws {
        let (engine, _, _, _) = try Self.scene()
        XCTAssertTrue(engine.bindings.contains {
            $0.objectID == "1" && $0.path == "animationlayers/1/visible" && $0.compiled
        }, "\(engine.bindings.map(\.path))")
    }

    func testWitnessOffsetsOnlyItsOwnLayerFrame() throws {
        let (engine, initial, _, document) = try Self.scene()
        var state = initial
        let animator = Self.bind(engine, document: document)
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(animator.value.layers[1].frame, 288, accuracy: 1e-3)
        XCTAssertEqual(animator.value.layers[0].frame, 0)
        animator.value.advance(dt: 8.552883)
        XCTAssertEqual(animator.value.layers[1].frame, 184.59, accuracy: 0.01)
        XCTAssertEqual(animator.value.layers[0].frame, 256.59, accuracy: 0.01)
    }

    func testThisObjectIsTheAnimationLayerAndThisLayerTheImage() throws {
        let rate = """
        export function init(value) {
          if ('addEndedCallback' in thisObject && thisObject !== thisLayer && thisObject.frameCount === 360)
            thisLayer.alpha = 0.5;
          return value;
        }
        """
        let (engine, initial, _, document) = try Self.scene(rateScript: rate, rateLayer: 0)
        var state = initial
        _ = Self.bind(engine, document: document)
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 0.5)
    }

    func testUpdateReturnWritesTheQualifiedField() throws {
        let rate = "export function update(value) { return 2; }"
        let (engine, initial, _, _) = try Self.scene(rateScript: rate)
        var state = initial
        try engine.start(state: &state)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.scriptField("animationlayers.1.rate", of: "1"), .vector(SIMD4(2, 0, 0, 0)))
    }

    func testWithoutAConsumerTheWitnessLogsAndDoesNotThrow() throws {
        let (engine, initial, logs, _) = try Self.scene()
        var state = initial
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertTrue(logs().contains { $0.contains("IAnimationLayer is unsupported") }, "\(logs())")
    }

    func testGetAnimationLayerUsesThePuppetOrderAndTheLastName() throws {
        let layers: [[String: Any]] = [
            ["id": 10, "animation": 7, "name": "a"],
            ["id": 11, "animation": 99, "name": "ghost"],
            ["id": 12, "animation": 8, "name": "b"],
            ["id": 13, "animation": 7, "name": "b"],
        ]
        let script = """
        export function init(value) {
          const l = thisLayer;
          const missing = [l.getAnimationLayer('ghost'), l.getAnimationLayer(''), l.getAnimationLayer(3),
            l.getAnimationLayer(-1)];
          if (l.getAnimationLayerCount() === 3 && l.getAnimationLayer(1).frameCount === 150
            && l.getAnimationLayer('b').frameCount === 360 && l.getAnimationLayer('a').frameCount === 360
            && missing.every(m => m === undefined))
            thisLayer.alpha = 0.5;
          return value;
        }
        """
        let (engine, initial, _, document) = try Self.scene(animationLayers: layers, visibleScript: script)
        var state = initial
        _ = Self.bind(engine, document: document, animations: [(7, "loop", 360), (8, "single", 150)])
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 0.5)
    }

    /// Workshop 3647999330's object 545 visible script, with the rope's click reduced to the shared flag.
    func testNamedLayersReplayTheSingleAndStopTheLoop() throws {
        let script = """
        'use strict';

        let frameCount = 0;
        let targetFrames = 180;  // 3秒的帧数（假设60fps：60*3=180）

        export function update(value) {
            if (shared.isLogoShakePlaying === true) {
                let logoShakeLayer = thisLayer.getAnimationLayer("LogoShake");
                let sssLayer = thisLayer.getAnimationLayer("sss");

                if (logoShakeLayer && !shared.animationIsPlaying) {
                    // 暂停sss动画
                    if (sssLayer) {
                        sssLayer.stop();
                        shared.sssWasPlaying = true;
                    }

                    // 播放LogoShake动画
                    logoShakeLayer.play();
                    shared.animationIsPlaying = true;
                    frameCount = 0;  // 重置帧计数器
                }
            }

            // 如果LogoShake正在播放，每帧计数
            if (shared.animationIsPlaying) {
                frameCount++;

                // 达到目标帧数时，结束动画
                if (frameCount >= targetFrames) {
                    shared.animationIsPlaying = false;
                    shared.isLogoShakePlaying = false;
                    frameCount = 0;

                    // 恢复sss动画
                    let sssLayer = thisLayer.getAnimationLayer("sss");
                    if (shared.sssWasPlaying && sssLayer) {
                        sssLayer.play();
                    }
                }
            }

            return value;
        }
        """
        let layers: [[String: Any]] = [
            ["id": 10, "animation": 7, "name": "sss"],
            ["id": 11, "animation": 8, "name": "LogoShake"],
        ]
        let (engine, initial, _, document) = try Self.scene(
            animationLayers: layers, visibleScript: script,
            secondObjectScript: "export function cursorClick(event) { shared.isLogoShakePlaying = true; }"
        )
        var state = initial
        let animator = Self.bind(engine, document: document, animations: [(7, "loop", 360), (8, "single", 150)])
        try engine.start(state: &state)
        animator.value.advance(dt: 6)
        engine.dispatch(.cursorClick, payloadJSON: #"{"world":[0,0,0],"local":[0,0,0],"hitBox":null}"#, target: "2",
                        state: &state)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        let (sss, logoShake) = (animator.value.layers[0], animator.value.layers[1])
        XCTAssertFalse(sss.isPlaying)
        XCTAssertEqual(sss.frame, 0)
        XCTAssertTrue(logoShake.isPlaying)
        XCTAssertEqual(logoShake.frame, 0)
        for _ in 0 ..< 179 {
            engine.tick(dt: 1 / 60, state: &state)
        }
        XCTAssertTrue(animator.value.layers[0].isPlaying)
    }

    func testImageWithoutAnimationLayersCountsZero() throws {
        let script = """
        export function init(value) {
          if (thisLayer.getAnimationLayerCount() === 0 && thisLayer.getAnimationLayer(0) === undefined
            && thisLayer.getAnimationLayer('a7') === undefined)
            thisLayer.alpha = 0.5;
          return value;
        }
        """
        let (engine, initial, _, document) = try Self.scene(secondObjectScript: script)
        var state = initial
        _ = Self.bind(engine, document: document)
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("2")?.alpha, 0.5)
    }

    final class Animator {
        var value: WPEParityPuppetAnimator

        init(_ value: WPEParityPuppetAnimator) {
            self.value = value
        }
    }

    /// One bone; by default animations 7 and 8 loop at 30 fps over 360 frames.
    private static func bind(_ engine: WPEParityScriptEngine, document: WPESceneDocument,
                             animations specs: [(id: Int, mode: String, frameCount: Int)] = [(7, "loop", 360), (8, "loop", 360)])
        -> Animator {
        let animations = specs.map { spec in
            let keys = (0 ... spec.frameCount).map {
                WPEPuppetAnimKey(frame: $0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1))
            }
            return WPEPuppetAnimation(id: spec.id, name: "a\(spec.id)", mode: spec.mode, fps: 30,
                                      frameCount: spec.frameCount,
                                      channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys)])
        }
        let identity = (0 ..< 16).map { Float($0 % 5 == 0 ? 1 : 0) }
        let model = WPEPuppetModel(version: 23, meshes: [], bones: [WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identity)],
                                   animations: animations)
        let animator = Animator(WPEParityPuppetAnimator(model: model, layers: document.imageObjects[0].animationLayers))
        engine.animationLayerHandler = { id, index, command, value in
            guard id == "1", let layer = animator.value.layers.first(where: { $0.sceneIndex == index }) else { return nil }
            switch command {
            case .play: animator.value.controlLayer(at: index, action: .play)
            case .pause: animator.value.controlLayer(at: index, action: .pause)
            case .stop: animator.value.controlLayer(at: index, action: .stop)
            case .setFrame: animator.value.controlLayer(at: index, action: .setFrame(Float(value)))
            case .isPlaying: return layer.isPlaying ? 1 : 0
            case .getFrame: return Double(layer.frame)
            case .fps: return Double(layer.fps)
            case .frameCount: return Double(layer.animation.frameCount)
            case .duration: return Double(layer.duration)
            }
            return 0
        }
        return animator
    }

    /// Object 2 is an image without animation layers, present only with `secondObjectScript` on its `visible`.
    private static func scene(rateScript: String? = nil, rateLayer: Int = 1, animationLayers authored: [[String: Any]]? = nil,
                              visibleScript: String? = nil, secondObjectScript: String? = nil) throws
        -> (WPEParityScriptEngine, WPEParitySceneState, () -> [String], WPESceneDocument) {
        var animationLayers: [[String: Any]] = authored ?? [
            ["id": 10, "animation": 7, "visible": true],
            ["id": 11, "animation": 8, "additive": true,
             "visible": ["value": true, "script": witness, "scriptproperties": ["percentage": 0.8]]],
        ]
        if let rateScript {
            animationLayers[rateLayer]["rate"] = ["value": 1, "script": rateScript]
        }
        var first: [String: Any] = ["id": 1, "image": "models/a.json", "size": "64 64", "alpha": 1,
                                    "animationlayers": animationLayers]
        if let visibleScript {
            first["visible"] = ["value": true, "script": visibleScript]
        }
        var objects = [first]
        if let secondObjectScript {
            objects.append(["id": 2, "image": "models/b.json", "size": "64 64", "alpha": 1,
                            "visible": ["value": true, "script": secondObjectScript]])
        }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
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
        return (engine, state, { log.messages }, document)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
