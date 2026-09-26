#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct ThumbnailBookmarkButton: View {
    let isBookmarked: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(isBookmarked
                    ? DesignTokens.Colors.rating
                    : DesignTokens.Colors.overlayForeground)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Explicit 0.72 rather than the 0.18/0.32 default: the default backing
        // disappears into bright wallpaper stills.
        .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
        .onHover { isHovering = $0 }
        .help(Text(isBookmarked ? "Remove Bookmark" : "Add Bookmark"))
        .accessibilityLabel(Text(isBookmarked ? "Remove Bookmark" : "Add Bookmark"))
    }
}
#endif
