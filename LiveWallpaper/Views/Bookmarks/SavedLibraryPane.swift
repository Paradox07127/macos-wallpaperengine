import LiveWallpaperCore
import SwiftUI

struct SavedLibraryPane: View {
    var body: some View {
        Group {
            #if !LITE_BUILD
            SavedWallpaperLibraryView()
            #else
            LibraryView()
            #endif
        }
        .task {
            WallpaperCoverStore.shared.removeOrphans(
                keeping: Set(
                    BookmarkStore.shared.bookmarks.compactMap(\.coverFileName)
                        + SchemeStore.shared.schemes.compactMap(\.coverFileName)
                )
            )
        }
    }
}
