#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Workshop bookmark storage error toast")
struct BookmarkStorageErrorToastTests {
    private static func unreadableStore(_ name: String) throws -> (WorkshopBookmarkStore, TestScratch.DefaultsSuite) {
        let suite = try TestScratch.defaultsSuite("workshop.bookmarks.toast.\(name)")
        suite.defaults.set(Data("not json".utf8), forKey: WorkshopBookmarkStore.preferencesKey)
        return (WorkshopBookmarkStore(defaults: suite.defaults), suite)
    }

    @Test("An unreadable archive raises a failure toast whose Reset discards it")
    func unreadableArchiveOffersReset() throws {
        let (store, suite) = try Self.unreadableStore("reset")
        defer { suite.discard() }
        #expect(store.hasStorageError, "control: the fixture did not make the archive unreadable")
        let center = EditDeskToastCenter()

        let shown = try #require(BookmarkStorageErrorToast.sync(store, shown: nil, in: center), "no toast for the storage error")
        let toast = try #require(center.toasts.first { $0.id == shown })
        #expect(toast.style == .failure)
        #expect(toast.lifetime == nil, "the error toast expires on its own")
        #expect(toast.action?.title == String(localized: "Reset", bundle: .appLanguage))
        #expect(BookmarkStorageErrorToast.sync(store, shown: shown, in: center) == shown, "a second sync posted a second toast")
        #expect(center.toasts.count == 1)

        center.performAction(shown)
        #expect(!store.hasStorageError)
        #expect(!store.isArchiveUnreadable)
        #expect(suite.defaults.object(forKey: WorkshopBookmarkStore.preferencesKey) == nil, "Reset left the archive in place")
        #expect(center.toasts.isEmpty)
        #expect(BookmarkStorageErrorToast.sync(store, shown: shown, in: center) == nil)
    }

    @Test("Closing the toast acknowledges the error without discarding the archive")
    func closingAcknowledges() throws {
        let (store, suite) = try Self.unreadableStore("close")
        defer { suite.discard() }
        let center = EditDeskToastCenter()
        let shown = try #require(BookmarkStorageErrorToast.sync(store, shown: nil, in: center))

        center.dismiss(shown)
        #expect(BookmarkStorageErrorToast.sync(store, shown: shown, in: center) == nil)
        #expect(!store.hasStorageError)
        #expect(store.isArchiveUnreadable)
        #expect(suite.defaults.object(forKey: WorkshopBookmarkStore.preferencesKey) != nil)
        #expect(center.toasts.isEmpty)
    }

    @Test("A readable store raises nothing")
    func noErrorNoToast() throws {
        let suite = try TestScratch.defaultsSuite("workshop.bookmarks.toast.clean")
        defer { suite.discard() }
        let center = EditDeskToastCenter()
        #expect(BookmarkStorageErrorToast.sync(WorkshopBookmarkStore(defaults: suite.defaults), shown: nil, in: center) == nil)
        #expect(center.toasts.isEmpty)
    }

    @Test("The Edit Desk window syncs the toast when the store's error or the toasts change")
    func rootWiring() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        #expect(root.contains(".onChange(of: WorkshopBookmarkStore.shared.hasStorageError, initial: true) { syncBookmarkErrorToast() }"))
        #expect(root.contains(".onChange(of: toasts.toasts.map(\\.id)) { syncBookmarkErrorToast() }"))
        #expect(root.contains("BookmarkStorageErrorToast.sync(.shared, shown: bookmarkErrorToast, in: toasts)"))
    }
}
#endif
