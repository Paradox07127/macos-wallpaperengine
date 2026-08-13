import SwiftUI

/// Shared gallery-card chrome: a light glass surface, a hairline edge, and a
/// hover lift. The glass is not decoration — without a surface the card's footer
/// is transparent, so `shadow` traces the opaque thumbnail alone and draws a line
/// across the card's waist instead of sitting behind the whole card.
struct GalleryTileChrome: ViewModifier {
    let isHovering: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat
    let reduceMotion: Bool

    init(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) {
        self.isHovering = isHovering
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.reduceMotion = reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .adaptiveGlassSurface(.roundedRectangle(cornerRadius), stroked: false)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(DesignTokens.Card.strokeOpacity),
                        lineWidth: isSelected ? 2.5 : DesignTokens.Card.strokeWidth
                    )
            }
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(DesignTokens.Card.selectedShadowOpacity)
                    : .black.opacity(isHovering
                                     ? DesignTokens.Card.shadowOpacity
                                     : DesignTokens.Card.restShadowOpacity),
                radius: isHovering || isSelected
                    ? DesignTokens.Card.shadowRadius
                    : DesignTokens.Card.restShadowRadius,
                x: 0,
                y: isHovering
                    ? DesignTokens.Card.shadowYOffset
                    : DesignTokens.Card.restShadowYOffset
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(
                DesignTokens.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.85)),
                value: isHovering
            )
            .animation(
                DesignTokens.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.85)),
                value: isSelected
            )
    }
}

extension View {
    public func galleryTileChrome(
        isHovering: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Corner.lg,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(GalleryTileChrome(
            isHovering: isHovering,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            reduceMotion: reduceMotion
        ))
    }
}
