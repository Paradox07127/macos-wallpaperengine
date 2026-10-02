import AppKit
@preconcurrency import AVFoundation
import CoreImage
import LiveWallpaperCore
import Metal
import QuartzCore

extension WallpaperVideoPlayer {
    /// The picture the player layer is showing, laid out in the window's backing pixels and converted to
    /// `colorSpace`. nil = no item, EDR, no frame in time, cleanup/suspension mid-capture, or cancellation.
    func captureDisplayedFrame(
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat,
        colorSpace: CGColorSpace
    ) async -> (any MTLTexture)? {
        guard !isCleanedUp, !usesExtendedDynamicRange,
              let item = player?.currentItem,
              let contentView = playbackWindow?.contentView,
              let scale = playbackWindow?.backingScaleFactor else { return nil }
        // Orientation lives in the track transform; a composition already applied it.
        let orientation: CGAffineTransform = item.videoComposition == nil ? await Self.preferredTransform(of: item) : .identity
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: WallpaperVideoOutputNegotiation.pixelBufferAttributes(forcingBGRA: true)
        )
        bindVideoOutput(output, to: item)
        defer { unbindVideoOutput(output, from: item) }

        // Not gated on `hasNewPixelBuffer`: a paused item never reports one, yet copying at its current time
        // still yields the frame on screen after a few polls.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        var copied: CVPixelBuffer?
        while copied == nil {
            guard isCapturing(output, from: item), ContinuousClock.now < deadline else { return nil }
            copied = output.copyPixelBuffer(
                forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()),
                itemTimeForDisplay: nil
            )
            if copied == nil {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return nil
                }
            }
        }
        guard let frame = copied else { return nil }

        let canvas = CGRect(
            x: 0, y: 0,
            width: (contentView.bounds.width * scale).rounded(),
            height: (contentView.bounds.height * scale).rounded()
        )
        let layerFrame = currentSpanRenderConfiguration?.canvasFrameInScreenCoordinates ?? contentView.bounds
        let layerRect = CGRect(
            x: layerFrame.minX * scale, y: layerFrame.minY * scale,
            width: layerFrame.width * scale, height: layerFrame.height * scale
        )
        let image = Self.displayedImage(
            frame: CIImage(cvPixelBuffer: frame).transformed(by: orientation),
            layerRect: layerRect,
            gravity: currentFitMode.avLayerVideoGravity,
            canvas: canvas
        )
        // Core Image fills a Metal texture from y = 0 upward; without the flip row 0 would hold the picture's bottom.
        .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -canvas.height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(canvas.width),
            height: Int(canvas.height),
            mipmapped: false
        )
        // Core Image refuses a destination texture without `.shaderWrite`.
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        context.render(image, to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: colorSpace)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed, isCapturing(output, from: item) else { return nil }
        return texture
    }

    /// `drainVideoOutputs` (suspension, hibernation, cleanup) unbinds the output; that ends the capture.
    private func isCapturing(_ output: AVPlayerItemVideoOutput, from item: AVPlayerItem) -> Bool {
        !Task.isCancelled
            && !isCleanedUp
            && !usesExtendedDynamicRange
            && player?.currentItem === item
            && boundVideoOutputs.contains { $0.output === output }
    }

    /// Places `frame` the way `AVPlayerLayer` does for `gravity` inside `layerRect`, over the window's
    /// background — clear: the window is non-opaque and neither the container nor the player layer paints one.
    private static func displayedImage(
        frame: CIImage,
        layerRect: CGRect,
        gravity: AVLayerVideoGravity,
        canvas: CGRect
    ) -> CIImage {
        let source = frame.extent
        var scaleX = layerRect.width / source.width
        var scaleY = layerRect.height / source.height
        switch gravity {
        case .resizeAspect:
            scaleX = min(scaleX, scaleY)
            scaleY = scaleX
        case .resizeAspectFill:
            scaleX = max(scaleX, scaleY)
            scaleY = scaleX
        default:
            break
        }
        let placed = frame
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: layerRect.midX - source.width * scaleX / 2,
                y: layerRect.midY - source.height * scaleY / 2
            ))
        return placed
            .composited(over: CIImage(color: .clear).cropped(to: canvas))
            .cropped(to: canvas)
    }
}
