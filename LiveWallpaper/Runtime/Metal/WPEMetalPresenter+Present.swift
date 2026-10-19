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

extension WPEMetalPresenter {
    /// Own command buffer: static re-present and sync/readback.
    func present(
        texture source: MTLTexture,
        layer: CAMetalLayer,
        fitMode: WPEPresentFitMode = .stretch,
        worldSourceSize: CGSize? = nil,
        uniforms: WPEPresentUniforms? = nil,
        colorTransfer: WPEPresentColorTransfer = .authored,
        presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? = nil
    ) throws -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderError.commandBufferFailed
        }
        WPEFrameOccupancyMeter.count(.sceneCommandBuffer)
        guard try encodePresent(
            texture: source,
            layer: layer,
            fitMode: fitMode,
            worldSourceSize: worldSourceSize,
            uniforms: uniforms,
            colorTransfer: colorTransfer,
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
        uniforms: WPEPresentUniforms? = nil,
        colorTransfer: WPEPresentColorTransfer = .authored,
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
        if uniforms == nil {
            encodedByUpscaler = try encodeUpscaledPresent(source: source, target: drawable.texture,
                                                          fitMode: fitMode, colorTransfer: colorTransfer,
                                                          into: commandBuffer)
        }
        if !encodedByUpscaler {
            // The plan sized this frame down expecting the scaler to restore it. It declined, so give up scaling for the rest of the scene rather than shipping a permanently bilinear-stretched low-resolution frame.
            if upscalePlan.isActive,
               upscalePlan.declineIsConclusive(forDrawableSize: lastPresentedDrawableSize) {
                upscalePlan = upscalePlan.demotedToNative()
                // `previousFrameHistory` is validated against the unchanged WORLD
                // size; discard its lower-resolution history when returning to
                // native rendering instead of feeding stale scaled content back.
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
                target: drawable.texture,
                fitMode: fitMode,
                worldSourceSize: worldSourceSize,
                uniforms: uniforms,
                colorTransfer: colorTransfer,
                into: commandBuffer
            )
        }
        lastPresentPass = WPEPresentPassRecord(
            source: source, fitMode: fitMode, worldSourceSize: worldSourceSize, uniforms: uniforms,
            colorTransfer: colorTransfer, target: drawable.texture, usedMetalFX: encodedByUpscaler
        )

        commandBuffer.present(drawable)
        // The present buffer reads `source` asynchronously; refcount it so the output ring doesn't hand the texture to the next frame's render while this GPU read is still in flight.
        let sourceID = ObjectIdentifier(source)
        let completionSource = PresentCompletionTexture(texture: source)
        let tracker = presentTracker
        tracker.increment(sourceID)
        commandBuffer.addCompletedHandler { cb in
            let releaseSource: @Sendable () -> Void = {
                tracker.decrement(sourceID)
            }
            if let presentCompletion {
                presentCompletion(completionSource.texture, cb, releaseSource)
            } else {
                releaseSource()
            }
        }
        return true
    }

    static func presentFragment(source: MTLPixelFormat, colorTransfer: WPEPresentColorTransfer = .authored) -> String {
        // Sampling a typed sRGB texture already decodes its RGB channels in hardware.
        if colorTransfer == .linear || source == .rgba8Unorm_srgb || source == .bgra8Unorm_srgb {
            return "wpe_present_linear_fragment"
        }
        return switch source {
        case .rgba16Float, .rgba32Float: "wpe_present_hdr_fragment"
        default: "wpe_present_authored_fragment"
        }
    }

    /// Both live presentation and capture use the same terminal transfer, after MetalFX's full-rect map.
    func encodeUpscaledPresent(source: MTLTexture, target: MTLTexture, fitMode: WPEPresentFitMode,
                               colorTransfer: WPEPresentColorTransfer, into commandBuffer: MTLCommandBuffer)
        throws -> Bool {
        guard let upscaler = metalFXUpscaler else { return false }
        let linearOutput = target.pixelFormat == .rgba16Float
        let scalerSource = linearOutput
            ? try encodeLinearPresentationTexture(source: source, colorTransfer: colorTransfer, into: commandBuffer)
            : source
        return try upscaler.encodeIfEligible(source: scalerSource, drawableTexture: target, fitMode: fitMode,
                                             commandBuffer: commandBuffer) { scaled in
            try self.encodePresentPass(source: scaled, target: target, fitMode: .stretch,
                                       worldSourceSize: nil, uniforms: nil,
                                       colorTransfer: linearOutput ? .linear : colorTransfer, into: commandBuffer)
        }
    }

    func encodeLinearPresentationTexture(
        source: MTLTexture, colorTransfer: WPEPresentColorTransfer, into commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        // The parity HDR tail has already converted its RGB. The scaler can read that float texture directly.
        if colorTransfer == .linear {
            return source
        }
        if linearPresentationTexture?.width != source.width || linearPresentationTexture?.height != source.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: source.width, height: source.height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            linearPresentationTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let destination = linearPresentationTexture else {
            throw WPEMetalRenderError.commandBufferFailed
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        let pipeline = try renderPipeline(
            fragmentName: Self.presentFragment(source: source.pixelFormat),
            colorPixelFormat: .rgba16Float
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderError.commandBufferFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return destination
    }

    private func acquireDrawable(from layer: CAMetalLayer) -> CAMetalDrawable? {
        let start = CACurrentMediaTime()
        defer { drawableAcquisitionSeconds += CACurrentMediaTime() - start }
        return layer.nextDrawable()
    }

    func encodePresentPass(
        source: MTLTexture,
        target: MTLTexture,
        fitMode: WPEPresentFitMode,
        worldSourceSize: CGSize?,
        uniforms: WPEPresentUniforms?,
        colorTransfer: WPEPresentColorTransfer = .authored,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let copyState = try renderPipeline(
            vertexName: "wpe_present_vertex",
            fragmentName: Self.presentFragment(source: source.pixelFormat, colorTransfer: colorTransfer),
            colorPixelFormat: target.pixelFormat
        )
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "present")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderError.commandBufferFailed
        }
        encoder.applyTraceLabel("present")
        WPEFrameOccupancyMeter.count(.presentEncoder)
        encoder.setRenderPipelineState(copyState)
        encoder.setFragmentTexture(source, index: 0)
        var presentUniforms = uniforms ?? WPEPresentUniforms.make(
            fitMode: fitMode,
            sourceWidth: worldSourceSize.map { Int($0.width) } ?? source.width,
            sourceHeight: worldSourceSize.map { Int($0.height) } ?? source.height,
            targetWidth: target.width,
            targetHeight: target.height
        )
        encoder.setVertexBytes(&presentUniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
#endif
