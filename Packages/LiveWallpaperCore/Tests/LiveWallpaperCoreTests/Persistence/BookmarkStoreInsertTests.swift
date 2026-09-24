import Foundation
import LiveWallpaperCore
import Testing

@MainActor
private final class RecordingBookmarkPersistence: BookmarkPersisting {
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
@Suite("Bookmark store insert")
struct BookmarkStoreInsertTests {
    @Test("An entry goes back at its index with every field it had, and the store persists")
    func insertKeepsEveryFieldAndPersists() {
        let persistence = RecordingBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let first = store.add(label: "First", content: .video(bookmarkData: Data([1])))
        let last = store.add(label: "Last", content: .video(bookmarkData: Data([3])))
        let removed = WallpaperBookmark(
            label: "Middle", content: .html(source: .inline("Page"), config: .default),
            createdAt: Date(timeIntervalSince1970: 100), sourceDisplayName: "Studio",
            playbackSettings: BookmarkPlaybackSettings(playbackSpeed: 1.5, muted: true),
            coverFileName: "middle.png", lastUsedAt: Date(timeIntervalSince1970: 200)
        )
        let saves = persistence.saveCount

        store.insert(removed, at: 1)

        #expect(store.bookmarks.map(\.id) == [first.id, removed.id, last.id])
        #expect(store.bookmarks.dropFirst().first == removed, "a field of the entry changed on the way back")
        #expect(persistence.saveCount == saves + 1)
        #expect(persistence.stored == store.bookmarks)
    }

    @Test("An index past the end puts the entry last; an ID already there is not added again")
    func pastTheEndGoesLastAndAnIDIsNeverDoubled() {
        let persistence = RecordingBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let kept = store.add(label: "Kept", content: .video(bookmarkData: Data([1])))
        let returning = WallpaperBookmark(label: "Returning", content: .video(bookmarkData: Data([2])))

        store.insert(returning, at: 9)
        #expect(store.bookmarks.map(\.id) == [kept.id, returning.id])

        let saves = persistence.saveCount
        store.insert(returning, at: 0)
        #expect(store.bookmarks.map(\.id) == [kept.id, returning.id])
        #expect(persistence.saveCount == saves)
    }
}
