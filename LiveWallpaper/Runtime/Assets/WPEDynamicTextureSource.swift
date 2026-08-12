#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Metal

/// Evolving texture sources (animated .tex / embedded MP4). Not `@MainActor` (render actor).
protocol WPEDynamicTextureSource: AnyObject {
    func texture(at time: TimeInterval) -> MTLTexture?
    func texture(at time: TimeInterval, frameSlot: Int) -> MTLTexture?
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func invalidate()
}

extension WPEDynamicTextureSource {
    /// Immutable textures ignore frameSlot; CPU-overwritten sources override with per-slot storage.
    func texture(at time: TimeInterval, frameSlot: Int) -> MTLTexture? {
        _ = frameSlot
        return texture(at: time)
    }
}
#endif
