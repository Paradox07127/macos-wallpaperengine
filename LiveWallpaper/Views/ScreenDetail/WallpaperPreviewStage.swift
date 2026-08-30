import LiveWallpaperCore
import SwiftUI

enum WallpaperPreviewMetrics {
    /// Display aspect: a wallpaper preview is a screen, whatever it renders.
    static let aspectRatio: CGFloat = 16 / 9
}

/// The one preview stage for video, web and scene: an aspect-fitted card centred
/// in the pane, with controls floating along its bottom edge.
/// Before this the three were hand-rolled separately and had drifted — two padding values
/// against none, two sizing routines for the same 16:9 fit, scene pinned to the top while the
/// other two centred. `controls` is overlaid *before* the expanding frame on purpose: the frame
/// is the pane, the aspect-fit box is the picture, and controls after the frame drift past its edges — keeping this order means no caller can get it wrong.
struct WallpaperPreviewStage<Content: View, Controls: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        content()
            .aspectRatio(WallpaperPreviewMetrics.aspectRatio, contentMode: .fit)
            .overlay(alignment: .bottom) {
                controls()
                    .padding(DesignTokens.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.lg)
    }
}
