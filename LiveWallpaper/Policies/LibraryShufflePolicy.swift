import Foundation
import LiveWallpaperCore

/// An automatic-selection candidate; a Workshop import is resolved only when the selection loop reaches it.
struct LibraryShuffleCandidate {
    let id: WallpaperQueueEntry.ID
    /// Set for unresolved Workshop imports, which are told apart from the showing wallpaper by this id instead of by content.
    let workshopID: String?
    /// nil until resolved.
    let resolvedEntry: WallpaperQueueEntry?
    private let resolver: @MainActor () -> WallpaperQueueEntry?

    init(_ entry: WallpaperQueueEntry) {
        id = entry.id
        workshopID = nil
        resolvedEntry = entry
        resolver = { entry }
    }

    init(id: WallpaperQueueEntry.ID, workshopID: String, resolve: @escaping @MainActor () -> WallpaperQueueEntry?) {
        self.id = id
        self.workshopID = workshopID
        resolvedEntry = nil
        resolver = resolve
    }

    @MainActor func resolve() -> WallpaperQueueEntry? {
        resolver()
    }
}

@MainActor
enum LibraryShufflePolicy {
    /// Reads the backing stores without depending on an open library window or its filters.
    static func liveEntries(canRender: @escaping @MainActor (WallpaperType) -> Bool) -> [LibraryShuffleCandidate] {
        let bookmarks = BookmarkStore.shared.bookmarks
        var entries: [LibraryShuffleCandidate] = []
        #if !LITE_BUILD
        let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
        let installed = Set(history.map(\.id))
        let resolver = WPECachedContentResolver()
        entries = workshopCandidates(in: history) { origin in
            resolver.content(for: origin).flatMap { canRender($0.wallpaperType) ? $0 : nil }
        }
        #endif
        entries += bookmarks.compactMap { bookmark in
            #if !LITE_BUILD
            if let id = bookmark.wpeOrigin?.workshopID, installed.contains(id),
               SavedLibraryModel.foldsIntoWorkshopRow(bookmark.content) {
                return nil
            }
            #endif
            return LibraryShuffleCandidate(
                WallpaperQueueEntry(id: "bookmark:\(bookmark.id)", title: bookmark.label, content: bookmark.content, origin: bookmark.wpeOrigin)
            )
        }
        entries += AppleAerialsLibrary.shared.assets.map {
            LibraryShuffleCandidate(
                WallpaperQueueEntry(id: "aerial:\($0.url.path)", title: $0.displayName, content: .video(bookmarkData: $0.bookmarkData))
            )
        }
        return entries.filter { $0.resolvedEntry.map { canRender($0.content.wallpaperType) } ?? true }
    }

    #if !LITE_BUILD
    /// Lists import history without opening any item; `content` runs only for the item the selection loop reaches.
    static func workshopCandidates(
        in history: [WPEHistoryEntry], content: @escaping @MainActor (WPEOrigin) -> WallpaperContent?
    ) -> [LibraryShuffleCandidate] {
        history.compactMap { item in
            guard item.origin.originalType != .application, item.origin.originalType != .unknown else { return nil }
            let id = "workshop:\(item.id)"
            return LibraryShuffleCandidate(id: id, workshopID: item.id) {
                content(item.origin).map { WallpaperQueueEntry(id: id, title: item.origin.title, content: $0, origin: item.origin) }
            }
        }
    }
    #endif

    /// `origin` is the showing wallpaper's Workshop origin; it identifies a showing Workshop video or web page.
    static func candidates(
        in entries: [LibraryShuffleCandidate], excluding current: WallpaperContent, origin: WPEOrigin?
    ) -> [LibraryShuffleCandidate] {
        let currentWorkshopID: String? = if case let .scene(descriptor) = current {
            descriptor.workshopID
        } else {
            origin?.workshopID
        }
        var seen: Set<WallpaperQueueEntry.ID> = []
        return entries.filter { candidate in
            guard seen.insert(candidate.id).inserted else { return false }
            if let entry = candidate.resolvedEntry {
                return !SchedulePolicy.isSameContent(entry.content, current)
            }
            return candidate.workshopID != currentWorkshopID
        }
    }
}
