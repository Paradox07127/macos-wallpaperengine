import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// A bookmark carries content only: applying one swaps the wallpaper and leaves every
/// setting on the target display alone. The whole-screen counterpart is `ScreenScheme`.
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

    /// The field is kept so older archives are not rewritten; dropping it from the schema
    /// would stop this compiling, which is the point.
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

    /// The store-level tests above would still pass with the old `applyPlaybackSettings`
    /// call restored; only this one drives the real apply path.
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

        // Unresolvable content on purpose: the apply bails before the swap, so anything this
        // test sees changed came from the settings path.
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
