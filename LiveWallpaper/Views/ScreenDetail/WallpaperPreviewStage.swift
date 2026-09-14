import LiveWallpaperCore
import SwiftUI

enum WallpaperPreviewMetrics {
    static let aspectRatio: CGFloat = 16 / 9
}

/// `controls` is overlaid *before* the expanding frame on purpose: applied after it,
/// they drift past the picture's edges rather than sitting on the aspect-fit box.
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
