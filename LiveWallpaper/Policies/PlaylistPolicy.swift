import Foundation
import LiveWallpaperCore

enum PlaylistPolicy {
    static func refreshLegacyBookmark(
        at cursor: Int,
        in configuration: inout ScreenConfiguration,
        with bookmarkData: Data
    ) {
        guard configuration.savedVideoBookmarkData != nil else { return }
        let count = configuration.combinedPlaylist.count
        guard cursor >= 0, cursor < count else { return }
        let primary = max(0, min(configuration.playlistPrimaryIndex ?? 0, count - 1))
        if cursor == primary {
            configuration.savedVideoBookmarkData = bookmarkData
        } else if var additional = configuration.playlistBookmarks {
            let index = cursor < primary ? cursor : cursor - 1
            additional[index] = bookmarkData
            configuration.playlistBookmarks = additional
        }
    }

    static func shouldRotate(
        now: Date,
        lastRotation: Date,
        rotationMinutes: Int
    ) -> Bool {
        guard rotationMinutes > 0 else { return false }
        return now.timeIntervalSince(lastRotation) >= Double(rotationMinutes) * 60.0
    }

    static func resolveCursor(activeBookmark: Data?, in combined: [Data]) -> Int {
        guard let activeBookmark else { return 0 }
        return combined.firstIndex(of: activeBookmark) ?? 0
    }
}
