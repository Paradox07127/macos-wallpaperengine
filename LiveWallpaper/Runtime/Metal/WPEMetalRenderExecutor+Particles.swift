#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

extension WPEMetalRenderExecutor {
    /// One render encoder for particle draws into `output` (`.load`/`.store` so it
    /// composites over the scene so far). Shared across consecutive non-refract
    /// systems by `flushParticles`.
    func makeParticleOutputEncoder(
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "particles")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        WPEFrameOccupancyMeter.count(.particleEncoder)
        return encoder
    }

    /// Encode one particle system on top of `output`, into either its own render
    /// pass (loadAction `.load`) or a caller-owned `sharedEncoder`, on the SHARED
    /// scene command buffer — so particles interleave with layers at their paint
    /// index. Returns false (no encode) when the system has no drawable particles
    /// or its texture is missing.
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
        // REFRACT: needs the normal map AND a snapshot of the scene drawn so far
        // (= `_rt_FullFrameBuffer`) to sample as the refracted background. The
        // snapshot is a blit encoder that cannot coexist with a shared open render
        // encoder, so refraction is only available on this system's OWN pass
        // (`sharedEncoder == nil`); `flushParticles` only ever batches non-refract.
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
        // Translate the whole system by its camera-parallax depth (pixels),
        // carried in `padding.xy` and added to each particle's screen position.
        let parallax = cameraParallax.pixelOffset(
            objectCenter: system.parallaxCenter,
            depth: system.parallaxDepth,
            sceneSize: sceneSize
        )
        // A keyframed ancestor `origin` shifts the whole system, exactly like the
        // parallax offset does — ride the same channel rather than rebuilding the
        // system's baked transform every frame.
        projection.padding = SIMD4<Float>(
            parallax.x + system.hostOriginOffset.x,
            parallax.y + system.hostOriginOffset.y,
            0, 0
        )
        // `spritetrail` orient+stretch mirrors WPE's `genericparticle` TRAILRENDERER path
        // (`common_particles.h` `ComputeParticleTrailTangents`): orient height axis ALONG
        // velocity (`up = normalize(velocity)`), stretch by `clamp(speed*length, minlen,
        // maxlength)`. `g_RenderVar0 = (length, maxlength, minlen, …)` is authored JSON
        // verbatim (not unit-converted); `trail.w > 0.5` enables the path.
        //
        // Orientation matters even at 1×: `ComputeParticlePosition`'s `-up*(uv.y-0.5)`
        // puts texture-top at screen-BOTTOM when velocity points down — rain's
        // `particle/drop` (32×128, bulb-at-top/tail-at-bottom) needs this flip to land
        // bulb-leading; drop it and the drop renders head-up (WRONG).
        //   - `ropetrail` (`.rope`): different shader (`genericropeparticle`), ribbons via
        //     position history / `usesRibbonGeometry`, never stretched.
        //   - perspective (flags&4): keep orientation, PIN stretch to 1× (length→0,
        //     minlen→1) — `perspectiveDepthScale` only grows near particles, so the ~15×
        //     `speed*length` stretch turned every drop into a full-screen line; 1× keeps
        //     the validated 4:1 drop, correctly oriented.
        if let trail = system.definition.trailRenderer, trail.kind == .sprite {
            if system.definition.isPerspective {
                projection.trail = SIMD4<Float>(0, Float(trail.maxLength), 1, 1)
            } else {
                projection.trail = SIMD4<Float>(Float(trail.length), Float(trail.maxLength), 0, 1)
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
        // Compose-group opacity mask (region confine) + tint, baked from the
        // particle's parent composelayer. Refract binds texture(1)/(2) itself;
        // the two never co-occur (matrix rain is additive-sprite, not refract).
        let groupMask = isRefract ? nil : system.groupOpacityMask
        sprite.tintAndMask = SIMD4<Float>(
            system.groupTint.x, system.groupTint.y, system.groupTint.z,
            groupMask != nil ? 1 : 0
        )

        encoder.setRenderPipelineState(state)
        encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
        encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        if let groupMask {
            encoder.setFragmentTexture(groupMask, index: 1)
        }
        if isRefract {
            // g_Texture1 = refraction normal map ; g_Texture3-equivalent = the
            // scene-so-far snapshot. sceneSize (projection) lets the fragment turn
            // its pixel position into a screen UV for the background sample.
            encoder.setFragmentTexture(refractNormal, index: 1)
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
            // Buffer(4) must always be bound for the vertex function's signature.
            // Use the system's pre-allocated frame-rect buffer (any frame count);
            // a 1-element dummy covers the uniform-grid path.
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
            // Mark the scene target written so a later scene pass loads (instead of
            // clearing away) the particles, previous-frame history + full-frame
            // aliases see them, and any refraction snapshot taken before this draw is
            // invalidated before the next interleaved pass requests another. A shared
            // run defers both to `flushParticles` when it ends the run.
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
            target: output,
            spriteSheet: system.spriteSheet.map {
                (cols: $0.cols, rows: $0.rows, frames: $0.frameCount, alphaMask: $0.isAlphaMask)
            },
            overbright: system.overbright,
            layerID: system.traceObjectID,
            spritePath: system.definition.materialRelativePath,
            // Mirror the binds above: REFRACT puts the normal map at 1 and the
            // scene snapshot at 2; otherwise slot 1 is the compose-group mask.
            extraTextures: {
                var extras: [WPECanonicalTraceRecorder.ParticleTextureInput] = []
                if isRefract {
                    extras.append(.init(slot: 1, name: "g_Texture1", texture: refractNormal,
                                        path: nil))
                    // WPE's `genericparticle.frag` declares the refraction
                    // backdrop as `g_Texture3` (default `_rt_FullFrameBuffer`).
                    // Our own Metal pipeline binds it at Metal index 2; report
                    // the AUTHORED slot so the diff lines up. Bindings unchanged.
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
