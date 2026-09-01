import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// A bookmark is a favourite wallpaper, nothing more: applying one swaps the
/// content and leaves every setting on the target display alone. The
/// whole-screen counterpart is `ScreenScheme`.
///
/// This suite used to assert the opposite — that a bookmark captured playback
/// settings plus the overlay's enabled/level state. That contract was reversed
/// on 2026-08-31 (`.notes/plan/screen-schemes.md`), so the old assertions were
/// replaced rather than left passing against behaviour the app no longer has.
/// `playbackSettings` itself stays on `WallpaperBookmark`, written by nothing
/// and read by nothing, so existing archives are not rewritten (plan D1 = A).
@Suite("Bookmarks carry content only")
@MainActor
struct BookmarkContentOnlyTests {
    @Test("Saving a bookmark records no playback settings")
    func addStoresNoPlaybackSettings() {
        let store = BookmarkStore(persistence: InMemoryBookmarkPersistence())
        let bookmark = store.add(
            label: "Aurora",
            content: .video(bookmarkData: Data([0x01]), packageEntryName: nil)
        )
        #expect(bookmark.playbackSettings == nil)
    }

    /// D1 = A: the field is kept so older archives are not rewritten. If it is
    /// ever dropped from the schema, this stops compiling — which is the point.
    @Test("A legacy bookmark's settings survive a decode untouched")
    func legacySettingsStillRoundTrip() throws {
        let legacy = WallpaperBookmark(
            label: "Old",
            content: .video(bookmarkData: Data([0x01]), packageEntryName: nil),
            playbackSettings: BookmarkPlaybackSettings(playbackSpeed: 1.5, muted: true)
        )
        let restored = try JSONDecoder().decode(
            WallpaperBookmark.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(restored.playbackSettings?.playbackSpeed == 1.5)
        #expect(restored.playbackSettings?.muted == true)
    }

    /// Provenance is not a setting: a scene bookmark still has to know where it
    /// came from, or applying it cannot restore the source-folder grant.
    @Test("Workshop provenance is still carried")
    func provenanceSurvivesTheSlimming() {
        let store = BookmarkStore(persistence: InMemoryBookmarkPersistence())
        let origin = WPEOrigin(
            workshopID: "12345",
            title: "Scene",
            originalType: .scene,
            sourceFolderBookmark: Data([0xAA]),
            cacheRelativePath: nil,
            previewFileName: nil
        )
        let bookmark = store.add(
            label: "Scene",
            content: .video(bookmarkData: Data([0x02]), packageEntryName: nil),
            wpeOrigin: origin
        )
        #expect(bookmark.wpeOrigin?.workshopID == "12345")
    }

    /// The one that actually exercises the split. The store-level tests above
    /// would still pass with the old `applyPlaybackSettings` call restored —
    /// this drives the real apply path and watches the target's settings.
    @Test("Applying a bookmark leaves the target display's settings alone")
    func applyingABookmarkDoesNotTouchSettings() throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        ))

        var configuration = ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .video(bookmarkData: Data([0x01]))
        )
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.videoVolume = 0.42
        configuration.fitMode = .aspectFill
        configuration.playbackSpeed = 1.75
        manager.saveConfiguration(configuration)

        // Unresolvable content on purpose: the apply bails before swapping the
        // wallpaper, so anything this test then sees changed came from the
        // settings path — the one that is supposed to be gone.
        let bookmark = WallpaperBookmark(
            label: "Other",
            content: .video(bookmarkData: Data([0x02]), packageEntryName: nil),
            playbackSettings: BookmarkPlaybackSettings(
                playbackSpeed: 0.25,
                fitMode: .aspectFit,
                videoVolume: 0.99
            )
        )
        manager.applyBookmark(bookmark, to: screen)

        let after = try #require(manager.getConfiguration(for: screen))
        #expect(after.videoVolume == 0.42)
        #expect(after.fitMode == .aspectFill)
        #expect(after.playbackSpeed == 1.75)
    }
}

@MainActor
private final class InMemoryBookmarkPersistence: BookmarkPersisting {
    private var stored: [WallpaperBookmark] = []
    func load() -> [WallpaperBookmark] {
        stored
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        stored = bookmarks
    }
}
