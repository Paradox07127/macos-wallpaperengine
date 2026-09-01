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
