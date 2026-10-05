#if !LITE_BUILD
import LiveWallpaperCore

/// A Workshop item's records outside the library history: its saved scene bookmarks and variants, and their library marks.
@MainActor
enum WorkshopSavedRecords {
    static func contains(
        workshopID: String, bookmarks: BookmarkStore = .shared, libraryBookmarks: LibraryBookmarkStore = .shared
    ) -> Bool {
        bookmarks.containsWPEBookmark(workshopID: workshopID) || libraryBookmarks.contains("workshop:\(workshopID)")
    }

    static func remove(
        workshopID: String, bookmarks: BookmarkStore = .shared, libraryBookmarks: LibraryBookmarkStore = .shared
    ) {
        // removeWPEBookmarks also drops the item's saved variants; their marks go with them.
        let before = Set(bookmarks.bookmarks.map(\.id))
        bookmarks.removeWPEBookmarks(workshopID: workshopID)
        for id in before.subtracting(Set(bookmarks.bookmarks.map(\.id))) {
            libraryBookmarks.remove("bookmark:\(id)")
        }
        libraryBookmarks.remove("workshop:\(workshopID)")
    }

    /// `removeImport`, then the entry's saved records once it removed the history entry.
    static func removingImport(
        bookmarks: BookmarkStore = .shared, libraryBookmarks: LibraryBookmarkStore = .shared,
        _ removeImport: @escaping @MainActor (WPEHistoryEntry) -> Bool
    ) -> @MainActor (WPEHistoryEntry) -> Bool {
        { entry in
            guard removeImport(entry) else { return false }
            remove(workshopID: entry.origin.workshopID, bookmarks: bookmarks, libraryBookmarks: libraryBookmarks)
            return true
        }
    }
}
#endif
