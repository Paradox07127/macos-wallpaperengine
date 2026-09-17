import Foundation
@testable import LiveWallpaperCore
import Testing

// MARK: - Doubles

@MainActor
private final class MemoryBookmarkPersistence: BookmarkPersisting {
    var stored: [WallpaperBookmark] = []
    private(set) var saveCount = 0

    func load() -> [WallpaperBookmark] {
        stored
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        stored = bookmarks
        saveCount += 1
    }
}

@MainActor
private final class MemorySchemePersistence: SchemePersisting {
    var stored: [ScreenScheme] = []
    private(set) var saveCount = 0

    func load() -> [ScreenScheme] {
        stored
    }

    func save(_ schemes: [ScreenScheme]) {
        stored = schemes
        saveCount += 1
    }
}

private func configuration(screenID: UInt32 = 777) -> ScreenConfiguration {
    var config = ScreenConfiguration(
        screenID: screenID,
        wallpaper: .video(bookmarkData: Data([0x01, 0x02]))
    )
    config.displayFingerprint = "source-panel"
    config.playbackSpeed = 1.5
    return config
}

// MARK: - Schema

@Suite("Saved library covers")
struct SavedLibraryCoverTests {
    @Test("A scheme's cover file name survives the archive round trip")
    func schemeCoverRoundTrips() throws {
        let scheme = ScreenScheme(
            name: "Desk",
            configuration: configuration(),
            overlay: .default,
            coverFileName: "8D1F.png"
        )
        let data = try JSONEncoder().encode(scheme)
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: data)
        #expect(decoded.coverFileName == "8D1F.png")
    }

    @Test("A scheme archived before covers existed still decodes")
    func schemeWithoutCoverDecodes() throws {
        // The hand-written `init(from:)` is the only decode path, so a missing
        // key has to be tolerated there rather than by a synthesized decoder.
        let json = try """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "createdAt": 0,
          "updatedAt": 0,
          "configuration": \(String(data: JSONEncoder().encode(configuration()), encoding: .utf8)!),
          "overlay": \(String(data: JSONEncoder().encode(MonitorOverlayConfiguration.default), encoding: .utf8)!)
        }
        """
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: Data(json.utf8))
        #expect(decoded.coverFileName == nil)
        #expect(decoded.name == "Legacy")
    }

    @Test("A bookmark's cover file name survives the archive round trip")
    func bookmarkCoverRoundTrips() throws {
        let bookmark = WallpaperBookmark(
            label: "Rain",
            content: .video(bookmarkData: Data([0x09])),
            coverFileName: "AB12.png"
        )
        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(WallpaperBookmark.self, from: data)
        #expect(decoded.coverFileName == "AB12.png")
    }

    @Test("A bookmark archived before covers existed still decodes")
    func bookmarkWithoutCoverDecodes() {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "label": "Legacy",
          "createdAt": 0,
          "content": {"video": {"bookmarkData": "CQ=="}}
        }
        """
        let decoded = try? JSONDecoder().decode(WallpaperBookmark.self, from: Data(json.utf8))
        #expect(decoded?.coverFileName == nil)
    }

    // MARK: - Stores

    @MainActor
    @Test("Setting a cover persists and is idempotent")
    func setCoverPersistsOnce() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let bookmark = store.add(label: "Rain", content: .video(bookmarkData: Data([0x09])))
        let savesAfterAdd = persistence.saveCount

        store.setCover("cover.png", for: bookmark.id)
        #expect(store.bookmarks.first?.coverFileName == "cover.png")
        #expect(persistence.saveCount == savesAfterAdd + 1)

        // Re-setting the same name must not rewrite the archive: the capture
        // path can land twice for one entry.
        store.setCover("cover.png", for: bookmark.id)
        #expect(persistence.saveCount == savesAfterAdd + 1)
    }

    /// Covers are named by id, so a recapture lands under the same name; the tile keys its
    /// artwork on `updatedAt`, which therefore has to move.
    @MainActor
    @Test("Re-setting a scheme's cover under the same name still bumps updatedAt")
    func schemeRecaptureBumpsUpdatedAt() async throws {
        let store = SchemeStore(persistence: MemorySchemePersistence())
        let scheme = store.add(name: "Desk", configuration: configuration(), overlay: .default)
        store.setCover("cover.png", for: scheme.id)
        let first = try #require(store.schemes.first?.updatedAt)
        try await Task.sleep(for: .milliseconds(5))
        store.setCover("cover.png", for: scheme.id)
        let second = try #require(store.schemes.first?.updatedAt)
        #expect(second > first)
        #expect(store.schemes.first?.coverFileName == "cover.png")
    }

    /// Saved scene bookmarks carry their origin; the popover's "already bookmarked" lookup
    /// keys on content alone, or every Save would insert a duplicate.
    @MainActor
    @Test("A bookmark saved with an origin is still found by its content")
    func originDoesNotHideAnEquivalentBookmark() {
        let store = BookmarkStore(persistence: MemoryBookmarkPersistence())
        let content = WallpaperContent.video(bookmarkData: Data([0x0A]))
        let origin = WPEOrigin(
            workshopID: "1234", title: "Night", originalType: .video, sourceFolderBookmark: Data([1]),
            cacheRelativePath: nil, previewFileName: nil, entryFile: nil
        )
        let saved = store.add(label: "Night", content: content, wpeOrigin: origin)
        #expect(store.equivalentBookmark(content: content)?.id == saved.id)
    }

    @MainActor
    @Test("A cover set for an entry that is gone changes nothing")
    func setCoverIgnoresMissingEntry() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let savesAtStart = persistence.saveCount
        store.setCover("cover.png", for: UUID())
        #expect(persistence.saveCount == savesAtStart)
    }

    /// The cover stays named until the recapture lands: an unnamed PNG is an orphan to the
    /// sweep, and a recapture that yields no frame would leave the scheme blank for good.
    @MainActor
    @Test("Replacing a scheme keeps its identity, re-strips the display, and keeps its cover")
    func replaceKeepsIdentityAndKeepsCover() throws {
        let persistence = MemorySchemePersistence()
        let store = SchemeStore(persistence: persistence)
        let original = store.add(
            name: "Desk",
            configuration: configuration(),
            overlay: .default,
            sourceDisplayName: "Studio"
        )
        store.setCover("old.png", for: original.id)

        let replaced = try #require(
            store.replace(
                original.id,
                configuration: configuration(screenID: 999),
                overlay: .default,
                sourceDisplayName: "Desk Panel"
            )
        )

        #expect(replaced.id == original.id)
        #expect(replaced.name == original.name)
        #expect(replaced.createdAt == original.createdAt)
        #expect(replaced.updatedAt >= original.updatedAt)
        #expect(replaced.sourceDisplayName == "Desk Panel")
        #expect(replaced.configuration.screenID == ScreenScheme.unboundScreenID)
        #expect(replaced.configuration.displayFingerprint == nil)
        #expect(replaced.configuration.playbackSpeed == 1.5)
        #expect(replaced.coverFileName == "old.png")
        #expect(store.schemes.count == 1)
    }

    @MainActor
    @Test("Replacing an id that is not in the archive writes nothing")
    func replaceMissingSchemeIsANoOp() {
        let persistence = MemorySchemePersistence()
        let store = SchemeStore(persistence: persistence)
        let savesAtStart = persistence.saveCount
        #expect(store.replace(UUID(), configuration: configuration(), overlay: .default) == nil)
        #expect(persistence.saveCount == savesAtStart)
    }
}
