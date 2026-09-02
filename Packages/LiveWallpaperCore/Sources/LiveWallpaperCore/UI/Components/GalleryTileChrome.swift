import SwiftUI

/// Shared gallery-card chrome: an opaque raised surface, a hairline edge, and a hover lift. The
/// surface is not decoration — without one the card's footer is transparent, so `shadow` traces the
/// opaque thumbnail alone and draws a line across the card's waist instead of sitting behind the
/// whole card. Opaque rather than glass: a card-sized `glassEffect` resamples whatever is scrolling
/// behind it every frame, and the thumbnail covers most of it anyway. The same reasoning reaches the
/// badges floating over the artwork, which is why this sets `thumbnailBadgeSurface(.opaque)` for
/// everything it wraps — a gallery page carries roughly four badges on each of ~50 cards, all of
/// which would sample the scrolling content otherwise. Detail and inspector surfaces do not use this
/// chrome, so their badges keep the real material.
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
            // The radius is deliberately constant across rest/hover/selected. It used to interpolate
            // 3→12, and a shadow whose blur radius changes has to be re-rasterised every frame of the
            // spring; opacity and offset do not. The lift now comes from opacity, `y`, and the scale
            // below — the hovered/selected appearance is unchanged, only the resting shadow went from
            // tight to diffuse at the same 5% black, keeping hover a smooth interpolation rather than
            // a pop from flat.
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
            // Same 150ms as the title band and the hover-in delay: the lift and
            // the band grow together, so two curves of different lengths read as
            // the card settling twice.
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
