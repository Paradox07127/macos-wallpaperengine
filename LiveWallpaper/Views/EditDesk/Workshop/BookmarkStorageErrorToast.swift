#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

@MainActor
enum BookmarkStorageErrorToast {
    /// Keeps one failure toast up while `store` reports a storage error, and returns the toast now showing.
    /// Closing the toast acknowledges the error, so the next failed save raises a new one.
    static func sync(
        _ store: WorkshopBookmarkStore, shown: EditDeskToastCenter.Toast.ID?, in center: EditDeskToastCenter
    ) -> EditDeskToastCenter.Toast.ID? {
        let isShowing = center.toasts.contains { $0.id == shown }
        if shown != nil, !isShowing, store.hasStorageError {
            store.dismissStorageError()
            return nil
        }
        guard store.hasStorageError else {
            if let shown {
                center.dismiss(shown)
            }
            return nil
        }
        if isShowing {
            return shown
        }
        guard store.isArchiveUnreadable else {
            return center.post(
                String(localized: "Couldn't save Workshop bookmarks. Your existing bookmarks have been kept.", bundle: .appLanguage),
                style: .failure
            )
        }
        return center.post(
            String(
                localized: "Couldn't read Workshop bookmarks. Reset discards them so new bookmarks can be saved.",
                bundle: .appLanguage,
                comment: "Workshop bookmark alert when the saved bookmarks can't be decoded; the Reset button discards them."
            ),
            style: .failure,
            action: EditDeskToastCenter.Toast.Action(
                title: String(localized: "Reset", bundle: .appLanguage),
                perform: { store.resetUnreadableArchive() }
            )
        )
    }
}
#endif
