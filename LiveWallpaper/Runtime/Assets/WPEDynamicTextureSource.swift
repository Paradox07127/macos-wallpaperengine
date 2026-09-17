#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

protocol WPEDynamicTextureSource: AnyObject {
    func texture(at time: TimeInterval) -> MTLTexture?
    func texture(at time: TimeInterval, frameSlot: Int) -> MTLTexture?
    /// Sampling transform that corresponds to the texture returned for this
    /// exact frame binding. `nil` means no authored TEXS descriptor exists.
    func samplingDescriptor(
        at time: TimeInterval,
        frameSlot: Int
    ) -> WPETexSpriteSamplingDescriptor?
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func invalidate()

    /// True when this source decoded a frame whose GPU work still has to ride
    /// the renderer's scene command buffer (see the three calls below).
    var hasStagedFrameWork: Bool { get }
    var stagedFrameWorkEncodingFailed: Bool { get }
    /// Encode before any pass samples this source. Metal requires fence completed-handlers before commit.
    func encodeStagedFrameWork(into commandBuffer: MTLCommandBuffer)
    func commitStagedFrameWork()
    /// Keep the published frame and leave staged; a merged present with nil `nextDrawable` still commits.
    func rollbackStagedFrameWork()
}

extension WPEDynamicTextureSource {
    /// Immutable textures ignore frameSlot; CPU-overwritten sources override with per-slot storage.
    func texture(at time: TimeInterval, frameSlot: Int) -> MTLTexture? {
        _ = frameSlot
        return texture(at: time)
    }

    func samplingDescriptor(
        at time: TimeInterval,
        frameSlot: Int
    ) -> WPETexSpriteSamplingDescriptor? {
        _ = time
        _ = frameSlot
        return nil
    }

    var hasStagedFrameWork: Bool {
        false
    }

    var stagedFrameWorkEncodingFailed: Bool {
        false
    }

    func encodeStagedFrameWork(into commandBuffer: MTLCommandBuffer) {
        _ = commandBuffer
    }

    func commitStagedFrameWork() {}
    func rollbackStagedFrameWork() {}
}
#endif
