import LiveWallpaperCore
import SwiftUI

/// Canvas controls in fixed order: viewport, playback, actions.
/// Fixed-width labels keep control positions stable across languages.
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
