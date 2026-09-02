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
/// `title` floats on the picture's top edge, mirroring the control bar on its
/// bottom edge. It used to sit inside that bar, and being the only flexible item
/// among fixed-width clusters it was always what gave way — a video's filename
/// had a few dozen points left once the controls had taken theirs. On its own
/// edge it has the whole width, and the bar is controls only.
struct WallpaperPreviewStage<Title: View, Content: View, Controls: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        content()
            .aspectRatio(WallpaperPreviewMetrics.aspectRatio, contentMode: .fit)
            .overlay(alignment: .top) {
                title()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.lg)
            }
            .overlay(alignment: .bottom) {
                controls()
                    .padding(DesignTokens.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.lg)
    }
}

extension WallpaperPreviewStage where Title == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder controls: @escaping () -> Controls) {
        self.init(title: { EmptyView() }, content: content, controls: controls)
    }
}

/// The name, as a capsule floating on the preview's top edge — the same chrome
/// the control bar uses on the bottom edge, so the two read as one pair.
struct WallpaperPreviewTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, DesignTokens.Spacing.cardInset)
            .padding(.vertical, 6)
            .adaptiveGlassOverMedia(.capsule)
            .help(Text(verbatim: text))
            .accessibilityAddTraits(.isHeader)
    }
}
