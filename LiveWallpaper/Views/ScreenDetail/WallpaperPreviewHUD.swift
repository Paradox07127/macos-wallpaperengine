import LiveWallpaperCore
import SwiftUI

/// The bar floating on the preview's bottom edge, for all three wallpaper types.
///
/// The rule it enforces: **this bar controls the canvas; the inspector controls
/// the asset.** Anything whose effect the preview cannot show belongs in the
/// inspector column instead — that is how span-all-displays left, and it is the
/// test to apply to whatever is proposed next.
///
/// Three zones, always in this order, so a control keeps its place across types:
///
///   viewport ⎪ playback ⎪ actions
///
/// The name is NOT here: as the one flexible item among fixed-width clusters it
/// was always what gave way, so it has its own row above the picture
/// (`WallpaperPreviewStage`).
///
/// * **viewport** — how it fills the display (scale).
/// * **playback** — how it runs (volume, speed, frame rate, input).
/// * **actions** — everything else the type offers.
///
/// Every control is a glyph over a fixed-width caption (`PreviewControlLabel`),
/// never a free-width label: the bar sits over arbitrary artwork at a width that
/// shrinks with the window, and text that grows 1.5–2× in Japanese would push
/// its neighbours off the bar. Values live in tooltips, popovers and the
/// accessibility value.
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
