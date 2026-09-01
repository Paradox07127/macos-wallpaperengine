import Foundation
import LiveWallpaperCore

extension ScreenManager {
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        guard !isTerminating else { return }
        Logger.info("Applying bookmark to screen \(screen.id): \(bookmark.wallpaperType.rawValue)", category: .ui)

        // Content only. A bookmark is a favourite wallpaper, not a screen setup —
        // applying one leaves this display's volume, effects, fit mode and overlay
        // exactly as they were. The whole-screen counterpart is a Scheme
        // (`ScreenManager+Schemes.swift`). `playbackSettings` on older bookmarks is
        // deliberately left on disk, unread: see .notes/plan/screen-schemes.md D1.
        switch bookmark.content {
        case .video(let bookmarkData, let packageEntryName):
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            setVideo(
                url: resolved.url,
                bookmarkData: resolved.bookmarkData,
                packageEntryName: packageEntryName,
                for: screen
            )
        case .html(let source, let config):
            setHTMLWallpaper(
                source: source,
                config: config,
                bookmarkID: bookmark.id,
                wpeOrigin: bookmark.wpeOrigin,
                for: screen
            )
        case .scene(let descriptor):
            setSceneWallpaper(descriptor: descriptor, origin: bookmark.wpeOrigin, for: screen)
        }
    }
}
