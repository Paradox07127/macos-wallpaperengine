import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// Only full-display system wallpaper windows below desktop icons can enter the preview.
enum DesktopWallpaperWindow {
    static func matches(bundleIdentifier: String?, layer: Int, frame: CGRect, displayBounds: CGRect) -> Bool {
        guard ["com.apple.wallpaper.agent", "com.apple.dock", "com.apple.WindowManager"].contains(bundleIdentifier),
              // WallpaperAgent: desktop − 2; WindowManager (Aerials): desktop − 1; legacy Dock: desktop.
              (Int(CGWindowLevelForKey(.desktopWindow)) - 2 ... Int(CGWindowLevelForKey(.desktopWindow))).contains(layer),
              displayBounds.width > 0, displayBounds.height > 0 else { return false }
        if bundleIdentifier == "com.apple.WindowManager", layer != Int(CGWindowLevelForKey(.desktopWindow)) - 1 {
            return false
        }
        return abs(frame.minX - displayBounds.minX) <= 2
            && abs(frame.minY - displayBounds.minY) <= 2
            && abs(frame.width - displayBounds.width) <= 2
            && abs(frame.height - displayBounds.height) <= 2
    }
}

@MainActor
enum DesktopWallpaperPreview {
    static func load(for screen: Screen) async -> CGImage? {
        if CGPreflightScreenCaptureAccess(), let image = await captureWallpaper(displayID: screen.id) {
            return image
        }
        // Modern macOS can return DefaultDesktop.heic for unrelated per-display wallpapers.
        // Never silently present that placeholder as the selected display's actual wallpaper.
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen.nsScreen),
              !url.lastPathComponent.hasPrefix("DefaultDesktop"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func captureWallpaper(displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let metadata = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let layers = Dictionary(metadata.compactMap { info -> (CGWindowID, Int)? in
                guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                      let layer = info[kCGWindowLayer as String] as? Int else { return nil }
                return (id, layer)
            }, uniquingKeysWith: { first, _ in first })
            let wallpaper = content.windows.first(where: {
                DesktopWallpaperWindow.matches(bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                                               layer: layers[$0.windowID] ?? 0,
                                               frame: $0.frame, displayBounds: display.frame)
            })
            guard let wallpaper else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = min(1600, display.width)
            configuration.height = max(1, Int(Double(configuration.width) * Double(display.height) / Double(max(1, display.width))))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: wallpaper), configuration: configuration
            )
        } catch {
            // An unavailable wallpaper must not fall back to capturing the whole desktop.
            return nil
        }
    }
}
