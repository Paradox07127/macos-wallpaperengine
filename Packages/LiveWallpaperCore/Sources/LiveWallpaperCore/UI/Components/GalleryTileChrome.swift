import SwiftUI

struct GalleryTileChrome: ViewModifier {
    let isHovering: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat
    /// Overridable for surfaces that stack cards closer than a gallery grid
    /// does, where the default blur pools in the gaps.
    let shadowRadius: CGFloat
    let reduceMotion: Bool

    init(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        shadowRadius: CGFloat = DesignTokens.Card.shadowRadius,
        reduceMotion: Bool = false
    ) {
        self.isHovering = isHovering
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.reduceMotion = reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .thumbnailBadgeSurface(.opaque)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(DesignTokens.Card.strokeOpacity),
                        lineWidth: isSelected ? 2.5 : DesignTokens.Card.strokeWidth
                    )
            }
            // Radius stays constant across rest/hover/selected: a changing blur radius would be
            // re-rasterised every frame of the spring, where opacity and offset are not.
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(DesignTokens.Card.selectedShadowOpacity)
                    : .black.opacity(isHovering
                                     ? DesignTokens.Card.shadowOpacity
                                     : DesignTokens.Card.restShadowOpacity),
                radius: shadowRadius,
                x: 0,
                y: isHovering
                    ? DesignTokens.Card.shadowYOffset
                    : DesignTokens.Card.restShadowYOffset
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            // 150ms must match the title band and the hover-in delay, or the card
            // reads as settling twice.
            .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isHovering)
            .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isSelected)
    }
}

extension View {
    public func galleryTileChrome(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        shadowRadius: CGFloat = DesignTokens.Card.shadowRadius,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(GalleryTileChrome(
            isHovering: isHovering,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            shadowRadius: shadowRadius,
            reduceMotion: reduceMotion
        ))
    }
}
