#if !LITE_BUILD
import CoreGraphics
import Metal
import os

/// A full-resolution copy of what the present pass last put on screen, encoded exactly as the drawable was.
struct WPEDisplayedFrameCapture: @unchecked Sendable { // MTLTexture lacks the SDK annotation; the GPU write completes before the value is vended and nothing writes it afterwards.
    let texture: MTLTexture
    let pixelFormat: MTLPixelFormat
    let colorSpace: CGColorSpace?
    /// True for an rgba16Float target: values are extended-linear and may exceed 1.
    let isEDR: Bool
}

/// Inputs of the last present that reached a drawable, so a capture can replay that exact pass.
struct WPEPresentPassRecord {
    let fitMode: WPEPresentFitMode
    let worldSourceSize: CGSize?
    let uniforms: WPEPresentUniforms?
    let targetWidth: Int
    let targetHeight: Int
    let targetPixelFormat: MTLPixelFormat
    /// MetalFX wrote the drawable itself; replaying the present pass would not reproduce that frame.
    let usedMetalFX: Bool

    init(
        fitMode: WPEPresentFitMode,
        worldSourceSize: CGSize?,
        uniforms: WPEPresentUniforms?,
        target: MTLTexture,
        usedMetalFX: Bool
    ) {
        self.fitMode = fitMode
        self.worldSourceSize = worldSourceSize
        self.uniforms = uniforms
        targetWidth = target.width
        targetHeight = target.height
        targetPixelFormat = target.pixelFormat
        self.usedMetalFX = usedMetalFX
    }
}

/// Resumes its continuation at most once, whichever of GPU completion or task cancellation comes first.
final class WPEDisplayedFrameCaptureResumer: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<WPEDisplayedFrameCapture?, Never>?>(
        initialState: nil
    )

    func install(_ continuation: CheckedContinuation<WPEDisplayedFrameCapture?, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(returning capture: WPEDisplayedFrameCapture?) {
        let pending = continuation.withLock { state in
            defer { state = nil }
            return state
        }
        pending?.resume(returning: capture)
    }
}

extension WPEMetalRenderExecutor {
    /// `completion` runs on a Metal callback thread, with nil when nothing reproducible was presented or the GPU failed.
    func encodeDisplayedFrameCapture(
        source: MTLTexture,
        colorSpace: CGColorSpace?,
        completion: @escaping @Sendable (WPEDisplayedFrameCapture?) -> Void
    ) {
        guard let pass = lastPresentPass, !pass.usedMetalFX else {
            completion(nil)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pass.targetPixelFormat, width: pass.targetWidth, height: pass.targetHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        target.label = "wpe.displayedFrameCapture"
        do {
            try encodePresentPass(
                source: source,
                target: target,
                fitMode: pass.fitMode,
                worldSourceSize: pass.worldSourceSize,
                uniforms: pass.uniforms,
                into: commandBuffer
            )
        } catch {
            completion(nil)
            return
        }
        let capture = WPEDisplayedFrameCapture(
            texture: target,
            pixelFormat: target.pixelFormat,
            colorSpace: colorSpace,
            isEDR: WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: target.pixelFormat)
        )
        // Same guard as `encodePresent`: keeps the output ring from re-rendering `source` while this pass reads it.
        let sourceID = ObjectIdentifier(source)
        let tracker = presentTracker
        tracker.increment(sourceID)
        commandBuffer.addCompletedHandler { commandBuffer in
            tracker.decrement(sourceID)
            completion(commandBuffer.status == .completed ? capture : nil)
        }
        commandBuffer.commit()
    }
}
#endif
