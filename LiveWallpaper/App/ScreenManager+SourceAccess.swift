import Foundation
import LiveWallpaperCore

extension ScreenManager {
    func persistRuntimeHTMLBookmarkRefresh(
        matching original: Data,
        with refreshed: Data,
        bookmarkID: UUID? = nil,
        ownerOrigin: WPEOrigin? = nil
    ) {
        guard !isTerminating else { return }
        var wpeWorkshopIDs: Set<String> = []
        if let ownerOrigin,
           ownerOrigin.sourceFolderBookmark == original {
            wpeWorkshopIDs.insert(ownerOrigin.workshopID)
        }
        for configuration in configurationStore.loadAll() {
            if let origin = configuration.wpeOrigin,
               origin.sourceFolderBookmark == original,
               let updated = configuration.replacingWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
               ) {
                saveConfiguration(updated)
                wpeWorkshopIDs.insert(origin.workshopID)
            } else if let updated = configuration.replacingHTMLBookmark(
                matching: original,
                with: refreshed
            ) {
                saveConfiguration(updated)
            }
        }
        if let bookmarkID {
            _ = BookmarkStore.shared.replaceHTMLBookmark(
                id: bookmarkID,
                matching: original,
                with: refreshed
            )
        }
        _ = BookmarkStore.shared.replaceMatchingHTMLBookmarks(
            matching: original,
            with: refreshed
        )
        SchemeStore.shared.replaceHTMLBookmark(matching: original, with: refreshed)
        for workshopID in wpeWorkshopIDs {
            _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
            _ = BookmarkStore.shared.replaceWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
            SchemeStore.shared.replaceWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
        }
    }

    func persistRuntimeWPEBookmarkRefresh(
        origin: WPEOrigin,
        with refreshed: Data
    ) {
        guard !isTerminating else { return }
        let original = origin.sourceFolderBookmark
        for configuration in configurationStore.loadAll() {
            guard let updated = configuration.replacingWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
            ) else { continue }
            saveConfiguration(updated)
        }
        _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
        _ = BookmarkStore.shared.replaceWPEOriginBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
        SchemeStore.shared.replaceWPEOriginBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
    }
}
