import LiveWallpaperCore
import SwiftUI

extension LibraryBookmarkStore {
    static let shared = LibraryBookmarkStore(defaults: .appScoped())
}

/// A grid tile's corner mark: the Wallpaper Library bookmark or the Workshop like.
struct TileMarkBadge: View {
    enum Mark {
        case bookmark, like
    }

    let mark: Mark
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isOn ? tint : DesignTokens.Colors.overlayForeground)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 0.72 rather than the default backing, which disappears into bright wallpaper stills.
        .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }

    private var symbol: String {
        switch mark {
        case .bookmark: isOn ? "bookmark.fill" : "bookmark"
        case .like: isOn ? "heart.fill" : "heart"
        }
    }

    private var tint: Color {
        switch mark {
        case .bookmark: DesignTokens.Colors.rating
        case .like: DesignTokens.Colors.like
        }
    }

    private var title: Text {
        switch (mark, isOn) {
        case (.bookmark, true): Text("Remove Bookmark")
        case (.bookmark, false): Text("Add Bookmark")
        case (.like, true): Text("Unlike")
        case (.like, false): Text("Like")
        }
    }
}
