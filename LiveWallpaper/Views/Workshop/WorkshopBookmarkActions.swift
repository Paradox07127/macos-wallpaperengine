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
        let bookmarks = workshopStore.bookmarks
        guard !bookmarks.isEmpty else { return [] }
        let browseByID = Dictionary(browseItems.lazy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Backup import appends old likes at the end, so store order is not like order.
        return bookmarks.reversed().sorted { $0.createdAt > $1.createdAt }.map { bookmark in
            let saved = queryItem(bookmark)
            return browseByID[bookmark.id]?.preservingDetails(from: saved) ?? saved
        }
    }

    /// Known metadata survives offline reopening; legacy references remain usable.
    static func queryItem(_ bookmark: WorkshopBookmark) -> WorkshopQueryItem {
        if let item = bookmark.queryItemSnapshot {
            return item
        }
        return WorkshopQueryItem(
            id: bookmark.id, rawTitle: bookmark.rawTitle, shortDescription: "", creatorID: nil,
            previewImageURL: bookmark.previewImageURL, fileSizeBytes: nil, timeUpdated: nil,
            subscriptionCount: nil, rating: nil, tags: bookmark.tags, visibility: .unknown,
            isBanned: false, steamCommunityURL: WorkshopCommunityURL.item(itemID: bookmark.id)
        )
    }

    /// Preserve a richer successful read without changing bookmark identity/order.
    static func refreshDetails(_ item: WorkshopQueryItem, in store: WorkshopBookmarkStore = .shared) {
        guard let saved = store.bookmarks.first(where: { $0.id == item.id }),
              let snapshot = item.preservingDetails(from: saved.queryItemSnapshot).bookmarkDetailsSnapshot else { return }
        store.updateDetailsSnapshot(snapshot, for: item.id)
    }
}
#endif
