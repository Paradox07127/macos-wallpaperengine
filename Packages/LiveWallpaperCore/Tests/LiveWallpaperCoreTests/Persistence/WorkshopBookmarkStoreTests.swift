import Foundation
@testable import LiveWallpaperCore
import Testing

@MainActor
struct WorkshopBookmarkStoreTests {
    @Test func savesUndownloadedWallpaperAcrossRelaunch() throws {
        let suite = "WorkshopBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        let bookmark = WorkshopBookmark(
            id: 123, title: "Rain", previewImageURL: nil, tags: ["Scene"],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        store.add(bookmark)
        store.add(WorkshopBookmark(id: 123, title: "Renamed", previewImageURL: nil, tags: []))

        let reopened = WorkshopBookmarkStore(defaults: defaults)
        #expect(reopened.bookmarks == [bookmark])
        #expect(reopened.contains(123))
        reopened.remove(123)
        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.isEmpty)
    }

    @Test func removalPreservesOtherSavedWallpapers() throws {
        let suite = "WorkshopBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        store.add(WorkshopBookmark(id: 1, title: "One", previewImageURL: nil, tags: []))
        store.add(WorkshopBookmark(id: 2, title: "Two", previewImageURL: nil, tags: []))
        store.remove(1)
        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.map(\.id) == [2])
    }

    @Test func unreadableArchiveIsNotOverwritten() throws {
        let suite = "WorkshopBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid archive".utf8)
        defaults.set(original, forKey: WorkshopBookmarkStore.preferencesKey)
        let store = WorkshopBookmarkStore(defaults: defaults)
        #expect(store.hasStorageError)
        store.dismissStorageError()
        store.add(WorkshopBookmark(id: 1, title: "One", previewImageURL: nil, tags: []))
        #expect(store.hasStorageError)
        #expect(store.bookmarks.isEmpty)
        #expect(defaults.data(forKey: WorkshopBookmarkStore.preferencesKey) == original)

        defaults.removeObject(forKey: WorkshopBookmarkStore.preferencesKey)
        store.resetAfterSettingsCleared()
        store.add(WorkshopBookmark(id: 1, title: "One", previewImageURL: nil, tags: []))
        #expect(!store.hasStorageError)
        #expect(WorkshopBookmarkStore(defaults: defaults).contains(1))
    }
}
