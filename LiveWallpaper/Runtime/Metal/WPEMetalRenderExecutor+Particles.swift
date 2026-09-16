#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

/// Applies only an explicitly authored Sprite Trail minimum. An absent/null key leaves the existing projection value untouched because its WPE default still requires L1 evidence.
func wpeApplyingAuthoredSpriteTrailMinimum(
    from renderer: WPEParticleTrailRenderer,
    to projection: SIMD4<Float>
) -> SIMD4<Float> {
    guard renderer.kind == .sprite, let minLength = renderer.minLength else {
        return projection
    }
    var result = projection
    result.z = Float(minLength)
    return result
}

extension WPEMetalRenderExecutor {
    func makeParticleOutputEncoder(
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "particles")
        closeSharedSceneEncoderForHelperEncoder()
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("particles")
        WPEFrameOccupancyMeter.count(.particleEncoder)
        return encoder
    }

    @discardableResult
    func encodeParticleSystem(
        _ system: WPEParticleSystem,
        into commandBuffer: MTLCommandBuffer,
        output: MTLTexture,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame,
        texturesByMaterial: [ObjectIdentifier: MTLTexture],
        normalsByMaterial: [ObjectIdentifier: MTLTexture],
        frameState: inout WPEMetalFrameState,
        traceIndex: Int,
        sharedEncoder: MTLRenderCommandEncoder? = nil
    ) throws -> Bool {
        guard system.liveInstanceCount > 0 else { return false }
        // A rope needs ≥2 knots (4 verts) for a strip; a degenerate/empty ribbon
        // draws nothing, so skip the pass entirely rather than encode an empty one.
        if system.usesRibbonGeometry, system.ropeVertexCount < 4 { return false }
        // Systems whose texture failed to load were filtered at scene-load; skip
        // defensively so a stale texture-slot binding can't leak in.
        guard let texture = texturesByMaterial[ObjectIdentifier(system)] else { return false }
        // REFRACT needs the normal map AND a scene-so-far snapshot (a blit encoder that cannot coexist with a shared open render encoder), so refraction is only available on this system's OWN pass (`sharedEncoder == nil`).
        let refractNormal = (sharedEncoder == nil && !system.usesRibbonGeometry)
            ? normalsByMaterial[ObjectIdentifier(system)] : nil
        let refractBackground: MTLTexture? = refractNormal == nil ? nil
            : snapshotForRefraction(of: output, into: commandBuffer, frameState: &frameState)
        let isRefract = refractNormal != nil && refractBackground != nil
        let state = try particlePipelineState(
            colorPixelFormat: output.pixelFormat,
            blendMode: system.blendMode,
            isRope: system.usesRibbonGeometry,
            isRefract: isRefract
        )

        let ownsEncoder = sharedEncoder == nil
        let encoder = try sharedEncoder
            ?? makeParticleOutputEncoder(output: output, commandBuffer: commandBuffer)

        var projection = WPEParticleProjection(
            sceneSize: SIMD4<Float>(
                Float(max(sceneSize.width, 1)),
                Float(max(sceneSize.height, 1)),
                0, 0
            )
        )
        let transform = system.sceneTransform
        let averageScale = transform.worldSizeMultiplier()
        if averageScale > 0 {
            projection.modelShape = SIMD4<Float>(
                transform.objectScale.x / averageScale, transform.objectScale.y / averageScale,
                cos(transform.objectAngleZ), sin(transform.objectAngleZ)
            )
        }
        // Translate the whole system by its camera-parallax depth (pixels),
        // carried in `padding.xy` and added to each particle's screen position.
        let parallax = cameraParallax.pixelOffset(
            objectCenter: system.parallaxCenter,
            depth: system.parallaxDepth,
            sceneSize: sceneSize
        )
        // A keyframed ancestor `origin` shifts the whole system, exactly like the parallax offset — ride the same channel rather than rebuilding the system's baked transform every frame.
        projection.padding = SIMD4<Float>(
            parallax.x + system.hostOriginOffset.x,
            parallax.y + system.hostOriginOffset.y,
            0, 0
        )
        // Perspective changes projection, not the authored velocity-to-length multiplier.
        if let trail = system.definition.trailRenderer, trail.kind == .sprite {
            projection.trail = wpeApplyingAuthoredSpriteTrailMinimum(
                from: trail,
                to: SIMD4<Float>(Float(trail.length), Float(trail.maxLength), 0, 1)
            )
            // Atlas aspect; the vertex stage applies the selected frame's UV extent.
            projection.padding.z = Float(texture.height) / Float(max(texture.width, 1))
        }

        if system.definition.isPerspective, !system.usesRibbonGeometry, averageScale > 0,
           let particleViewProjection = frameState.cameraUniforms.particlePerspectiveViewProjectionMatrix {
            let scale = transform.objectScale
            let c = transform.cosAngleZ
            let s = transform.sinAngleZ
            let model = simd_float4x4(columns: (
                SIMD4(c * scale.x, s * scale.x, 0, 0),
                SIMD4(-s * scale.y, c * scale.y, 0, 0),
                SIMD4(0, 0, scale.z, 0), SIMD4(0, 0, 0, 1)
            ))
            if abs(simd_determinant(model)) > 0.000001,
               let viewProjection = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: particleViewProjection) {
                projection.sceneSize.z = 1
                projection.viewProjection = simd_float4x4(columns: (
                    SIMD4<Float>(viewProjection.columns.0), SIMD4<Float>(viewProjection.columns.1),
                    SIMD4<Float>(viewProjection.columns.2), SIMD4<Float>(viewProjection.columns.3)
                ))
                projection.modelToWorld = model
                projection.worldToModel = model.inverse
                projection.eyeAndSizeScale = SIMD4(0, 0, Float(viewProjection.columns.3.w), averageScale)
            }
        }

        let useFrameRects = system.frameRectsBuffer != nil
        var sprite = WPEParticleSpriteParams(
            grid: SIMD4<Float>(
                Float(system.spriteSheet?.cols ?? 1),
                Float(system.spriteSheet?.rows ?? 1),
                Float(system.spriteSheet?.frameCount ?? 1),
                (system.spriteSheet?.isAlphaMask ?? false) ? 1 : 0
            ),
            frameRectMode: SIMD4<Float>(
                useFrameRects ? 1 : 0,
                Float(system.spriteSheet?.frameRects?.count ?? 0),
                system.overbright,
                isRefract ? system.refractAmount : 0   // .w = g_RefractAmount (0 ⇒ non-refract)
            )
        )
        // Compose-group opacity mask + tint, baked from the parent composelayer. Refract binds texture(1)/(2) itself; the two never co-occur (matrix rain is additive-sprite, not refract).
        let groupMask = isRefract ? nil : system.groupOpacityMask
        sprite.tintAndMask = SIMD4<Float>(
            system.groupTint.x, system.groupTint.y, system.groupTint.z,
            groupMask != nil ? 1 : 0
        )

        encoder.setRenderPipelineState(state)
        encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
        encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(customShaderSamplerState(for: texture, useMipmaps: texture.mipmapLevelCount > 1), index: 0)
        if let groupMask {
            encoder.setFragmentTexture(groupMask, index: 1)
        }
        if isRefract {
            // g_Texture1 = refraction normal map; g_Texture3-equivalent = the scene-so-far snapshot. sceneSize lets the fragment turn its pixel position into a screen UV for the background sample.
            encoder.setFragmentTexture(refractNormal, index: 1)
            encoder.setFragmentSamplerState(customShaderSamplerState(for: refractNormal, useMipmaps: (refractNormal?.mipmapLevelCount ?? 1) > 1), index: 1)
            encoder.setFragmentTexture(refractBackground, index: 2)
            encoder.setFragmentBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 1)
        }
        if system.usesRibbonGeometry, let ropeBuffer = system.ropeVertexBuffer {
            // One continuous ribbon strip: 2 edge vertices per knot, built by
            // `tick`. No instancing, no sprite-sheet rects.
            encoder.setVertexBuffer(ropeBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: system.ropeVertexCount
            )
        } else {
            encoder.setVertexBuffer(system.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 3)
            // Buffer(4) must always be bound for the vertex function's signature. Use the system's pre-allocated frame-rect buffer; a 1-element dummy covers the uniform-grid path.
            if let frameRectsBuffer = system.frameRectsBuffer {
                encoder.setVertexBuffer(frameRectsBuffer, offset: 0, index: 4)
            } else {
                var dummyFrameRect = SIMD4<Float>(0, 0, 1, 1)
                encoder.setVertexBytes(&dummyFrameRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
            }
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: system.liveInstanceCount
            )
        }
        if ownsEncoder {
            encoder.endEncoding()
            // Mark the scene target written so a later scene pass loads (instead of clearing) the particles, and any refraction snapshot taken before this draw is invalidated. A shared run defers both to `flushParticles`.
            frameState.registerWrite(texture: output, targetID: .scene)
        }

        #if !LITE_BUILD && DEBUG
        let traceVertices = WPESceneDebugArtifacts.shared.isEnabled
            ? system.particleTraceVertices() : (records: [[String: Any]](), truncated: false)
        WPECanonicalTraceRecorder.shared.recordParticlePass(
            index: traceIndex,
            particleCount: system.liveInstanceCount,
            sprite: texture,
            blendMode: system.blendMode.rawValue,
            nativeState: .particle(blendMode: system.blendMode),
            target: output,
            spriteSheet: system.spriteSheet.map {
                (cols: $0.cols, rows: $0.rows, frames: $0.frameCount, alphaMask: $0.isAlphaMask)
            },
            overbright: system.overbright,
            layerID: system.traceObjectID,
            spritePath: system.definition.materialRelativePath,
            extraTextures: {
                var extras: [WPECanonicalTraceRecorder.ParticleTextureInput] = []
                if isRefract {
                    extras.append(.init(slot: 1, name: "g_Texture1", texture: refractNormal,
                                        path: nil))
                    // WPE's `genericparticle.frag` declares the refraction backdrop as `g_Texture3`. Our Metal pipeline binds it at index 2; report the AUTHORED slot so the diff lines up. Bindings unchanged.
                    extras.append(.init(slot: 3, name: "g_Texture3", texture: refractBackground,
                                        path: "fbo(_rt_FullFrameBuffer)"))
                } else if let groupMask {
                    extras.append(.init(slot: 1, name: "g_Texture1", texture: groupMask, path: nil))
                }
                return extras
            }(),
            vertices: traceVertices.records,
            verticesTruncated: traceVertices.truncated
        )
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "particle-state-\(traceIndex).txt",
                contents: system.particleStateDumpText())
        }
        #endif
        return true
    }

    /// Mirrors `WPEParticleSpriteParams` in `WPEMetalBuiltins.metal`:
    /// `grid` = (cols, rows, frameCount, r8-mask); `frameRectMode` = (explicit-rects, count, overbright, refractAmount); `tintAndMask.w` flags opacity mask.
    struct WPEParticleSpriteParams {
        var grid: SIMD4<Float>
        var frameRectMode: SIMD4<Float>
        var tintAndMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    }

}
#endif
