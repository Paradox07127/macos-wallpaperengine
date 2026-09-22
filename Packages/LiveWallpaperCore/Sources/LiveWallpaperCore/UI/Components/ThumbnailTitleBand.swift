import SwiftUI

public struct ThumbnailTitleBand<Leading: View, Trailing: View>: View {
    private let title: String
    private let isHovering: Bool
    private let leading: Leading
    private let trailing: Trailing

    @State private var lineHeight: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// How far the gradient reaches above the band, so its top edge dissolves
    /// into the picture instead of ending on a line.
    private static var fade: CGFloat { 18 }

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
            MarqueeText(title, lineLimit: 2, isActive: isHovering)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(height: isHovering ? lineHeight * 2 : lineHeight, alignment: .top)
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
        .background(alignment: .bottom) { scrim.allowsHitTesting(false) }
        .background(alignment: .leading) { lineSizer.allowsHitTesting(false) }
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isHovering)
    }

    /// Sized to the band it backs plus a fixed fade above it, not to a fixed overall height.
    @ViewBuilder
    private var scrim: some View {
        if reduceTransparency {
            Rectangle().fill(Color.black.opacity(0.92))
        } else {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.62), location: 0.5),
                    .init(color: .black.opacity(0.86), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -Self.fade)
        }
    }

    /// One line of the title font, measured rather than assumed: the band's open
    /// and closed heights are multiples of it.
    private var lineSizer: some View {
        Text(verbatim: "X")
            .font(DesignTokens.Typography.bodyEmphasized)
            .lineLimit(1, reservesSpace: true)
            .opacity(0)
            .accessibilityHidden(true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TitleLineHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(TitleLineHeightKey.self) { lineHeight = $0 }
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

private struct TitleLineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 16
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
