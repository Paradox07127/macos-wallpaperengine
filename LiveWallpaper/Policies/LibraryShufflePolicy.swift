import Foundation
import LiveWallpaperCore

@MainActor
enum LibraryShufflePolicy {
    /// Reads the backing stores without depending on an open library window or its filters.
    static func liveEntries() -> [WallpaperQueueEntry] {
        let bookmarks = BookmarkStore.shared.bookmarks
        var entries: [WallpaperQueueEntry] = []
        #if !LITE_BUILD
        let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
        let installed = Set(history.map(\.id))
        let resolver = WPECachedContentResolver()
        entries = history.compactMap { item in
            guard item.origin.originalType != .application, item.origin.originalType != .unknown,
                  let content = resolver.content(for: item.origin) else { return nil }
            return WallpaperQueueEntry(id: "workshop:\(item.id)", title: item.origin.title, content: content, origin: item.origin)
        }
        #endif
        entries += bookmarks.compactMap { bookmark in
            #if !LITE_BUILD
            if let id = bookmark.wpeOrigin?.workshopID, installed.contains(id),
               SavedLibraryModel.foldsIntoWorkshopRow(bookmark.content) {
                return nil
            }
            #endif
            return WallpaperQueueEntry(id: "bookmark:\(bookmark.id)", title: bookmark.label, content: bookmark.content, origin: bookmark.wpeOrigin)
        }
        entries += AppleAerialsLibrary.shared.assets.map {
            WallpaperQueueEntry(id: "aerial:\($0.url.path)", title: $0.displayName, content: .video(bookmarkData: $0.bookmarkData))
        }
        return entries
    }

    static func candidates(in entries: [WallpaperQueueEntry], excluding current: WallpaperContent) -> [WallpaperQueueEntry] {
        var seen: Set<WallpaperQueueEntry.ID> = []
        return entries.filter {
            seen.insert($0.id).inserted && !SchedulePolicy.isSameContent($0.content, current)
        }
    }
}
