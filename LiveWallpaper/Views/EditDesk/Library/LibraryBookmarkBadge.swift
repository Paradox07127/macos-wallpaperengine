import LiveWallpaperCore
import SwiftUI

extension LibraryBookmarkStore {
    static let shared = LibraryBookmarkStore(defaults: .appScoped())
}

/// The bookmark corner of a Wallpaper Library grid tile.
struct LibraryBookmarkBadge: View {
    let isBookmarked: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(isBookmarked ? DesignTokens.Colors.rating : DesignTokens.Colors.overlayForeground)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 0.72 rather than the default backing, which disappears into bright wallpaper stills.
        .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
        .onHover { isHovering = $0 }
        .help(isBookmarked ? Text("Remove Bookmark") : Text("Add Bookmark"))
        .accessibilityLabel(isBookmarked ? Text("Remove Bookmark") : Text("Add Bookmark"))
    }
}
