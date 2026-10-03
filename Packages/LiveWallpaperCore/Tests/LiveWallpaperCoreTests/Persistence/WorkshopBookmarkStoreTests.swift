import Foundation
@testable import LiveWallpaperCore
import Testing

@MainActor
struct WorkshopBookmarkStoreTests {
    @Test func savesUndownloadedWallpaperAcrossRelaunch() throws {
        let suite = "WorkshopBookmarkStoreTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        let bookmark = WorkshopBookmark(
            id: 123, rawTitle: "Rain", previewImageURL: nil, tags: ["Scene"],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        store.add(bookmark)
        store.add(WorkshopBookmark(id: 123, rawTitle: "Renamed", previewImageURL: nil, tags: []))

        let reopened = WorkshopBookmarkStore(defaults: defaults)
        #expect(reopened.bookmarks == [bookmark])
        #expect(reopened.contains(123))
        reopened.remove(123)
        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.isEmpty)
    }

    @Test func removalPreservesOtherSavedWallpapers() throws {
        let suite = "WorkshopBookmarkStoreTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        store.add(WorkshopBookmark(id: 1, rawTitle: "One", previewImageURL: nil, tags: []))
        store.add(WorkshopBookmark(id: 2, rawTitle: "Two", previewImageURL: nil, tags: []))
        store.remove(1)
        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.map(\.id) == [2])
    }

    @Test func unreadableArchiveIsNotOverwritten() throws {
        let suite = "WorkshopBookmarkStoreTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid archive".utf8)
        defaults.set(original, forKey: WorkshopBookmarkStore.preferencesKey)
        let store = WorkshopBookmarkStore(defaults: defaults)
        #expect(store.hasStorageError)
        store.dismissStorageError()
        store.add(WorkshopBookmark(id: 1, rawTitle: "One", previewImageURL: nil, tags: []))
        #expect(store.hasStorageError)
        #expect(store.bookmarks.isEmpty)
        #expect(defaults.data(forKey: WorkshopBookmarkStore.preferencesKey) == original)

        defaults.removeObject(forKey: WorkshopBookmarkStore.preferencesKey)
        store.resetAfterSettingsCleared()
        store.add(WorkshopBookmark(id: 1, rawTitle: "One", previewImageURL: nil, tags: []))
        #expect(!store.hasStorageError)
        #expect(WorkshopBookmarkStore(defaults: defaults).contains(1))
    }

    @Test func nonDataValueIsUnreadableNotAbsent() throws {
        let suite = "WorkshopBookmarkStoreTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not an archive", forKey: WorkshopBookmarkStore.preferencesKey)

        let store = WorkshopBookmarkStore(defaults: defaults)
        #expect(store.isArchiveUnreadable)
        store.add(WorkshopBookmark(id: 1, rawTitle: "One", previewImageURL: nil, tags: []))

        #expect(defaults.string(forKey: WorkshopBookmarkStore.preferencesKey) == "not an archive")
    }

    @Test func resettingAnUnreadableArchiveClearsOnlyItsKey() throws {
        let suite = "WorkshopBookmarkStoreTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid archive".utf8), forKey: WorkshopBookmarkStore.preferencesKey)
        defaults.set(true, forKey: "neighbour")
        let store = WorkshopBookmarkStore(defaults: defaults)
        try #require(store.hasStorageError)

        store.resetUnreadableArchive()
        store.add(WorkshopBookmark(id: 1, rawTitle: "One", previewImageURL: nil, tags: []))

        #expect(!store.hasStorageError)
        #expect(WorkshopBookmarkStore(defaults: defaults).contains(1))
        #expect(defaults.bool(forKey: "neighbour"))
    }
}
