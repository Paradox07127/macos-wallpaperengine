import LiveWallpaperCore
import SwiftUI

struct LibraryApplyTargetList: View {
    let screens: [Screen]
    let onApply: (Screen) -> Void
    /// Nil for whole-display schemes, which apply to one display at a time.
    var onApplyToAll: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") {
                    dismiss()
                    onApply(screen)
                }
            }
            if let onApplyToAll {
                Divider()
                Button("Apply to All Displays") {
                    dismiss()
                    onApplyToAll()
                }
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 220)
    }
}

/// A real `Button` + popover, never a `Menu`: an AppKit popup paints its label in the system control colour, which is invisible over artwork.
struct LibraryTileOverflowButton<Content: View>: View {
    var width: CGFloat = 200
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content

    @State private var isHovering = false
    @State private var showingActions = false

    var body: some View {
        Button { showingActions = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 22, height: 22)
                .floatingGlyphGlass(hovered: isHovering)
                .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .help(Text("More actions"))
        .accessibilityLabel(Text("More actions"))
        .popover(isPresented: $showingActions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                content { showingActions = false }
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsPopoverChrome(width: width)
        }
    }
}

struct LibraryTileUnavailableVeil: View {
    var body: some View {
        Rectangle()
            .fill(.black.opacity(0.45))
            .overlay {
                Image(systemName: "nosign")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(0.9))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The entry id alone is not enough: a cover is written after the entry is saved, and the tile has to reload when that name appears.
struct TileContentKey: Hashable {
    let id: UUID
    let coverFileName: String?
    /// For entries rewritten in place under the same id, so the tile reloads even when the cover name is unchanged. Nil for immutable content.
    var version: Date?
}
