#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WorkshopBookmarkStore {
    static let shared = WorkshopBookmarkStore(defaults: .appScoped())
}

/// Workshop likes live in `WorkshopBookmarkStore` alone; the wallpaper library's bookmarks never count as one.
@MainActor
enum WorkshopBookmarkActions {
    /// Liked ids, computed once for a pane to test each card against.
    static func bookmarkedIDs(workshopStore: WorkshopBookmarkStore = .shared) -> Set<UInt64> {
        Set(workshopStore.bookmarks.map(\.id))
    }

    static func contains(_ id: UInt64, workshopStore: WorkshopBookmarkStore = .shared) -> Bool {
        workshopStore.contains(id)
    }

    static func toggle(_ item: WorkshopQueryItem, workshopStore: WorkshopBookmarkStore = .shared) {
        if workshopStore.contains(item.id) {
            workshopStore.remove(item.id)
        } else if !item.isBanned {
            workshopStore.add(WorkshopBookmark(
                id: item.id, rawTitle: item.rawTitle,
                previewImageURL: item.previewImageURL, tags: item.tags,
                detailsSnapshot: item.bookmarkDetailsSnapshot
            ))
        }
    }

    /// Newest like first; an item on the loaded browse page outranks its saved snapshot.
    static func likedItems(
        browseItems: [WorkshopQueryItem], workshopStore: WorkshopBookmarkStore = .shared
    ) -> [WorkshopQueryItem] {
        workshopStore.bookmarks.reversed().map { bookmark in
            let saved = SavedBookmarks.queryItem(bookmark)
            return browseItems.first { $0.id == bookmark.id }?.preservingDetails(from: saved) ?? saved
        }
    }

    /// Preserve a richer successful read without changing bookmark identity/order.
    static func refreshDetails(_ item: WorkshopQueryItem, in store: WorkshopBookmarkStore = .shared) {
        guard let saved = store.bookmarks.first(where: { $0.id == item.id }),
              let snapshot = item.preservingDetails(from: saved.queryItemSnapshot).bookmarkDetailsSnapshot else { return }
        store.updateDetailsSnapshot(snapshot, for: item.id)
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
