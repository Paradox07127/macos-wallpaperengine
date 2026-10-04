#if !LITE_BUILD
import CoreGraphics
import Metal
import simd

struct WPEParticleDrawUniforms {
    let projection: WPEParticleProjection
    let sprite: WPEMetalRenderExecutor.WPEParticleSpriteParams

    func matches(_ other: Self) -> Bool {
        let a = projection
        let b = other.projection
        return sprite.grid == other.sprite.grid
            && sprite.frameRectMode == other.sprite.frameRectMode
            && sprite.tintAndMask == other.sprite.tintAndMask
            && a.sceneSize == b.sceneSize && a.padding == b.padding
            && a.trail == b.trail && a.modelShape == b.modelShape
            && a.eyeAndSizeScale == b.eyeAndSizeScale
            && a.cameraClipTransform == b.cameraClipTransform
            && Self.matches(a.viewProjection, b.viewProjection)
            && Self.matches(a.modelToWorld, b.modelToWorld)
            && Self.matches(a.worldToModel, b.worldToModel)
            && Self.matches(a.cameraOrientation, b.cameraOrientation)
    }

    private static func matches(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1
            && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
}

struct WPEParticleSpriteBatch {
    var systemCount = 1
    var instanceCount: Int
    var uniforms: WPEParticleDrawUniforms?
}

extension WPEMetalRenderExecutor {
    func particleSpriteBatch(
        startingWith first: WPEParticleSystem, following systems: [WPEParticleSystem],
        cursor: inout Int, threshold: Int, enabled: Bool,
        textures: [ObjectIdentifier: MTLTexture], normals: [ObjectIdentifier: MTLTexture],
        sceneSize: CGSize, cameraParallax: WPECameraParallaxFrame, cameraUniforms: WPEMetalCameraUniforms
    ) -> WPEParticleSpriteBatch {
        var batch = WPEParticleSpriteBatch(instanceCount: first.liveInstanceCount)
        guard enabled, first.usesFrameArena, !first.usesRibbonGeometry,
              normals[ObjectIdentifier(first)] == nil,
              let texture = textures[ObjectIdentifier(first)] else { return batch }
        let uniforms = particleDrawUniforms(
            first, texture: texture, sceneSize: sceneSize, cameraParallax: cameraParallax,
            cameraUniforms: cameraUniforms, isRefract: false
        )
        batch.uniforms = uniforms
        let stride = MemoryLayout<WPEParticleInstance>.stride
        while cursor < systems.count {
            let next = systems[cursor]
            guard next.sortIndex < threshold, next.usesFrameArena, !next.usesRibbonGeometry,
                  normals[ObjectIdentifier(next)] == nil,
                  textures[ObjectIdentifier(next)] === texture,
                  next.blendMode == first.blendMode,
                  next.groupOpacityMask === first.groupOpacityMask,
                  next.frameRectsBuffer === first.frameRectsBuffer,
                  next.instanceBuffer === first.instanceBuffer,
                  next.renderBufferOffset == first.renderBufferOffset + batch.instanceCount * stride,
                  uniforms.matches(particleDrawUniforms(
                      next, texture: texture, sceneSize: sceneSize, cameraParallax: cameraParallax,
                      cameraUniforms: cameraUniforms, isRefract: false
                  )) else { break }
            batch.systemCount += 1
            batch.instanceCount += next.liveInstanceCount
            cursor += 1
        }
        return batch
    }
}
#endif
