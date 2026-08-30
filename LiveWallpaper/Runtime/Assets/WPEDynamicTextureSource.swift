#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Evolving texture sources (animated .tex / embedded MP4). Not `@MainActor` (render actor).
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
    /// Encode into the frame's scene command buffer, before any pass samples
    /// this source. Fence completed-handlers are armed here because Metal
    /// requires them before commit — nothing is published yet.
    func encodeStagedFrameWork(into commandBuffer: MTLCommandBuffer)
    /// The scene command buffer was committed: publish the staged frame and
    /// hand the frame it replaced to that buffer's fence.
    func commitStagedFrameWork()
    /// The scene command buffer was dropped before commit (encode throw, `makeCommandBuffer`
    /// failure, in-flight budget exhausted, no renderable passes): keep the published frame,
    /// leave staged for the next buffer. NOT a drawable miss — a merged present whose
    /// `nextDrawable` comes back nil still commits, so the frame advances but doesn't reach the screen.
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

    /// Sources that own their uploads outright (every `.tex` path) never stage
    /// frame work; only the video source overrides these.
    var hasStagedFrameWork: Bool { false }
    func encodeStagedFrameWork(into commandBuffer: MTLCommandBuffer) { _ = commandBuffer }
    func commitStagedFrameWork() {}
    func rollbackStagedFrameWork() {}
}
#endif
