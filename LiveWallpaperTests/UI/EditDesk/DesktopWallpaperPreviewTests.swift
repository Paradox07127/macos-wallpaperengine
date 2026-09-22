import CoreGraphics
@testable import LiveWallpaper
import Testing

@Suite("Desktop wallpaper capture isolation")
struct DesktopWallpaperPreviewTests {
    private let target = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let desktop = Int(CGWindowLevelForKey(.desktopWindow))

    @Test("Current and legacy wallpaper windows match only their selected display")
    func wallpaperWindow() {
        #expect(DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.wallpaper.agent", layer: desktop - 2,
                                               frame: target, displayBounds: target))
        #expect(DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.WindowManager", layer: desktop - 1,
                                               frame: target, displayBounds: target))
        #expect(DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.dock", layer: desktop,
                                               frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.wallpaper.agent", layer: desktop - 2,
                                                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayBounds: target))
    }

    @Test("App windows, desktop icons and spanning windows never enter a wallpaper preview")
    func excludesNonWallpaperContent() {
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.finder", layer: desktop,
                                                frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.wallpaper.agent", layer: 0,
                                                frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.loomscreen.pro", layer: desktop,
                                                frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.WindowManager", layer: desktop,
                                                frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: nil, layer: desktop,
                                                frame: target, displayBounds: target))
        #expect(!DesktopWallpaperWindow.matches(bundleIdentifier: "com.apple.wallpaper.agent", layer: desktop,
                                                frame: CGRect(x: -1920, y: 0, width: 3840, height: 1080), displayBounds: target))
    }
}
