import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Library bookmark storage error toast")
struct LibraryBookmarkStorageErrorToastTests {
    private static func unreadableStore(_ name: String) throws -> (LibraryBookmarkStore, TestScratch.DefaultsSuite) {
        let suite = try TestScratch.defaultsSuite("library.bookmarks.toast.\(name)")
        suite.defaults.set(Data("not json".utf8), forKey: LibraryBookmarkStore.preferencesKey)
        return (LibraryBookmarkStore(defaults: suite.defaults), suite)
    }

    @Test("An unreadable archive raises a failure toast whose Reset discards it")
    func unreadableArchiveOffersReset() throws {
        let (store, suite) = try Self.unreadableStore("reset")
        defer { suite.discard() }
        #expect(store.hasStorageError, "control: the fixture did not make the archive unreadable")
        let center = EditDeskToastCenter()

        let shown = try #require(LibraryBookmarkStorageErrorToast.sync(store, shown: nil, in: center), "no toast for the storage error")
        let toast = try #require(center.toasts.first { $0.id == shown })
        #expect(toast.style == .failure)
        #expect(toast.lifetime == nil, "the error toast expires on its own")
        #expect(toast.action?.title == String(localized: "Reset", bundle: .appLanguage))
        #expect(LibraryBookmarkStorageErrorToast.sync(store, shown: shown, in: center) == shown, "a second sync posted a second toast")
        #expect(center.toasts.count == 1)

        center.performAction(shown)
        #expect(!store.hasStorageError)
        #expect(!store.isArchiveUnreadable)
        #expect(suite.defaults.object(forKey: LibraryBookmarkStore.preferencesKey) == nil, "Reset left the archive in place")
        #expect(center.toasts.isEmpty)
        #expect(LibraryBookmarkStorageErrorToast.sync(store, shown: shown, in: center) == nil)
    }

    @Test("Closing the toast acknowledges the error without discarding the archive")
    func closingAcknowledges() throws {
        let (store, suite) = try Self.unreadableStore("close")
        defer { suite.discard() }
        let center = EditDeskToastCenter()
        let shown = try #require(LibraryBookmarkStorageErrorToast.sync(store, shown: nil, in: center))

        center.dismiss(shown)
        #expect(LibraryBookmarkStorageErrorToast.sync(store, shown: shown, in: center) == nil)
        #expect(!store.hasStorageError)
        #expect(store.isArchiveUnreadable)
        #expect(suite.defaults.object(forKey: LibraryBookmarkStore.preferencesKey) != nil)
        #expect(center.toasts.isEmpty)
    }

    @Test("A readable store raises nothing")
    func noErrorNoToast() throws {
        let suite = try TestScratch.defaultsSuite("library.bookmarks.toast.clean")
        defer { suite.discard() }
        let center = EditDeskToastCenter()
        #expect(LibraryBookmarkStorageErrorToast.sync(LibraryBookmarkStore(defaults: suite.defaults), shown: nil, in: center) == nil)
        #expect(center.toasts.isEmpty)
    }

    @Test("Both SKUs' Edit Desk windows sync the toast when the store's error or the toasts change")
    func rootWiring() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        let lines = root.components(separatedBy: "\n")
        for wiring in [
            ".onChange(of: LibraryBookmarkStore.shared.hasStorageError, initial: true) { syncLibraryBookmarkErrorToast() }",
            ".onChange(of: toasts.toasts.map(\\.id)) { syncLibraryBookmarkErrorToast() }",
            "LibraryBookmarkStorageErrorToast.sync(.shared, shown: libraryBookmarkErrorToast, in: toasts)",
            "@State private var libraryBookmarkErrorToast: EditDeskToastCenter.Toast.ID?",
        ] {
            let index = try #require(lines.firstIndex { $0.contains(wiring) }, "missing: \(wiring)")
            let directive = lines[..<index].last { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("#if") || trimmed.hasPrefix("#else") || trimmed.hasPrefix("#endif")
            }
            #expect(
                directive.map { $0.trimmingCharacters(in: .whitespaces) == "#endif" } ?? true,
                "the Lite build drops this line: \(wiring)"
            )
        }
    }
}
