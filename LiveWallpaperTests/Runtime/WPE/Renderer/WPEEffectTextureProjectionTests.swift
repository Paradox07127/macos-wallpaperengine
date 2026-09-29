#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Effect texture projection matrix")
struct WPEEffectTextureProjectionTests {
    private static let scene = SIMD2<Float>(3840, 2160)

    @Test
    func rotatedLayerMatchesWindowsCapture() {
        let m = WPEMetalObjectUniforms.effectTextureProjectionMatrix(
            quad: quad(center: .zero, size: SIMD2(1920, 1080), rotation: 0.5235988)
        )
        expect(m.columns.0, SIMD4(0.4330125, 0.4444454, 0, 0))
        expect(m.columns.1, SIMD4(-0.1406253, 0.4330124, 0, 0))
        expect(m.columns.2, SIMD4(0, 0, 1, 0))
        expect(m.columns.3, SIMD4(0, 0, 0, 1))
    }

    @Test
    func mirroredLayerFlipsTheLocalAxis() {
        let m = WPEMetalObjectUniforms.effectTextureProjectionMatrix(
            quad: quad(center: .zero, size: SIMD2(1920, 1080), rotation: 0, uvSign: SIMD2(-1, 1))
        )
        expect(m.columns.0, SIMD4(-0.5, 0, 0, 0))
        expect(m.columns.1, SIMD4(0, 0.5, 0, 0))
    }

    @Test
    func scaledOffsetLayerMatchesWindowsCaptureAndInverse() {
        let scale: Float = 1.05903
        let m = WPEMetalObjectUniforms.effectTextureProjectionMatrix(
            quad: quad(
                center: SIMD2(-0.0394595 * 1920, 0.0405955 * 1080),
                size: SIMD2(3840 * scale, 2160 * scale),
                rotation: 0
            )
        )
        expect(m.columns.0, SIMD4(1.05903, 0, 0, 0))
        expect(m.columns.1, SIMD4(0, 1.05903, 0, 0))
        expect(m.columns.3, SIMD4(-0.0394595, 0.0405955, 0, 1))
        let inverse = WPEMetalObjectUniforms.safeInverse(m)
        expect(inverse.columns.0, SIMD4(0.94426, 0, 0, 0), tolerance: 1e-4)
        expect(inverse.columns.1, SIMD4(0, 0.94426, 0, 0), tolerance: 1e-4)
        expect(inverse.columns.3, SIMD4(0.03726, -0.03833, 0, 1), tolerance: 1e-4)
    }

    @Test
    func packingTakesTheMatrixFromTheDrawContext() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let matrix = WPEMetalObjectUniforms.effectTextureProjectionMatrix(
            quad: quad(center: SIMD2(120, -40), size: SIMD2(1920, 1080), rotation: 0.5235988)
        )
        let layout = [
            WPEUniformSlot(name: WPEMetalObjectUniforms.effectTextureProjectionMatrixUniformName,
                           glslType: "mat4", slot: 0, slotCount: 4),
            WPEUniformSlot(name: WPEMetalObjectUniforms.effectTextureProjectionMatrixInverseUniformName,
                           glslType: "mat4", slot: 4, slotCount: 4),
        ]
        let slots = try executor.packTranslatedUniforms(
            for: makePass(), layout: layout, effectTextureProjection: { matrix }
        )
        #expect(Array(slots[0 ..< 4]) == Self.floatColumns(matrix))
        #expect(Array(slots[4 ..< 8]) == Self.floatColumns(WPEMetalObjectUniforms.safeInverse(matrix)))

        #if DEBUG
        let (missing, sources) = try executor.withUniformSourceTracing {
            try executor.packTranslatedUniforms(for: makePass(), layout: [layout[1]], effectTextureProjection: { nil })
        }
        #expect(missing.allSatisfy { $0 == .zero })
        #expect(sources == [.missing])
        #endif
    }

    @Test
    func fullscreenLayerWithoutLiveParallaxIsIdentity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let texture = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 16, height: 9, mipmapped: false
        )))
        var frameState = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 3840, height: 2160))
        frameState.cameraParallax = WPECameraParallaxFrame(smoothed: SIMD2(0, 0), amount: 0.5, influence: 0.5)
        let layer = makeLayer(passes: [makePass().pass], parent: "root", parallaxDepth: SIMD2(1, 1))
        let m = try #require(executor.effectTextureProjectionMatrix(
            for: layer, frameState: frameState, sourceTexture: texture
        ))
        #expect(m == matrix_identity_double4x4)

        let noComposite = makeLayer(passes: [], parent: nil, parallaxDepth: .zero)
        #expect(executor.effectTextureProjectionMatrix(
            for: noComposite, frameState: frameState, sourceTexture: texture
        ) == nil)
    }

    // MARK: - Helpers

    private func quad(
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        rotation: Float,
        uvSign: SIMD2<Float> = SIMD2(1, 1)
    ) -> WPEObjectQuadUniforms {
        WPEObjectQuadUniforms(
            centerAndSize: SIMD4(center.x, center.y, size.x, size.y),
            sceneSizeAndRotation: SIMD4(Self.scene.x, Self.scene.y, rotation, 0),
            uvSignAndPadding: SIMD4(uvSign.x, uvSign.y, 0, 0)
        )
    }

    private func expect(
        _ actual: SIMD4<Double>,
        _ expected: SIMD4<Double>,
        tolerance: Double = 1e-5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let delta = simd_abs(actual - expected)
        #expect(delta.max() <= tolerance, "\(actual) vs \(expected)", sourceLocation: sourceLocation)
    }

    private static func floatColumns(_ m: simd_double4x4) -> [SIMD4<Float>] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].map { SIMD4<Float>($0) }
    }

    private func makePass() -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(id: "etpm.probe", phase: .effect(file: "probe"), shader: "etpm_probe",
                                source: .image("unused"), target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                                blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]
        )
    }

    private func makeLayer(passes: [WPERenderPass], parent: String?, parallaxDepth: SIMD2<Double>) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "etpm.layer",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: "materials/layer.json",
            parentObjectID: parent,
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_etpm_a",
            compositeB: "_rt_imageLayerComposite_etpm_b",
            localFBOs: [],
            passes: passes,
            parallaxDepth: parallaxDepth
        )
    }
}
#endif
