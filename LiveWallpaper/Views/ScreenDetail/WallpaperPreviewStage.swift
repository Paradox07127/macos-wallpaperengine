import LiveWallpaperCore
import SwiftUI

enum WallpaperPreviewMetrics {
    /// Display aspect: a wallpaper preview is a screen, whatever it renders.
    static let aspectRatio: CGFloat = 16 / 9
}

/// The one preview stage for video, web and scene: an aspect-fitted card centred
/// in the pane, with controls floating along its bottom edge.
///
/// Before this the three were hand-rolled separately and had drifted — two
/// padding values against none, two sizing routines for the same 16:9 fit, and
/// scene pinned to the top while the other two came out centred.
///
/// `controls` is overlaid *before* the expanding frame on purpose: the frame is
/// the whole pane, the aspect-fit box is the picture, and controls hung after the
/// frame drift past the picture's edges. Keeping that order here means no caller
/// can get it wrong.
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

extension WallpaperPreviewStage where Controls == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, controls: { EmptyView() })
    }
}
