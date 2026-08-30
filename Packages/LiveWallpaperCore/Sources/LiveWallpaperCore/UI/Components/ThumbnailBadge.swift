import SwiftUI

/// A small pill floating over a thumbnail or preview: optional glyph, optional label, glass backing.
/// Nine of these were written out longhand across four files — resolution, rating, In Library,
/// Update, In use, compatibility, playing, and the Aerials format labels. They drifted: padding ran
/// 5/2, 6/3 and 7/3 for badges that sit side by side. One component keeps the metrics in one place.
/// Badges are `accessibilityHidden` by default because the cards combine their children into a
/// single element and restate the information in the card's own label. Pass `accessibility:` for a
/// badge that has no such host.
public struct ThumbnailBadge: View {
    private let systemImage: String?
    private let label: Text?
    private let tint: Color
    private let opacity: Double
    private let accessibility: Text?
    /// Letter-spacing for labels set in caps (the type badge); 0 elsewhere,
    /// because tracking a mixed-case label just loosens it.
    private var tracking: CGFloat = 0

    /// Localized label. Resolved against the app bundle, like every other shared
    /// component that renders app copy.
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tint: Color = .black,
        opacity: Double = 0.6,
        accessibility: Text? = nil
    ) {
        self.systemImage = systemImage
        self.label = Text(title)
        self.tint = tint
        self.opacity = opacity
        self.accessibility = accessibility
    }

    /// Already-resolved text — a resolution glyph, a rating number, an author's
    /// string. Distinct label so a string literal can't pick the wrong overload.
    public init(
        verbatim title: String,
        systemImage: String? = nil,
        tint: Color = .black,
        opacity: Double = 0.6,
        accessibility: Text? = nil,
        tracking: CGFloat = 0
    ) {
        self.systemImage = systemImage
        self.label = Text(verbatim: title)
        self.tint = tint
        self.opacity = opacity
        self.accessibility = accessibility
        self.tracking = tracking
    }

    /// Glyph only.
    public init(
        systemImage: String,
        tint: Color = .black,
        opacity: Double = 0.6,
        accessibility: Text? = nil
    ) {
        self.systemImage = systemImage
        self.label = nil
        self.tint = tint
        self.opacity = opacity
        self.accessibility = accessibility
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            if let label {
                label
                    .font(DesignTokens.Typography.badge)
                    .tracking(tracking)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass(tint: tint, opacity: opacity)
        .fixedSize()
        .modifier(BadgeAccessibility(label: accessibility))
    }
}

private struct BadgeAccessibility: ViewModifier {
    let label: Text?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
