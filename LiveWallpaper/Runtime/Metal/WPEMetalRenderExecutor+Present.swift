#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import QuartzCore
import simd

/// Process-wide drawable-miss tally so the warning below stays rate-limited
/// across every executor instance (misses tend to burst on all displays at once).
private let presentDrawableMissCount = OSAllocatedUnfairLock(initialState: 0)

extension WPEMetalRenderExecutor {
    typealias DeferredPresentEncoder = (MTLTexture, MTLCommandBuffer) throws -> Bool

    /// Own command buffer: static re-present and sync/readback.
    func present(
        texture source: MTLTexture,
        layer: CAMetalLayer,
        fitMode: WPEPresentFitMode = .stretch,
        worldSourceSize: CGSize? = nil,
        presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? = nil
    ) throws -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        WPEFrameOccupancyMeter.count(.sceneCommandBuffer)
        guard try encodePresent(
            texture: source,
            layer: layer,
            fitMode: fitMode,
            worldSourceSize: worldSourceSize,
            presentCompletion: presentCompletion,
            into: commandBuffer
        ) else {
            // Drawable miss: the un-committed buffer is simply dropped.
            return false
        }
        commandBuffer.commit()
        return true
    }

    /// `worldSourceSize`: the WORLD canvas the source represents when render scaling shrank it. Only `.center` consumes it — centering the reduced texture would otherwise shrink the picture on screen by the pixel scale.
    func encodePresent(
        texture source: MTLTexture,
        layer: CAMetalLayer,
        fitMode: WPEPresentFitMode,
        worldSourceSize: CGSize? = nil,
        presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)?,
        into commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        // Pull the drawable straight from the layer. The MTKView host is paused (a CADisplayLink on the render thread paces frames), so nothing else acquires `currentDrawable` — no double-acquire.
        #if DEBUG
        let forceDrawableMiss = remainingForcedDrawableMissesForTesting > 0
        if forceDrawableMiss {
            remainingForcedDrawableMissesForTesting -= 1
        }
        #else
        let forceDrawableMiss = false
        #endif
        guard !forceDrawableMiss, let drawable = acquireDrawable(from: layer) else {
            // A dropped frame, not an error — but a sustained run means drawable starvation, so keep it visible in Release: first 5 misses, then every 300th.
            let missCount = presentDrawableMissCount.withLock { count -> Int in
                count += 1
                return count
            }
            if missCount <= 5 || missCount % 300 == 0 {
                Logger.warning(
                    "[present] layer.nextDrawable()=nil (miss #\(missCount)) — source=\(source.width)x\(source.height) drawableSize=\(layer.drawableSize)",
                    category: .wpeRender
                )
            }
            return false
        }

        lastPresentedDrawableSize = CGSize(
            width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height)
        )
        var encodedByUpscaler = false
        if let upscaler = metalFXUpscaler {
            encodedByUpscaler = upscaler.encodeIfEligible(
                source: source,
                drawableTexture: drawable.texture,
                fitMode: fitMode,
                commandBuffer: commandBuffer
            )
        }
        if !encodedByUpscaler {
            // The plan sized this frame down expecting the scaler to restore it. It declined, so give up scaling for the rest of the scene rather than shipping a permanently bilinear-stretched low-resolution frame.
            if upscalePlan.isActive,
               upscalePlan.declineIsConclusive(forDrawableSize: lastPresentedDrawableSize) {
                upscalePlan = upscalePlan.demotedToNative()
                // `previousFrameHistory` is validated against the WORLD size, unchanged here, so its old smaller textures would keep being served to `.previous` — and `copyTexture` sizes the blit from the DESTINATION, a validation error once the destination grows.
                notePresentSideDemotion()
                Logger.notice(
                    "[metalfx] scaler declined a planned frame — rendering native for this scene "
                        + "(source=\(source.width)x\(source.height) drawable="
                        + "\(drawable.texture.width)x\(drawable.texture.height))",
                    category: .wpeRender
                )
            }
            try encodePresentPass(
                source: source,
                drawable: drawable,
                fitMode: fitMode,
                worldSourceSize: worldSourceSize,
                into: commandBuffer
            )
        }

        commandBuffer.present(drawable)
        // The present buffer reads `source` asynchronously; refcount it so the output ring doesn't hand the texture to the next frame's render while this GPU read is still in flight.
        let sourceID = ObjectIdentifier(source)
        let completionSource = PresentCompletionTexture(texture: source)
        let tracker = presentTracker
        let sink = gpuErrorSink
        tracker.increment(sourceID)
        commandBuffer.addCompletedHandler { cb in
            let releaseSource: @Sendable () -> Void = {
                tracker.decrement(sourceID)
            }
            if cb.status == .error {
                sink.record("present: \(cb.error?.localizedDescription ?? "unknown")")
            }
            if let presentCompletion {
                presentCompletion(completionSource.texture, cb, releaseSource)
            } else {
                releaseSource()
            }
        }
        return true
    }

    private func acquireDrawable(from layer: CAMetalLayer) -> CAMetalDrawable? {
        let start = CACurrentMediaTime()
        defer { drawableAcquisitionSeconds += CACurrentMediaTime() - start }
        return layer.nextDrawable()
    }

    private func encodePresentPass(
        source: MTLTexture,
        drawable: CAMetalDrawable,
        fitMode: WPEPresentFitMode,
        worldSourceSize: CGSize?,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let copyState = try renderPipeline(
            vertexName: "wpe_present_vertex",
            fragmentName: "wpe_present_fragment",
            blendMode: "disabled",
            // The wallpaper window is transparent, but its wallpaper content is terminal and opaque. The fragment writes alpha=1 explicitly; do not encode that contract indirectly through a color write mask.
            alphaWritePolicy: .all,
            colorPixelFormat: drawable.texture.pixelFormat
        )
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "present")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("present")
        WPEFrameOccupancyMeter.count(.presentEncoder)
        encoder.setRenderPipelineState(copyState)
        encoder.setFragmentTexture(source, index: 0)
        var presentUniforms = WPEPresentUniforms.make(
            fitMode: fitMode,
            sourceWidth: worldSourceSize.map { Int($0.width) } ?? source.width,
            sourceHeight: worldSourceSize.map { Int($0.height) } ?? source.height,
            targetWidth: drawable.texture.width,
            targetHeight: drawable.texture.height
        )
        encoder.setVertexBytes(&presentUniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    func clearColor(for targetID: WPEMetalTargetID) -> MTLClearColor {
        switch targetID {
        case .scene:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .named:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// WPE HDR bloom pyramid: prefilter (soft-knee threshold + strength/17 + tint) into a half-res chain, 4-tap box downsamples, scatter-weighted SRC_ALPHA/ONE upsamples, additive composite. HDR scenes render to rgba16Float so the prefilter sees real >1 overbright; `hdr:false` scenes clamp at 8-bit.
    func encodeSceneBloomIfNeeded(
        cameraUniforms: WPEMetalCameraUniforms,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard Self.isSceneBloomEnabled, let bloom = cameraUniforms.bloom else { return }
        ensureBloomLevels(for: output, levelCount: min(max(bloom.iterations, 1), 6))
        let levels = bloomLevelTextures.count
        guard levels >= 1 else { return }

        let threshold = Float(bloom.threshold)
        let knee = threshold * Float(1 - min(max(bloom.feather, 0), 1))
        let kneeSpan = max(threshold - knee, 0.0001)
        let blendParams = SIMD4<Float>(threshold, knee, 2 * kneeSpan, 0.25 / kneeSpan)
        let strength = Float(bloom.strength) / 17
        let scatterAlpha = min(max(Float(bloom.scatter) * 0.25, 0), 1)
        let tint = SIMD4<Float>(Float(bloom.tint.x), Float(bloom.tint.y), Float(bloom.tint.z), 1)

        func texel(of texture: MTLTexture) -> SIMD2<Float> {
            SIMD2<Float>(1 / Float(max(texture.width, 1)), 1 / Float(max(texture.height, 1)))
        }

        func draw(
            into destination: MTLTexture,
            source: MTLTexture,
            fragment: String,
            blendMode: String,
            uniforms: WPEBloomUniforms
        ) throws {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            // "disabled" = the prefilter/downsample passes fully overwrite the target (blending off), so prior content can be discarded. "normal" would fall through to straight-alpha blend and read this `.dontCare` destination whenever a source pixel had alpha < 1.
            descriptor.colorAttachments[0].loadAction = blendMode == "disabled" ? .dontCare : .load
            descriptor.colorAttachments[0].storeAction = .store
            gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "bloom|\(fragment)")
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
            encoder.applyTraceLabel("bloom|\(fragment)")
            WPEFrameOccupancyMeter.count(.bloomEncoder)
            defer { encoder.endEncoding() }
            encoder.setRenderPipelineState(try renderPipeline(
                vertexName: "wpe_fullscreen_vertex",
                fragmentName: fragment,
                blendMode: blendMode,
                colorPixelFormat: destination.pixelFormat,
                depthPixelFormat: .invalid
            ))
            var uniforms = uniforms
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBloomUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        let sceneTexel = texel(of: output)
        try draw(
            into: bloomLevelTextures[0],
            source: output,
            fragment: "wpe_bloom_prefilter_fragment",
            blendMode: "disabled",
            uniforms: WPEBloomUniforms(
                texelAndWeight: SIMD4<Float>(sceneTexel.x, sceneTexel.y, strength, 0),
                blendParams: blendParams,
                tint: tint
            )
        )
        for level in 1..<levels {
            let source = bloomLevelTextures[level - 1]
            let t = texel(of: source)
            try draw(
                into: bloomLevelTextures[level],
                source: source,
                fragment: "wpe_bloom_downsample_fragment",
                blendMode: "disabled",
                uniforms: WPEBloomUniforms(
                    texelAndWeight: SIMD4<Float>(t.x, t.y, 0, 0),
                    blendParams: .zero,
                    tint: tint
                )
            )
        }
        var level = levels - 1
        while level >= 1 {
            let destination = bloomLevelTextures[level - 1]
            let t = texel(of: destination)
            try draw(
                into: destination,
                source: bloomLevelTextures[level],
                fragment: "wpe_bloom_upsample_fragment",
                blendMode: "additive",
                uniforms: WPEBloomUniforms(
                    texelAndWeight: SIMD4<Float>(t.x, t.y, scatterAlpha, 0),
                    blendParams: .zero,
                    tint: tint
                )
            )
            level -= 1
        }
        let compositeTexel = texel(of: bloomLevelTextures[0])
        try draw(
            into: output,
            source: bloomLevelTextures[0],
            fragment: "wpe_bloom_upsample_fragment",
            blendMode: "additive",
            uniforms: WPEBloomUniforms(
                texelAndWeight: SIMD4<Float>(compositeTexel.x, compositeTexel.y, 1, 0),
                blendParams: .zero,
                tint: tint
            )
        )
    }

    private func ensureBloomLevels(for output: MTLTexture, levelCount: Int) {
        if bloomLevelBaseWidth == output.width,
           bloomLevelBaseHeight == output.height,
           bloomLevelPixelFormat == output.pixelFormat,
           bloomLevelRequestedCount == levelCount {
            return
        }
        releaseBloomLevels()
        bloomLevelBaseWidth = output.width
        bloomLevelBaseHeight = output.height
        bloomLevelPixelFormat = output.pixelFormat
        bloomLevelRequestedCount = levelCount

        var descriptors: [MTLTextureDescriptor] = []
        var width = output.width / 2
        var height = output.height / 2
        for _ in 0..<levelCount {
            guard width >= 8, height >= 8 else { break }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: output.pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptors.append(descriptor)
            width /= 2
            height /= 2
        }
        guard !descriptors.isEmpty else { return }

        var heapSize = 0
        var maxAlign = 1
        for descriptor in descriptors {
            let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
            guard sizeAndAlign.size > 0 else { heapSize = 0; break }
            maxAlign = max(maxAlign, sizeAndAlign.align)
            heapSize += WPEMetalRenderTargetPool.align(sizeAndAlign.size, to: sizeAndAlign.align)
        }
        if heapSize > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.type = .automatic
            heapDescriptor.storageMode = .private
            heapDescriptor.hazardTrackingMode = .tracked
            heapDescriptor.size = WPEMetalRenderTargetPool.align(heapSize + maxAlign, to: maxAlign)
            bloomLevelHeap = device.makeHeap(descriptor: heapDescriptor)
        }

        for (index, descriptor) in descriptors.enumerated() {
            let texture = bloomLevelHeap?.makeTexture(descriptor: descriptor)
                ?? device.makeTexture(descriptor: descriptor)
            guard let texture else { break }
            texture.label = "wpe.bloom.level\(index)"
            bloomLevelTextures.append(texture)
        }
    }

    func releaseBloomLevels() {
        bloomLevelTextures = []
        bloomLevelHeap = nil
        bloomLevelBaseWidth = 0
        bloomLevelBaseHeight = 0
        bloomLevelPixelFormat = .invalid
        bloomLevelRequestedCount = 0
    }

}

// MARK: - Engine colour correction

extension WPEMetalRenderExecutor {

    /// Returns `output` untouched when the correction is an identity — a full-frame 4K pass that provably changes nothing isn't worth its bandwidth.
    func encodeColorCorrectionIfNeeded(
        _ correction: WPEEngineColorCorrection,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        guard !correction.isIdentity else { return output }

        // From the output pool, not a texture of its own: this one *is* the frame once returned, so it obeys the same reuse rules. A private permanently-reused scratch once let a later frame overwrite one a detached poster readback was still reading.
        let destination = try makeOutputTexture(
            size: CGSize(width: output.width, height: output.height)
        )
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        // Every pixel is written by the fullscreen draw, so the prior contents
        // are dead — loading them would cost a 4K read for nothing.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "colorCorrection")

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("colorCorrection")
        WPEFrameOccupancyMeter.count(.colorCorrectionEncoder)
        defer { encoder.endEncoding() }

        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_fullscreen_vertex",
            fragmentName: "wpe_color_correction_fragment",
            // "disabled": the draw replaces the target outright. Any blend mode
            // here would read the `.dontCare` contents above.
            blendMode: "disabled",
            colorPixelFormat: destination.pixelFormat,
            depthPixelFormat: .invalid
        ))
        var uniforms = WPEColorCorrectionUniforms(
            brightness: Float(correction.brightness),
            contrast: Float(correction.contrast),
            saturation: Float(correction.saturation),
            hueRadians: Float(correction.hueDegrees * .pi / 180)
        )
        encoder.setFragmentTexture(output, index: 0)
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<WPEColorCorrectionUniforms>.stride, index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return destination
    }

}

/// Mirrors `WPEColorCorrectionUniforms` in WPEMetalBuiltins.metal.
struct WPEColorCorrectionUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var hueRadians: Float
}

#endif
