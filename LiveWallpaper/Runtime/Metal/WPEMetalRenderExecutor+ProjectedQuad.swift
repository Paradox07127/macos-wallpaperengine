#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import simd

extension WPEMetalRenderExecutor {
    /// Composelayers this frame captures and draws back through `WPEProjectedComposeQuad`; every other layer keeps today's route.
    func projectedComposeObjectIDs(
        for pipeline: WPEPreparedRenderPipeline,
        cameraUniforms: WPEMetalCameraUniforms,
        sceneSize: CGSize,
        groupingContainerObjectIDs: Set<String>
    ) -> Set<String> {
        // The quad's VP carries no camera motion, so any animated camera falls back.
        guard cameraUniforms.perspectiveOverrideFOVDegrees > 0, !cameraUniforms.usesPerspectiveProjection,
              cameraUniforms.sceneMotion == .identity else { return [] }
        var ids: Set<String> = []
        // Parallax only translates in x/y, which never moves clip w, so the zero-parallax quad decides admission.
        for layer in pipeline.layers {
            let graph = layer.graphLayer
            // The quad has no alignment offset, unlike `objectQuadUniforms`.
            guard graph.utilityModelKind == .composeLayer, graph.geometry.alignment == .center,
                  !groupingContainerObjectIDs.contains(graph.objectID),
                  cameraUniforms.usesProjectedCompose(objectID: graph.objectID),
                  Self.capturesSceneAndCopiesBack(layer),
                  projectedComposeQuad(
                      for: graph, sceneSize: sceneSize, cameraUniforms: cameraUniforms, parallaxOffset: .zero
                  ) != nil else { continue }
            ids.insert(graph.objectID)
        }
        return ids
    }

    /// First pass is the single-texture scene capture into the layer's own RT; last pass is the synthesized scene copy / blendComposite.
    /// Without both, a projected draw-back of an un-captured RT would paint a picture-in-picture.
    static func capturesSceneAndCopiesBack(_ layer: WPEPreparedRenderLayer) -> Bool {
        guard layer.graphLayer.groupCompositeSource == nil,
              let first = layer.passes.first, let last = layer.passes.last, layer.passes.count > 1,
              case .layerComposite = first.pass.target,
              first.shader?.isBuiltin != false,
              WPEBuiltinShaderKind(normalizing: first.pass.shader) == .compose,
              case let .fbo(captured) = first.textureBindings[0] ?? first.pass.textures[0] ?? first.pass.source,
              WPETextureReference.isSceneAliasName(captured),
              last.pass.target == .scene,
              last.pass.phase == .command(file: WPERenderPassPhase.sceneCopyCommandFile) else { return false }
        return last.pass.shader == WPERenderPassPhase.sceneCopyCommandFile
            || WPEBuiltinShaderKind(normalizing: last.pass.shader) == .blendComposite
    }

    /// Scene draw-back of a `.projected` layer; capture and effect passes target the layer RT and are excluded.
    func usesProjectedComposeDrawBack(for pass: WPERenderPass, layer: WPERenderLayer) -> Bool {
        guard case .scene = pass.target else { return false }
        return sceneCaptureUtilityOutputGeometry(for: layer) == .projected
    }

    /// nil when the quad cannot be built (no authored size, corner at/behind the eye); callers then take today's path.
    func projectedQuadUniforms(
        for layer: WPERenderLayer,
        frameState: WPEMetalFrameState,
        clearAlpha: Bool
    ) -> WPEProjectedQuadUniforms? {
        let anchor = Self.centeredOrigin(of: layer.geometry, sceneSize: frameState.sceneSize)
        let parallax = frameState.cameraParallax.pixelOffset(
            objectCenter: parallaxObjectCenter(for: layer, fallback: anchor),
            depth: layer.parallaxDepth,
            sceneSize: frameState.sceneSize
        )
        // The capture targets the layer RT, where `objectQuadCameraUniforms` would return `.identity`.
        guard let quad = projectedComposeQuad(
            for: layer,
            sceneSize: frameState.sceneSize,
            cameraUniforms: frameState.cameraUniforms,
            parallaxOffset: SIMD2(Double(parallax.x), Double(parallax.y))
        ) else { return nil }
        return WPEProjectedQuadUniforms(quad: quad, clearAlpha: clearAlpha)
    }

    private func projectedComposeQuad(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        cameraUniforms: WPEMetalCameraUniforms,
        parallaxOffset: SIMD2<Double>
    ) -> WPEProjectedComposeQuad? {
        let geometry = layer.geometry
        guard let size = geometry.size else { return nil }
        return WPEProjectedComposeQuad(
            origin: geometry.origin,
            scale: geometry.scale,
            angles: geometry.angles,
            size: size,
            sceneSize: sceneSize,
            fovDegrees: cameraUniforms.perspectiveOverrideFOVDegrees,
            parallaxOffset: parallaxOffset
        )
    }
}
#endif
