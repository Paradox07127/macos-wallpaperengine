import LiveWallpaperCore
import SwiftUI

/// Fixed-width labels keep control positions stable across languages.
struct WallpaperPreviewHUD<Viewport: View, Playback: View, Actions: View>: View {
    @ViewBuilder var viewport: Viewport
    @ViewBuilder var playback: Playback
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            row.environment(\.compactPreviewControls, true)
        }
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 6)
        .adaptiveGlassOverMedia(.capsule)
    }

    private var row: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            leadingZone { viewport }
            zone { playback }
            zone { actions }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The viewport zone carries no leading hairline; the zones after it do.
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
