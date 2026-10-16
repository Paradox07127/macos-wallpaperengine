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

    final class Animator {
        var value: WPEParityPuppetAnimator

        init(_ value: WPEParityPuppetAnimator) {
            self.value = value
        }
    }

    /// One bone; animations 7 and 8 loop at 30 fps over 360 frames.
    private static func bind(_ engine: WPEParityScriptEngine, document: WPESceneDocument) -> Animator {
        let keys = (0 ... 360).map {
            WPEPuppetAnimKey(frame: $0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1))
        }
        let animations = [7, 8].map {
            WPEPuppetAnimation(id: $0, name: "a\($0)", mode: "loop", fps: 30, frameCount: keys.count - 1,
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

    private static func scene(rateScript: String? = nil, rateLayer: Int = 1) throws
        -> (WPEParityScriptEngine, WPEParitySceneState, () -> [String], WPESceneDocument) {
        var animationLayers: [[String: Any]] = [
            ["id": 10, "animation": 7, "visible": true],
            ["id": 11, "animation": 8, "additive": true,
             "visible": ["value": true, "script": witness, "scriptproperties": ["percentage": 0.8]]],
        ]
        if let rateScript {
            animationLayers[rateLayer]["rate"] = ["value": 1, "script": rateScript]
        }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": 1, "image": "models/a.json", "size": "64 64", "alpha": 1, "animationlayers": animationLayers],
            ],
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
