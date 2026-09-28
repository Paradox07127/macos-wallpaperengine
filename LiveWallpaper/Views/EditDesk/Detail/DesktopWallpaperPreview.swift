import AppKit
import ImageIO

@MainActor
enum DesktopWallpaperPreview {
    static func load(for screen: Screen) async -> CGImage? {
        load(from: NSWorkspace.shared.desktopImageURL(for: screen.nsScreen))
    }

    static func load(from url: URL?) -> CGImage? {
        // Modern macOS can return DefaultDesktop.heic for unrelated per-display wallpapers.
        // An unavailable local image leaves the setup page without a wallpaper preview.
        guard let url, url.isFileURL,
              !url.lastPathComponent.hasPrefix("DefaultDesktop"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
