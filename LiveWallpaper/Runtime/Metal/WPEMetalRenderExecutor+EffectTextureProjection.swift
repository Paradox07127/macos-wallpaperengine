#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

extension WPEMetalRenderExecutor {
    /// `nil` = the layer has no pass compositing into the scene or its group target.
    func effectTextureProjectionMatrix(
        for layer: WPERenderLayer,
        frameState: WPEMetalFrameState,
        sourceTexture: MTLTexture
    ) -> simd_double4x4? {
        guard let composite = layer.passes.last(where: { pass in
            if case .scene = pass.target {
                return true
            }
            return isGroupRenderTarget(pass.target, layer: layer)
        }) else {
            return nil
        }
        let drawLayer = layerForDrawing(pass: composite, layer: layer)
        // Branch before building the quad: a parented identity layer still gets a static parallax
        // offset from `objectQuadUniforms`, yet it is drawn fullscreen while parallax is idle.
        guard usesObjectQuadGeometry(for: composite, layer: drawLayer, cameraParallax: frameState.cameraParallax) else {
            return matrix_identity_double4x4
        }
        let quad = objectQuadUniforms(
            for: drawLayer,
            sceneSize: objectQuadSceneSize(
                for: composite,
                layer: drawLayer,
                destination: (id: .scene, texture: sourceTexture),
                frameState: frameState
            ),
            cameraParallax: frameState.cameraParallax,
            sourceTexture: sourceTexture,
            cameraUniforms: objectQuadCameraUniforms(for: composite, layer: drawLayer, frameState: frameState)
        )
        return WPEMetalObjectUniforms.effectTextureProjectionMatrix(quad: quad)
    }
}
#endif
