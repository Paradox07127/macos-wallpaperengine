#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WorkshopBookmarkStore {
    static let shared = WorkshopBookmarkStore(defaults: .appScoped())
}

@MainActor
enum WorkshopBookmarkActions {
    /// Workshop ids saved in either store, computed once for a pane to test each card against.
    static func bookmarkedIDs(
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) -> Set<UInt64> {
        var ids = Set(workshopStore.bookmarks.map(\.id))
        for bookmark in store.bookmarks {
            for workshopID in [bookmark.wpeOrigin?.workshopID, bookmark.content.sceneDescriptor?.workshopID] {
                if let id = workshopID.flatMap(UInt64.init) {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    static func contains(
        _ id: UInt64,
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) -> Bool {
        contains(workshopID: String(id), store: store, workshopStore: workshopStore)
    }

    static func contains(
        workshopID: String,
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) -> Bool {
        if let id = UInt64(workshopID), workshopStore.contains(id) {
            return true
        }
        return store.containsWPEBookmark(workshopID: workshopID)
    }

    static func toggle(
        _ item: WorkshopQueryItem,
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) {
        if contains(item.id, store: store, workshopStore: workshopStore) {
            if workshopStore.contains(item.id) {
                workshopStore.remove(item.id)
                guard !workshopStore.hasStorageError else { return }
            }
            store.removeWPEBookmarks(workshopID: String(item.id))
        } else if !item.isBanned {
            workshopStore.add(WorkshopBookmark(
                id: item.id, rawTitle: item.rawTitle,
                previewImageURL: item.previewImageURL, tags: item.tags,
                detailsSnapshot: item.bookmarkDetailsSnapshot
            ))
        }
    }

    /// Preserve a richer successful read without changing bookmark identity/order.
    static func refreshDetails(_ item: WorkshopQueryItem, in store: WorkshopBookmarkStore = .shared) {
        guard let saved = store.bookmarks.first(where: { $0.id == item.id }),
              let snapshot = item.preservingDetails(from: saved.queryItemSnapshot).bookmarkDetailsSnapshot else { return }
        store.updateDetailsSnapshot(snapshot, for: item.id)
    }

    /// Clears a Workshop id from both stores.
    static func removeAll(
        workshopID: String,
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) {
        if let id = UInt64(workshopID), workshopStore.contains(id) {
            workshopStore.remove(id)
        }
        store.removeWPEBookmarks(workshopID: workshopID)
    }

    /// A confirmed delete: the local bookmark always goes; a failed Workshop write surfaces through `hasStorageError`.
    static func remove(
        _ bookmark: WallpaperBookmark,
        store: BookmarkStore = .shared,
        workshopStore: WorkshopBookmarkStore = .shared
    ) {
        store.remove(bookmark.id)
        if let workshopID = bookmark.wpeOrigin?.workshopID ?? bookmark.content.sceneDescriptor?.workshopID,
           let id = UInt64(workshopID), workshopStore.contains(id) {
            workshopStore.remove(id)
        }
    }
}
#endif
