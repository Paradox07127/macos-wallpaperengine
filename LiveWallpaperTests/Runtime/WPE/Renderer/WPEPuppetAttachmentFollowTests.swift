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

    @Test("Zero bone motion under a mirrored parent leaves the child at its bind-pose origin")
    func zeroDeltaUnderMirroredParentIsNoOp() throws {
        let origin = try followedOrigin(parentScale: SIMD3<Double>(-1, -1, 1), angleZ: 0.7, boneTranslation: .zero)
        #expect(origin == childOrigin)
    }

    @Test("Zero parent scale keeps the GPU's positive sign (uvSignAndPadding: scale < 0 ? -1 : 1)")
    func zeroScaleKeepsPositiveSign() throws {
        let origin = try followedOrigin(parentScale: SIMD3<Double>(0, 1, 1), angleZ: 0, boneTranslation: boneDelta)
        #expect(origin.x > childOrigin.x)
        #expect(origin.x - childOrigin.x < 0.01)
        #expect(abs(origin.y - (childOrigin.y + Double(boneDelta.y))) < 0.01)
    }
}
