import AppKit
import Testing
@testable import LiveWallpaper
@testable import LiveWallpaperCore

/// The wallpaper window carries every wallpaper type (video, HTML, Metal scene,
/// ambient), so one wrong flag here silently changes behaviour for all of them.
@Suite("Wallpaper window capture policy", .serialized)
@MainActor
struct VideoWallpaperWindowTests {
    private func makeWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func makeOverlay() -> OverlayWindow {
        OverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600), level: .desktop)
    }

    /// Shipped hard-coded as `.none` until 2026-08-23, which excluded the
    /// wallpaper from every capture — including the user's own screenshots.
    @Test("Default policy leaves the wallpaper capturable")
    func defaultPolicyIsCapturable() {
        #expect(GlobalSettings().wallpaperVisibleInScreenCapture)
    }

    @Test("A window built while capture is allowed is readable by capture")
    func windowFollowsPolicyWhenAllowed() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        WallpaperCapturePolicy.allowsScreenCapture = true
        #expect(makeWindow().sharingType == .readOnly)
    }

    @Test("A window built while capture is denied is excluded from capture")
    func windowFollowsPolicyWhenDenied() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        WallpaperCapturePolicy.allowsScreenCapture = false
        #expect(makeWindow().sharingType == .none)
    }

    /// The Monitor board sits directly above the wallpaper; if the two disagree
    /// a screenshot shows widgets floating over the system desktop picture.
    @Test("The Monitor overlay tracks the wallpaper's capture policy in both directions")
    func overlayMatchesWallpaperCapturePolicy() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        for allowed in [true, false] {
            WallpaperCapturePolicy.allowsScreenCapture = allowed
            #expect(makeOverlay().sharingType == makeWindow().sharingType)
        }
    }
}

@Suite("Screen-capture setting persistence")
struct WallpaperCaptureSettingTests {
    /// Installs predating the key inherit the new default (visible), which is
    /// deliberately the opposite of the behaviour they shipped with.
    @Test("A settings blob without the key decodes as visible")
    func legacyBlobDecodesAsVisible() throws {
        let legacy = Data(#"{"showInDock":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacy)
        #expect(decoded.wallpaperVisibleInScreenCapture)
    }

    @Test("An explicit opt-out survives a round trip")
    func optOutRoundTrips() throws {
        var settings = GlobalSettings()
        settings.wallpaperVisibleInScreenCapture = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(!decoded.wallpaperVisibleInScreenCapture)
    }
}
