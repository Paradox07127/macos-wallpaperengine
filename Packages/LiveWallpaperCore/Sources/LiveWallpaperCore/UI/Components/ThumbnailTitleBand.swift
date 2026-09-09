import SwiftUI

/// Hover reveals a second title line while text remains laid out in a two-line window.
/// A gradient avoids filtering every video frame and darkens the title background.
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

            MarqueeText(title, lineLimit: 2, isActive: isHovering)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(height: isHovering ? lineHeight * 2 : lineHeight, alignment: .top)
                .clipped()

            Spacer(minLength: 0)

            trailing
        }
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) { scrim }
        .background(alignment: .leading) { lineSizer }
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isHovering)
    }

    /// Sized to the band it backs plus a fixed fade above it. A fixed overall
    /// height darkened far more of the picture than one or two lines of type
    /// ever needed.
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

/// The green glass check a tile wears when its wallpaper is already local.
public struct ThumbnailPresenceCheck: View {
    private let tint: Color

    public init(tint: Color = DesignTokens.Colors.badgeActive) {
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .frame(width: 18, height: 18)
            .thumbnailBadgeGlass(tint: tint, opacity: 0.55, in: .circle)
            .accessibilityHidden(true)
    }
}

private struct TitleLineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 16
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
