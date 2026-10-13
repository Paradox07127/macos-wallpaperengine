@testable import LiveWallpaperProWPE
import simd
import XCTest

final class WPEParityAttachmentTests: XCTestCase {
    private func floats(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(value, 1)
        return matrix
    }

    private func key(_ frame: Int, _ x: Float) -> WPEPuppetAnimKey {
        WPEPuppetAnimKey(frame: frame, translation: SIMD3(x, 0, 0), euler: .zero, scale: .one)
    }

    /// One bone at (1, 0, 0) sliding to (5, 0, 0) over 0.25 s; attachment "hand" on it, rotated a quarter turn.
    private func puppet() -> WPEPuppetModel {
        let slide = WPEPuppetAnimation(id: 3, name: "slide", mode: "loop", fps: 4, frameCount: 1,
                                       channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: [key(0, 1), key(1, 5)])])
        let hand = translation(SIMD3(0, 3, 0)) * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        return WPEPuppetModel(version: 23, meshes: [],
                              bones: [WPEPuppetBone(index: 0, parentIndex: nil,
                                                    rawMatrix: floats(translation(SIMD3(1, 0, 0))))],
                              animations: [slide],
                              attachments: [WPEPuppetAttachment(name: "hand", boneIndex: 0, bindMatrix: floats(hand))])
    }

    private func camera() -> WPEParityCamera {
        WPEParityCamera(eye: SIMD3(0, 0, 1), center: .zero, up: SIMD3(0, 1, 0), size: SIMD2(1920, 1080),
                        renderTargetSize: SIMD2(1920, 1080))
    }

    private func layers(attachment: String?, models: [String: WPEPuppetModel]) -> WPEParityLayerTransformSet {
        WPEParityLayerTransformSet(camera: camera(), layers: [
            WPEParityLayerTransform(id: "p", origin: SIMD3(100, 200, 0)),
            WPEParityLayerTransform(id: "c", parentID: "p", origin: SIMD3(10, 0, 0), attachment: attachment),
        ], puppetModels: models)
    }

    private func position(_ layers: WPEParityLayerTransformSet, _ id: String) -> SIMD2<Float> {
        let origin = layers.world(id) * SIMD4<Float>(0, 0, 0, 1)
        return SIMD2(origin.x, origin.y)
    }

    private func assertNear(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertLessThan(simd_length(lhs - rhs), 1e-4, "\(lhs) != \(rhs)", file: file, line: line)
    }

    /// W_child = W_parent · BoneWorld · AttachM · local (1401850a0.c:49-67, 1401fd5c0.c:21-23).
    func testChildFollowsTheMovingBoneEveryFrame() {
        let model = puppet()
        var animator = WPEParityPuppetAnimator(model: model,
                                               layers: [WPESceneAnimationLayer(id: 1, rate: 1, visible: true,
                                                                               blend: 1, animation: 3,
                                                                               additive: false)])
        var layers = layers(attachment: "hand", models: ["p": model])
        XCTAssertTrue(layers.hasAttachments)
        // Rest pose: bone (1, 0), hand +3 up, the quarter turn takes the child's (10, 0) to (0, 10).
        assertNear(position(layers, "c"), SIMD2(101, 213))
        for (dt, x) in [(0.0, Float(1)), (0.125, 3), (0.0625, 4)] {
            animator.advance(dt: dt)
            layers.refreshWorlds { $0 == "p" ? animator.boneWorld : nil }
            assertNear(position(layers, "c"), SIMD2(100 + x, 213))
        }
        assertNear(position(layers, "p"), SIMD2(100, 200))
    }

    func testAttachmentNeedsAPuppetParentAndAKnownName() {
        let plain = SIMD2<Float>(110, 200)
        for (name, models) in [("hand", [String: WPEPuppetModel]()), ("foot", ["p": puppet()]),
                               (nil, ["p": puppet()])] as [(String?, [String: WPEPuppetModel])] {
            var layers = layers(attachment: name, models: models)
            XCTAssertFalse(layers.hasAttachments)
            assertNear(position(layers, "c"), plain)
            layers.refreshWorlds()
            assertNear(position(layers, "c"), plain)
        }
    }

    func testBoneOutOfRangeLeavesTheLocalAlone() {
        let model = puppet()
        let broken = WPEPuppetModel(version: 23, meshes: [], bones: model.bones, animations: model.animations,
                                    attachments: [WPEPuppetAttachment(name: "hand", boneIndex: 4,
                                                                      bindMatrix: model.attachments[0].bindMatrix)])
        var layers = layers(attachment: "hand", models: ["p": broken])
        layers.refreshWorlds()
        assertNear(position(layers, "c"), SIMD2(110, 200))
    }
}

final class WPEParityPerspectiveLayerTests: XCTestCase {
    /// 1920×1080 canvas on a square target, alignment position 25: crop 630 left, 210 right.
    private func camera(flip: Bool) -> WPEParityCamera {
        WPEParityCamera(eye: SIMD3(0, 0, 1), center: .zero, up: SIMD3(0, 1, 0), size: SIMD2(1920, 1080),
                        renderTargetSize: SIMD2(1000, 1000),
                        alignment: WPEParityCameraAlignment(mode: 0, position: 25, flipHorizontal: flip))
    }

    private func assertNear(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>, accuracy: Float = 1e-3,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(lhs - rhs), accuracy, "\(lhs) != \(rhs)", file: file, line: line)
    }

    /// FUN_1401e5b60: V.x −= W·cx with the unmirrored crop centre, V.z = −(1/P.m5)/tan(fov/2), P perspective with
    /// its first column negated under fliph.
    func testTopLevelPerspectiveUsesTheUnmirroredCropCentre() {
        let focal: Float = 2.1445069
        for flip in [false, true] {
            var flagged = WPEParityLayerTransform(id: "a", origin: SIMD3(960, 540, 0))
            flagged.perspective = true
            let layers = WPEParityLayerTransformSet(camera: camera(flip: flip), layers: [flagged])
            let draw = layers.draw("a", kind: .layer, parallax: .zero).matrices
            assertNear(draw.view.columns.3, SIMD4(-1170, -540, -1158.0337, 1))
            assertNear(draw.projection.columns.0, SIMD4(flip ? -focal : focal, 0, 0, 0))
            assertNear(draw.projection.columns.1, SIMD4(0, focal, 0, 0))
            XCTAssertEqual(draw.projection.columns.2.w, -1)
            assertNear(layers.view("a", parallax: .zero).columns.3, draw.view.columns.3)
        }
    }

    /// A perspective child in its parent's composite pushes onto V = I and the composite ortho (1401e8aa0.c:998-1001).
    func testPerspectiveChildInACompositeReplacesTheCompositeCamera() {
        let parent = WPEParityLayerTransform(id: "p", origin: SIMD3(960, 540, 0), size: SIMD2(400, 200))
        var child = WPEParityLayerTransform(id: "c", parentID: "p", origin: SIMD3(10, 0, 0))
        child.perspective = true
        let layers = WPEParityLayerTransformSet(camera: camera(flip: false), layers: [parent, child])
        let draw = layers.draw("c", kind: .layer, compositeOwnerID: "p", parallax: .zero).matrices
        assertNear(draw.view.columns.3, SIMD4(-1170, -540, -214.4507, 1))
        assertNear(draw.model.columns.3, SIMD4(10, 0, 0, 1))
        assertNear(draw.projection.columns.1, SIMD4(0, 2.1445069, 0, 0))
    }
}
