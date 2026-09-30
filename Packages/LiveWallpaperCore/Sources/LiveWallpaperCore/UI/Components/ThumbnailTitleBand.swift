import SwiftUI

public struct ThumbnailTitleBand<Leading: View, Trailing: View>: View {
    private let title: String
    private let isHovering: Bool
    private let leading: Leading
    private let trailing: Trailing

    public init(
        title: String,
        isHovering: Bool,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.isHovering = isHovering
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            leading

            // Click-through, or the band blocks the whole-card apply gesture beneath it.
            MarqueeText(title, lineLimit: 1, isActive: isHovering)
                .font(DesignTokens.EditDesk.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .clipped()
                .allowsHitTesting(false)

            Spacer(minLength: 0)

            trailing
        }
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension ThumbnailTitleBand where Leading == EmptyView {
    init(title: String, isHovering: Bool, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, isHovering: isHovering, leading: { EmptyView() }, trailing: trailing)
    }
}

/// The green check a tile wears when its wallpaper is already local.
public struct ThumbnailPresenceCheck: View {
    /// `solid` fills the disc with `tint` as given and draws the glyph in `glyph`; the glass
    /// appearance tints the material behind a white one instead.
    public enum Appearance: Sendable {
        case glass
        case solid(glyph: Color)
    }

    private let tint: Color
    private let appearance: Appearance

    public init(tint: Color = DesignTokens.Colors.badgeActive, appearance: Appearance = .glass) {
        self.tint = tint
        self.appearance = appearance
    }

    public var body: some View {
        switch appearance {
        case .glass:
            check(DesignTokens.Colors.overlayForeground)
                .thumbnailBadgeGlass(tint: tint, opacity: 0.55, in: .circle)
                .accessibilityHidden(true)
        case let .solid(glyph):
            check(glyph)
                .background(Circle().fill(tint))
                .accessibilityHidden(true)
        }
    }

    private func check(_ color: Color) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
    }
}
