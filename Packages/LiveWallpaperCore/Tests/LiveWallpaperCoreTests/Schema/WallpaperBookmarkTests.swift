import Foundation
import LiveWallpaperCore
import Testing

@Suite("WallpaperBookmark last used date")
struct WallpaperBookmarkTests {
    @Test("Legacy JSON without lastUsedAt decodes with nil")
    func legacyJSONDecodesWithoutLastUsedAt() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789ABC",
            "label": "Saved video",
            "createdAt": 1000,
            "content": {"video": {"bookmarkData": "AQID"}},
            "sourceDisplayName": "video.mov"
        }
        """
        let bookmark = try JSONDecoder().decode(WallpaperBookmark.self, from: Data(json.utf8))

        #expect(bookmark.lastUsedAt == nil)
        #expect(bookmark.content == .video(bookmarkData: Data([0x01, 0x02, 0x03])))
    }

    @Test("lastUsedAt defaults to nil and round-trips when supplied")
    func lastUsedAtRoundTrips() throws {
        let content = WallpaperContent.video(bookmarkData: Data([0x01]))
        #expect(WallpaperBookmark(label: "Unused", content: content).lastUsedAt == nil)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let bookmark = WallpaperBookmark(label: "Used", content: content, lastUsedAt: date)

        let decoded = try JSONDecoder().decode(
            WallpaperBookmark.self,
            from: JSONEncoder().encode(bookmark)
        )

        #expect(decoded.lastUsedAt == date)
        #expect(decoded == bookmark)
    }
}

@Suite("BookmarkStore last used date")
@MainActor
struct BookmarkStoreLastUsedTests {
    @Test("touch updates only the matching bookmark and persists once")
    func touchSetsDateAndPersistsOnce() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let bookmark = store.add(label: "Used", content: .video(bookmarkData: Data([0x01])))
        let other = store.add(label: "Unused", content: .video(bookmarkData: Data([0x02])))
        let saveCountBefore = persistence.saveCount
        let date = Date(timeIntervalSince1970: 1_750_000_000)

        store.touch(bookmark.id, at: date)

        var expected = bookmark
        expected.lastUsedAt = date
        #expect(store.bookmarks == [expected, other])
        #expect(persistence.stored == [expected, other])
        #expect(persistence.saveCount == saveCountBefore + 1)
    }

    @Test("touch with an unknown id changes nothing and does not persist")
    func touchUnknownIDDoesNotPersist() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let bookmark = store.add(label: "Unused", content: .video(bookmarkData: Data([0x01])))
        let saveCountBefore = persistence.saveCount

        store.touch(UUID())

        #expect(store.bookmarks == [bookmark])
        #expect(persistence.stored == [bookmark])
        #expect(persistence.saveCount == saveCountBefore)
    }
}

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
