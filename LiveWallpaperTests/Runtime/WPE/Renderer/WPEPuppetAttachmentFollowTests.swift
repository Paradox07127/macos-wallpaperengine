import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("WPE puppet attachment follow")
struct WPEPuppetAttachmentFollowTests {
    private let sceneSize = CGSize(width: 3840, height: 2160)
    private let childOrigin = SIMD3<Double>(1200, 900, 0)
    /// Bone motion in the parent's model space (current − bind).
    private let boneDelta = SIMD2<Float>(40, -24)
    private let identityFloats: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    private func layer(
        id: String, origin: SIMD3<Double>, scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1), angleZ: Double = 0,
        puppetPath: String? = nil, parentObjectID: String? = nil, attachment: String? = nil
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: id, objectName: id, imagePath: "models/\(id).json", materialPath: nil, puppetPath: puppetPath,
            parentObjectID: parentObjectID, attachment: attachment,
            geometry: WPERenderLayerGeometry(
                origin: origin, scale: scale, angles: SIMD3<Double>(0, 0, angleZ), alignment: .center,
                size: CGSize(width: 400, height: 300), puppetMeshCenter: SIMD2<Double>(50, -30),
                alpha: 1, color: SIMD3<Double>(1, 1, 1), brightness: 1
            ),
            compositeA: "_rt_imageLayerComposite_\(id)_a", compositeB: "_rt_imageLayerComposite_\(id)_b",
            localFBOs: [], passes: []
        )
    }

    private func context(parent: WPERenderLayer, boneTranslation: SIMD2<Float>) -> WPEMetalRenderExecutor.PuppetAttachmentFrameContext {
        var palette = matrix_identity_float4x4
        palette.columns.3 = SIMD4<Float>(boneTranslation.x, boneTranslation.y, 0, 1)
        let state = WPEMetalRenderExecutor.PuppetSkinningState(
            enabled: true,
            palette: [palette],
            attachmentsByName: ["head": WPEPuppetAttachment(name: "head", boneIndex: 0, bindMatrix: identityFloats)],
            boneBindByIndex: [0: matrix_identity_float4x4],
            assembledBoneBindByIndex: [0: matrix_identity_float4x4],
            reason: "test"
        )
        return WPEMetalRenderExecutor.PuppetAttachmentFrameContext(
            objectParentByID: [:],
            layersByObjectID: [parent.objectID: WPEPreparedRenderLayer(graphLayer: parent, passes: [])],
            skinningByObjectID: [parent.objectID: state],
            sceneSize: sceneSize
        )
    }

    private func followedOrigin(parentScale: SIMD3<Double>, angleZ: Double, boneTranslation: SIMD2<Float>) throws -> SIMD3<Double> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let parent = layer(id: "rig", origin: SIMD3<Double>(1000, 800, 0), scale: parentScale, angleZ: angleZ, puppetPath: "models/rig.mdl")
        let child = layer(id: "face", origin: childOrigin, parentObjectID: "rig", attachment: "head")
        return executor.layerApplyingAttachmentFollow(child, context: context(parent: parent, boneTranslation: boneTranslation)).geometry.origin
    }

    @Test("Follow delta is the bone motion through the parent's signed scale and rotation, like the mirrored mesh", arguments: [
        (SIMD3<Double>(-1, 1, 1), 0.0),
        (SIMD3<Double>(1, -1, 1), 0.0),
        (SIMD3<Double>(-1, -1, 1), 0.0),
        (SIMD3<Double>(-2, 1.5, 1), 0.7),
        (SIMD3<Double>(1, -0.5, 1), -1.1),
        (SIMD3<Double>(1, 1, 1), 0.3),
    ])
    func followDeltaMatchesMirroredMesh(parentScale: SIMD3<Double>, angleZ: Double) throws {
        let origin = try followedOrigin(parentScale: parentScale, angleZ: angleZ, boneTranslation: boneDelta)
        // wpe_puppet_scene_composite_vertex: localPixels = Δ · |scale| · sign(scale), then rotate by angles.z.
        let local = SIMD2<Double>(parentScale.x * Double(boneDelta.x), parentScale.y * Double(boneDelta.y))
        let expected = SIMD2<Double>(
            childOrigin.x + cos(angleZ) * local.x - sin(angleZ) * local.y,
            childOrigin.y + sin(angleZ) * local.x + cos(angleZ) * local.y
        )
        #expect(abs(origin.x - expected.x) < 0.01, "x: \(origin.x) vs \(expected.x)")
        #expect(abs(origin.y - expected.y) < 0.01, "y: \(origin.y) vs \(expected.y)")
        #expect(origin.z == childOrigin.z)
    }

    @Test("An unattached grandchild inherits the attached parent's bone motion exactly once")
    func grandchildFollowsAttachment() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let parent = layer(id: "rig", origin: SIMD3(1000, 800, 0), puppetPath: "models/rig.mdl")
        let child = layer(id: "face", origin: childOrigin, parentObjectID: "rig", attachment: "head")
        let grandchild = layer(id: "jewel", origin: childOrigin + SIMD3(10, 20, 0), parentObjectID: "face")
        let initial = context(parent: parent, boneTranslation: boneDelta)
        let chain = WPEMetalRenderExecutor.PuppetAttachmentFrameContext(
            objectParentByID: [:],
            layersByObjectID: initial.layersByObjectID.merging([
                "face": WPEPreparedRenderLayer(graphLayer: child, passes: []),
            ]) { first, _ in first }, skinningByObjectID: initial.skinningByObjectID, sceneSize: sceneSize
        )
        let moved = executor.layerApplyingAttachmentFollow(grandchild, context: chain)
        #expect(abs(moved.geometry.origin.x - grandchild.geometry.origin.x - Double(boneDelta.x)) < 0.01)
        #expect(abs(moved.geometry.origin.y - grandchild.geometry.origin.y - Double(boneDelta.y)) < 0.01)
    }

    @Test("Bone motion crosses a non-rendered transform host without following cycles")
    func grandchildAcrossTransformHost() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let rig = layer(id: "rig", origin: SIMD3(1000, 800, 0), puppetPath: "models/rig.mdl")
        let face = layer(id: "face", origin: childOrigin, parentObjectID: "rig", attachment: "head")
        let jewel = layer(id: "jewel", origin: childOrigin + SIMD3(10, 20, 0), parentObjectID: "host")
        let initial = context(parent: rig, boneTranslation: boneDelta)
        let chain = WPEMetalRenderExecutor.PuppetAttachmentFrameContext(
            objectParentByID: ["host": "face", "rig": "host"],
            layersByObjectID: initial.layersByObjectID.merging([
                "face": WPEPreparedRenderLayer(graphLayer: face, passes: []),
            ]) { first, _ in first }, skinningByObjectID: initial.skinningByObjectID, sceneSize: sceneSize
        )
        let moved = executor.layerApplyingAttachmentFollow(jewel, context: chain)
        #expect(abs(moved.geometry.origin.x - jewel.geometry.origin.x - Double(boneDelta.x)) < 0.01)
        #expect(abs(moved.geometry.origin.y - jewel.geometry.origin.y - Double(boneDelta.y)) < 0.01)
    }

    private func groupChain(
        child: WPERenderLayer, groupAngleZ: Double, groupScale: SIMD3<Double>
    ) -> WPEMetalRenderExecutor.PuppetAttachmentFrameContext {
        let rig = layer(id: "rig", origin: SIMD3(1000, 800, 0), puppetPath: "models/rig.mdl")
        let group = layer(id: "grp", origin: SIMD3(1600, 1000, 0), scale: groupScale, angleZ: groupAngleZ)
        let initial = context(parent: rig, boneTranslation: boneDelta)
        return WPEMetalRenderExecutor.PuppetAttachmentFrameContext(
            objectParentByID: ["face": "rig", "rig": "grp"],
            layersByObjectID: initial.layersByObjectID.merging([
                "grp": WPEPreparedRenderLayer(graphLayer: group, passes: []),
                "face": WPEPreparedRenderLayer(graphLayer: child, passes: []),
            ]) { first, _ in first }, skinningByObjectID: initial.skinningByObjectID, sceneSize: sceneSize
        )
    }

    private func pass(target: WPERenderTarget) -> WPERenderPass {
        WPERenderPass(
            id: "face.final", phase: .material, shader: "genericimage2", source: .image("materials/face.png"),
            target: target, textures: [:], binds: [:], constants: [:], combos: [:], blending: "normal",
            cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
    }

    @Test("An attached layer drawn into its composelayer target follows the bone through the group's inverse rotation and scale")
    func groupedAttachmentFollowsInGroupLocalSpace() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let base = layer(id: "face", origin: childOrigin, parentObjectID: "rig", attachment: "head")
        let groupTarget = WPERenderTargetNames.LayerGroup.make(objectID: "grp")
        let groupLocal = WPERenderLayerGeometry(
            origin: SIMD3(300, 200, 4), scale: SIMD3(0.5, 0.5, 1), angles: SIMD3(0, 0, -0.5), alignment: .topLeft,
            size: CGSize(width: 400, height: 300), puppetMeshCenter: SIMD2(7, 9), alpha: 0.8,
            color: SIMD3(0.2, 0.4, 0.6), brightness: 1.5, shapePoints: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        )
        let child = WPERenderLayer(
            objectID: base.objectID, objectName: base.objectName, imagePath: base.imagePath, materialPath: nil,
            parentObjectID: "rig", attachment: "head", geometry: base.geometry,
            compositeA: base.compositeA, compositeB: base.compositeB, localFBOs: [], passes: [],
            groupRenderTarget: groupTarget, groupLocalGeometry: groupLocal
        )
        let angle = 0.5
        let moved = executor.layerApplyingAttachmentFollow(
            child, context: groupChain(child: child, groupAngleZ: angle, groupScale: SIMD3(2, 2, 1))
        )
        let drawn = executor.layerForDrawing(pass: pass(target: .fbo(name: groupTarget)), layer: moved).geometry
        let delta = SIMD2<Double>(Double(boneDelta.x), Double(boneDelta.y))
        let expected = SIMD2<Double>(
            (delta.x * cos(-angle) - delta.y * sin(-angle)) / 2,
            (delta.x * sin(-angle) + delta.y * cos(-angle)) / 2
        )
        #expect(abs(drawn.origin.x - groupLocal.origin.x - expected.x) < 0.01, "x: \(drawn.origin.x - groupLocal.origin.x) vs \(expected.x)")
        #expect(abs(drawn.origin.y - groupLocal.origin.y - expected.y) < 0.01, "y: \(drawn.origin.y - groupLocal.origin.y) vs \(expected.y)")
        let movedLocal = try #require(moved.groupLocalGeometry)
        #expect(movedLocal.origin.z == groupLocal.origin.z)
        #expect(movedLocal.scale == groupLocal.scale)
        #expect(movedLocal.angles == groupLocal.angles)
        #expect(movedLocal.alignment == groupLocal.alignment)
        #expect(movedLocal.size == groupLocal.size)
        #expect(movedLocal.puppetMeshCenter == groupLocal.puppetMeshCenter)
        #expect(movedLocal.alpha == groupLocal.alpha)
        #expect(movedLocal.color == groupLocal.color)
        #expect(movedLocal.brightness == groupLocal.brightness)
        #expect(movedLocal.shapePoints == groupLocal.shapePoints)
        #expect(moved.groupRenderTarget == groupTarget)
        #expect(abs(moved.geometry.origin.x - childOrigin.x - delta.x) < 0.01)
        #expect(abs(moved.geometry.origin.y - childOrigin.y - delta.y) < 0.01)
    }

    @Test("An attached layer outside any composelayer still moves only its scene geometry")
    func ungroupedAttachmentUnchangedByGroupAncestor() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let child = layer(id: "face", origin: childOrigin, parentObjectID: "rig", attachment: "head")
        let moved = executor.layerApplyingAttachmentFollow(
            child, context: groupChain(child: child, groupAngleZ: 0.5, groupScale: SIMD3(2, 2, 1))
        )
        #expect(moved.groupLocalGeometry == nil)
        #expect(abs(moved.geometry.origin.x - childOrigin.x - Double(boneDelta.x)) < 0.01)
        #expect(abs(moved.geometry.origin.y - childOrigin.y - Double(boneDelta.y)) < 0.01)
        let drawn = executor.layerForDrawing(pass: pass(target: .fbo(name: WPERenderTargetNames.LayerGroup.make(objectID: "grp"))), layer: moved)
        #expect(drawn.geometry == moved.geometry)
    }

    @Test("Zero bone motion under a mirrored parent leaves the child at its bind-pose origin")
    func zeroDeltaUnderMirroredParentIsNoOp() throws {
        let origin = try followedOrigin(parentScale: SIMD3<Double>(-1, -1, 1), angleZ: 0.7, boneTranslation: .zero)
        #expect(origin == childOrigin)
    }

    @Test("Attachment motion adds pixels without rescaling fractional authored origins",
          arguments: [-0.5, 0, 0.5, 1, 1.01, 12.375])
    func attachmentPreservesPixelOrigins(value: Double) throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let parent = layer(id: "rig", origin: SIMD3(value, value, 0), puppetPath: "models/rig.mdl")
        let child = layer(id: "face", origin: SIMD3(value, value, 3), parentObjectID: "rig", attachment: "head")
        let moved = executor.layerApplyingAttachmentFollow(child, context: context(parent: parent, boneTranslation: boneDelta))
        #expect(abs(moved.geometry.origin.x - (value + Double(boneDelta.x))) < 0.001)
        #expect(abs(moved.geometry.origin.y - (value + Double(boneDelta.y))) < 0.001)
        #expect(moved.geometry.origin.z == 3)
    }

    @Test("Zero parent scale keeps the GPU's positive sign (uvSignAndPadding: scale < 0 ? -1 : 1)")
    func zeroScaleKeepsPositiveSign() throws {
        let origin = try followedOrigin(parentScale: SIMD3<Double>(0, 1, 1), angleZ: 0, boneTranslation: boneDelta)
        #expect(origin.x > childOrigin.x)
        #expect(origin.x - childOrigin.x < 0.01)
        #expect(abs(origin.y - (childOrigin.y + Double(boneDelta.y))) < 0.01)
    }
}
