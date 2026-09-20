#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WorkshopBookmarkStore {
    static let shared = WorkshopBookmarkStore(defaults: .appScoped())
}

@MainActor
enum WorkshopBookmarkActions {
    static func contains(_ id: UInt64) -> Bool {
        contains(workshopID: String(id))
    }

    static func contains(workshopID: String) -> Bool {
        if let id = UInt64(workshopID), WorkshopBookmarkStore.shared.contains(id) {
            return true
        }
        return BookmarkStore.shared.containsWPEBookmark(workshopID: workshopID)
    }

    static func toggle(_ item: WorkshopQueryItem) {
        let store = WorkshopBookmarkStore.shared
        if contains(item.id) {
            if store.contains(item.id) {
                store.remove(item.id)
                guard !store.hasStorageError else { return }
            }
            BookmarkStore.shared.removeWPEBookmarks(workshopID: String(item.id))
        } else if !item.isBanned {
            store.add(WorkshopBookmark(
                id: item.id, title: item.title,
                previewImageURL: item.previewImageURL, tags: item.tags
            ))
        }
    }
}

struct WorkshopBookmarkErrorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.alert("Action needed", isPresented: Binding(
            get: { WorkshopBookmarkStore.shared.hasStorageError },
            set: {
                if !$0 {
                    WorkshopBookmarkStore.shared.dismissStorageError()
                }
            }
        )) {
            Button("OK") { WorkshopBookmarkStore.shared.dismissStorageError() }
        } message: {
            Text("Couldn't save Workshop bookmarks. Your existing bookmarks have been kept.")
        }
    }
}
#endif
