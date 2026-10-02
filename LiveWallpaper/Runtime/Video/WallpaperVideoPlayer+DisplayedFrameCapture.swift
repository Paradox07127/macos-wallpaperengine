import AppKit
@preconcurrency import AVFoundation
import CoreImage
import LiveWallpaperCore
import Metal
import QuartzCore

extension WallpaperVideoPlayer {
    /// The picture the player layer is showing, laid out in the window's backing pixels and converted to
    /// `colorSpace`. nil = no item, EDR, the picture not covering the whole window, no frame in time,
    /// cleanup/suspension mid-capture, or cancellation.
    func captureDisplayedFrame(
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat,
        colorSpace: CGColorSpace
    ) async -> (any MTLTexture)? {
        guard !isCleanedUp, !usesExtendedDynamicRange,
              let item = player?.currentItem,
              let contentView = playbackWindow?.contentView,
              let scale = playbackWindow?.backingScaleFactor else { return nil }
        // `_srgb` targets encode again on write, so Core Image must hand them linear values.
        let renderColorSpace: CGColorSpace
        if pixelFormat == .rgba8Unorm_srgb || pixelFormat == .bgra8Unorm_srgb {
            guard let linear = CGColorSpaceCreateLinearized(colorSpace) else { return nil }
            renderColorSpace = linear
        } else {
            renderColorSpace = colorSpace
        }
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
        let oriented = CIImage(cvPixelBuffer: frame).transformed(by: orientation)
        let placement = Self.placement(of: oriented.extent.size, in: layerRect, gravity: currentFitMode.avLayerVideoGravity)
        // The composite layer is opaque, so any canvas the picture leaves uncovered would show as black.
        guard placement.insetBy(dx: -0.5, dy: -0.5).contains(canvas) else { return nil }
        let image = Self.displayedImage(frame: oriented, placement: placement, canvas: canvas)
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
        context.render(image, to: texture, commandBuffer: commandBuffer, bounds: canvas, colorSpace: renderColorSpace)
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

    /// Where `AVPlayerLayer` draws a picture of `size` for `gravity` inside `layerRect`.
    private static func placement(of size: CGSize, in layerRect: CGRect, gravity: AVLayerVideoGravity) -> CGRect {
        var scaleX = layerRect.width / size.width
        var scaleY = layerRect.height / size.height
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
        let width = size.width * scaleX
        let height = size.height * scaleY
        return CGRect(x: layerRect.midX - width / 2, y: layerRect.midY - height / 2, width: width, height: height)
    }

    /// Stretches `frame` onto `placement` over the window's background — clear: the window is non-opaque
    /// and neither the container nor the player layer paints one.
    private static func displayedImage(frame: CIImage, placement: CGRect, canvas: CGRect) -> CIImage {
        let source = frame.extent
        let placed = frame
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: placement.width / source.width, y: placement.height / source.height))
            .transformed(by: CGAffineTransform(translationX: placement.minX, y: placement.minY))
        return placed
            .composited(over: CIImage(color: .clear).cropped(to: canvas))
            .cropped(to: canvas)
    }
}
