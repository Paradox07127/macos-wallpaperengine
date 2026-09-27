import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore

@MainActor
enum DisplayConfigurationTestSupport {
    static func commands(for store: WallpaperConfigurationStore) -> DisplayConfigurationController {
        DisplayConfigurationController(
            store: store,
            bookmarkDisplayNameCache: BookmarkDisplayNameCache(),
            releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {},
            advanceSceneMutationIntent: { _ in },
            notificationCenter: NotificationCenter()
        )
    }
}
