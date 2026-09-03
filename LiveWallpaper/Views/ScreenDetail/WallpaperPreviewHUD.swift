import LiveWallpaperCore
import SwiftUI

/// The bar floating on the preview's bottom edge, for all three wallpaper types.
///
/// The rule: **this bar controls the canvas; the inspector controls the asset.**
/// Anything whose effect the preview cannot show belongs in the inspector — that
/// is how span-all-displays left, and the test for whatever is proposed next.
///
/// Zones stay in the order viewport ⎪ playback ⎪ actions so a control keeps its
/// place across types. The wallpaper name is NOT here: as the one flexible item
/// it always gave way, so it has its own row above the picture
/// (`WallpaperPreviewStage`). Every control is a glyph over a fixed-width
/// caption (`PreviewControlLabel`), never free-width text — the bar shrinks with
/// the window and Japanese runs 1.5–2× wider. Values live in tooltips, popovers
/// and the accessibility value.
struct WallpaperPreviewHUD<Viewport: View, Playback: View, Actions: View>: View {
    @ViewBuilder var viewport: Viewport
    @ViewBuilder var playback: Playback
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            leadingZone { viewport }
            zone { playback }
            zone { actions }
        }
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 6)
        .adaptiveGlassOverMedia(.capsule)
    }

    /// The first zone with content carries no leading hairline; the rest do. A
    /// type that skips one (web has no scale) gets no stray divider either way.
    @ViewBuilder
    private func leadingZone(@ViewBuilder _ content: () -> some View) -> some View {
        let built = content()
        if built is EmptyView {
            EmptyView()
        } else {
            built.fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func zone(@ViewBuilder _ content: () -> some View) -> some View {
        let built = content()
        if built is EmptyView {
            EmptyView()
        } else {
            Divider().frame(height: 22)
            built.fixedSize(horizontal: true, vertical: false)
        }
    }
}
