import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperCore
#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

/// A card's GIF preview with every frame decoded, and how long each frame shows.
struct ShelfPreviewFrames: Sendable {
    let images: [CGImage]
    let delays: [TimeInterval]

    /// Nil unless `origin`'s preview file animates within the preview decode budget; Lite has no scene previews.
    static func load(_ origin: WPEOrigin, maxPixelSize: Int) async -> ShelfPreviewFrames? {
        #if LITE_BUILD
        return nil
        #else
        return await PreviewWorkGate.shared.runDetached {
            guard let url = origin.sourcePreviewURL,
                  let folder = try? SecurityScopedBookmarkResolver.shared
                  .resolve(origin.sourceFolderBookmark, target: .transient).get() else { return nil }
            return SecurityScopedBookmarkResolver.withScopedAccess(folder.url) { _ in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return decode(data, maxPixelSize: maxPixelSize)
            }
        }
        #endif
    }

    #if !LITE_BUILD
    /// Every frame at most `maxPixelSize` on its long edge; nil for a still or an animation over the budget.
    static func decode(_ data: Data, maxPixelSize: Int) -> ShelfPreviewFrames? {
        guard let decoded = WPEPreviewDecodedImage.decode(data, maxPixelSize: maxPixelSize), decoded.frameCount > 1 else {
            return nil
        }
        var images: [CGImage] = []
        for index in 0 ..< decoded.frameCount {
            guard !Task.isCancelled, let frame = decoded.frame(at: index) else { return nil }
            images.append(frame)
        }
        return ShelfPreviewFrames(images: images, delays: decoded.frameDelays)
    }
    #endif
}
