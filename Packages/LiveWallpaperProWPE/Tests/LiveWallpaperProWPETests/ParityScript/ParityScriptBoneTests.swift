import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

/// IImageLayer bone and blend-shape methods on object 1, whose puppet animates bone 0 and blend shape 1, and on
/// object 2, an image without a puppet.
final class ParityScriptBoneTests: XCTestCase {
    private static let methods = [
        "getBoneCount", "getBoneIndex", "getBoneParentIndex", "getBoneTransform", "setBoneTransform",
        "getLocalBoneTransform", "setLocalBoneTransform", "getLocalBoneAngles", "setLocalBoneAngles",
        "getLocalBoneOrigin", "setLocalBoneOrigin", "applyBonePhysicsImpulse", "resetBonePhysicsSimulation",
        "getBlendShapeIndex", "getBlendShapeWeight", "setBlendShapeWeight",
    ]
    /// The layer's vfunc+0x80 matrix the handler answers for object 1.
    private static let object = translation(100, 200, 0)
    /// Bone 0's animated local: its key's translation, then 0.5 rad about Z.
    private static let animatedRoot = translation(10, 0, 0) * simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1)))

    func testEveryMethodExistsOnImageLayers() throws {
        let check = """
        export function init(value) {
          const names = \(Self.methods);
          const missing = names.filter(n => typeof thisLayer[n] !== 'function');
          if (missing.length) throw new Error('missing ' + missing.join(','));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: check, plainScript: check)
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testGettersAnswerTheAnimatedPose() throws {
        let script = """
        export function init(value) {
          const l = thisLayer;
          console.log(JSON.stringify({
            count: l.getBoneCount(), tip: l.getBoneIndex('tip'), missing: l.getBoneIndex('none'),
            parent: l.getBoneParentIndex('tip'), rootParent: l.getBoneParentIndex(0),
            angles: l.getLocalBoneAngles('root'), origin: l.getLocalBoneOrigin(0),
            local: l.getLocalBoneTransform(0).m, world: l.getBoneTransform('tip').m,
            blink: l.getBlendShapeIndex('blink'), weight: l.getBlendShapeWeight('blink'),
            unresolved: [l.getBoneTransform(2), l.getLocalBoneAngles(''), l.getBlendShapeWeight(5),
              l.getLocalBoneOrigin(-1), l.getBoneParentIndex(1.5)].map(v => v === undefined)
          }));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        let result = try scene.result()
        XCTAssertEqual(result["count"] as? Double, 2)
        XCTAssertEqual(result["tip"] as? Double, 1)
        XCTAssertEqual(result["missing"] as? Double, -1)
        XCTAssertEqual(result["parent"] as? Double, 0)
        XCTAssertEqual(result["rootParent"] as? Double, -1)
        let angles = try XCTUnwrap(result["angles"] as? [String: Double])
        XCTAssertEqual(angles["x"] ?? .nan, 0, accuracy: 1e-5)
        XCTAssertEqual(angles["y"] ?? .nan, 0, accuracy: 1e-5)
        XCTAssertEqual(angles["z"] ?? .nan, 0.5, accuracy: 1e-5)
        XCTAssertEqual(result["origin"] as? [String: Double], ["x": 10, "y": 0, "z": 0])
        try Self.assertMatrix(result["local"], Self.animatedRoot)
        try Self.assertMatrix(result["world"], Self.object * scene.animator.value.boneWorld[1])
        try Self.assertMatrix(result["world"], Self.object * Self.animatedRoot * Self.translation(0, 5, 0))
        XCTAssertEqual(result["blink"] as? Double, 1)
        XCTAssertEqual(result["weight"] as? Double ?? .nan, 0.25, accuracy: 1e-6)
        XCTAssertEqual(result["unresolved"] as? [Bool], [true, true, true, true, true])
    }

    func testLocalWritesReachThePaletteUntilTheNextUpdate() throws {
        let script = """
        export function init(value) {
          const l = thisLayer;
          l.setLocalBoneTransform('root', new Mat4([2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 1, 2, 3, 1]));
          l.setLocalBoneOrigin(1, new Vec3(7, 8, 9));
          console.log(JSON.stringify({ root: l.getLocalBoneTransform(0).m, tip: l.getLocalBoneOrigin('tip') }));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        let before = scene.animator.value.bones
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        var root = matrix_identity_float4x4 * 2
        root.columns.3 = SIMD4(1, 2, 3, 1)
        let result = try scene.result()
        try Self.assertMatrix(result["root"], root)
        XCTAssertEqual(result["tip"] as? [String: Double], ["x": 7, "y": 8, "z": 9])
        let world = scene.animator.value.boneWorld
        Self.assertEqual(world[0], root)
        Self.assertEqual(world[1], root * Self.translation(7, 8, 9))
        XCTAssertNotEqual(scene.animator.value.bones, before)
        // 1401fdf90.c:1506 rewrites every bone local from the animation on each update.
        scene.animator.value.advance(dt: 1 / 30)
        Self.assertEqual(scene.animator.value.boneWorld[0], Self.animatedRoot)
    }

    func testWorldWriteIsUndoneByTheLayerMatrixAndTheParent() throws {
        let target = Self.translation(150, 260, 4)
        let script = """
        export function init(value) {
          thisLayer.setBoneTransform('tip', new Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 150, 260, 4, 1]));
          thisLayer.setBoneTransform(0, thisLayer.getBoneTransform(0).translation(new Vec3(130, 210, 0)));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        let world = scene.animator.value.boneWorld
        var root = Self.animatedRoot
        root.columns.3 = SIMD4(30, 10, 0, 1)
        Self.assertEqual(Self.object * world[0], Self.object * root)
        // The tip's local keeps what the first write solved against the animated root.
        Self.assertEqual(world[1], root * (Self.animatedRoot.inverse * Self.object.inverse * target))
    }

    func testLocalAnglesReplaceTheRotationAndKeepTheOrigin() throws {
        let script = """
        export function init(value) {
          thisLayer.setLocalBoneAngles(0, new Vec3(0.25, -0.5, 1));
          console.log(JSON.stringify({ angles: thisLayer.getLocalBoneAngles(0), origin: thisLayer.getLocalBoneOrigin(0) }));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        let result = try scene.result()
        let angles = try XCTUnwrap(result["angles"] as? [String: Double])
        XCTAssertEqual(angles["x"] ?? .nan, 0.25, accuracy: 1e-5)
        XCTAssertEqual(angles["y"] ?? .nan, -0.5, accuracy: 1e-5)
        XCTAssertEqual(angles["z"] ?? .nan, 1, accuracy: 1e-5)
        XCTAssertEqual(result["origin"] as? [String: Double], ["x": 10, "y": 0, "z": 0])
        let rotation = simd_quatf(angle: 1, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: -0.5, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: 0.25, axis: SIMD3(1, 0, 0))
        Self.assertEqual(scene.animator.value.boneWorld[0], Self.translation(10, 0, 0) * simd_float4x4(rotation))
    }

    /// 1402105c0.c:17-58: the weight lands by name or index; a weight below FLT_EPSILON clears the target's bit.
    func testBlendShapeWritesReachTheMorphUniforms() throws {
        let script = """
        export function init(value) {
          thisLayer.setBlendShapeWeight('smile', 0.75);
          thisLayer.setBlendShapeWeight(1, 0);
          thisLayer.setBlendShapeWeight(2, 1);
          console.log(JSON.stringify({ smile: thisLayer.getBlendShapeWeight(0) }));
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        XCTAssertEqual(Self.morphWeights(scene.animator.value), [1, 0.25, 0, 0])
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try scene.result()["smile"] as? Double, 0.75)
        XCTAssertEqual(Self.morphWeights(scene.animator.value), [1, 0.75, 0, 0])
    }

    func testPhysicsCallsAreAcceptedAndLeaveThePoseAlone() throws {
        let script = """
        export function init(value) {
          thisLayer.applyBonePhysicsImpulse(0, new Vec3(5, 0, 0));
          thisLayer.applyBonePhysicsImpulse('tip', new Vec3(0, 1, 0), new Vec3(0, 0, 90));
          thisLayer.resetBonePhysicsSimulation();
          thisLayer.resetBonePhysicsSimulation(1);
          return value;
        }
        """
        var scene = try Self.scene(puppetScript: script)
        let before = scene.animator.value.bones
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(scene.animator.value.bones, before)
    }

    /// The methods are registered on every image layer; without a puppet getters answer undefined and setters do nothing.
    func testImageWithoutAPuppetAnswersUndefinedWithoutThrowing() throws {
        let script = """
        export function init(value) {
          const l = thisLayer;
          l.setBoneTransform(0, new Mat4());
          l.setLocalBoneTransform(0, new Mat4());
          l.setLocalBoneAngles(0, new Vec3(1, 2, 3));
          l.setLocalBoneOrigin(0, new Vec3(1, 2, 3));
          l.setBlendShapeWeight(0, 1);
          l.applyBonePhysicsImpulse(0, new Vec3(1, 0, 0), new Vec3(0, 0, 1));
          l.resetBonePhysicsSimulation();
          console.log(JSON.stringify([l.getBoneCount(), l.getBoneIndex('root'), l.getBoneParentIndex(0),
            l.getBoneTransform(0), l.getLocalBoneTransform(0), l.getLocalBoneAngles(0), l.getLocalBoneOrigin(0),
            l.getBlendShapeIndex('smile'), l.getBlendShapeWeight(0)].map(v => v === undefined)));
          return value;
        }
        """
        var scene = try Self.scene(plainScript: script)
        try scene.start()
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        let flags = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(scene.logs().first { $0.hasPrefix("[") }).utf8))
        XCTAssertEqual(flags as? [Bool], [Bool](repeating: true, count: 9))
    }

    // MARK: - Fixture

    final class Animator {
        var value: WPEParityPuppetAnimator

        init(_ value: WPEParityPuppetAnimator) {
            self.value = value
        }
    }

    struct Scene {
        let engine: WPEParityScriptEngine
        let animator: Animator
        let logs: () -> [String]
        var state: WPEParitySceneState

        mutating func start() throws {
            try engine.start(state: &state)
        }

        func result() throws -> [String: Any] {
            let line = try XCTUnwrap(logs().first { $0.hasPrefix("{") }, "\(logs())")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(x, y, z, 1)
        return matrix
    }

    private static func assertMatrix(_ value: Any?, _ expected: simd_float4x4, line: UInt = #line) throws {
        let numbers = try XCTUnwrap(value as? [Double], line: line)
        XCTAssertEqual(numbers.count, 16, line: line)
        let columns = (0 ..< 4).map { SIMD4(numbers[$0 * 4 ..< $0 * 4 + 4].map { Float($0) }) }
        assertEqual(simd_float4x4(columns), expected, line: line)
    }

    private static func assertEqual(_ actual: simd_float4x4, _ expected: simd_float4x4, line: UInt = #line) {
        for column in 0 ..< 4 {
            for row in 0 ..< 4 {
                XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 1e-3, "[\(column)][\(row)]", line: line)
            }
        }
    }

    /// g_MorphWeights[0]: the scale, then the set targets' weights in index order.
    private static func morphWeights(_ animator: WPEParityPuppetAnimator) -> [Float] {
        guard case let .array(groups)? = animator.values["g_MorphWeights"], case let .vector(lanes)? = groups.first else {
            return []
        }
        return lanes
    }

    /// Bone 0 "root" rests at (10, 0, 0) and bone 1 "tip" at (0, 5, 0) under it. Clip 7 holds bone 0 at 0.5 rad
    /// about Z and blend shape 1 "blink" at 0.25; blend shape 0 is "smile".
    private static func scene(puppetScript: String? = nil, plainScript: String? = nil) throws -> Scene {
        var first: [String: Any] = ["id": 1, "image": "models/a.json", "size": "64 64", "alpha": 1,
                                    "animationlayers": [["id": 10, "animation": 7, "visible": true]]]
        if let puppetScript {
            first["visible"] = ["value": true, "script": puppetScript]
        }
        var second: [String: Any] = ["id": 2, "image": "models/b.json", "size": "64 64", "alpha": 1]
        if let plainScript {
            second["visible"] = ["value": true, "script": plainScript]
        }
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [first, second],
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
        let animator = Animator(WPEParityPuppetAnimator(model: model(), layers: document.imageObjects[0].animationLayers))
        engine.puppetHandler = { id, body in
            guard id == "1" else { return false }
            body(&animator.value)
            return true
        }
        engine.transformMatrixHandler = { id, _, _ in id == "1" ? object : nil }
        return Scene(engine: engine, animator: animator, logs: { log.messages }, state: state)
    }

    private static func model() -> WPEPuppetModel {
        func floats(_ matrix: simd_float4x4) -> [Float] {
            [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: floats(translation(10, 0, 0)), name: "root"),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: floats(translation(0, 5, 0)), name: "tip"),
        ]
        let keys = (0 ... 1).map {
            WPEPuppetAnimKey(frame: $0, translation: SIMD3(10, 0, 0), euler: SIMD3(0, 0, 0.5), scale: SIMD3(1, 1, 1))
        }
        let tail = WPEPuppetAnimationTail(mdlaVersion: 6, sourceRange: 0 ..< 0, blendCurves: nil, scalarCurves: nil,
                                          unknownSegments: [],
                                          morphTracks: [[WPEPuppetMorphTrack(targetIndex: 1, values: [0.25, 0.25])]])
        let clip = WPEPuppetAnimation(id: 7, name: "a7", mode: "loop", fps: 30, frameCount: 1,
                                      channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys)], tail: tail)
        let targets = ["smile", "blink"].map {
            WPEPuppetMorph.Target(name: $0, positions: [1, 2, 3], normals: nil, alpha: nil)
        }
        let mesh = WPEPuppetMesh(materialPath: "", vertices: [], indices: [], parts: [],
                                 morph: WPEPuppetMorph(scale: 1, vertexCount: 1, targets: targets))
        return WPEPuppetModel(version: 23, meshes: [mesh], bones: bones, animations: [clip])
    }
}
