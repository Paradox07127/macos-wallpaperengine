import SwiftUI

/// Hover lift for interactive cards that draw their own surface instead of going through
/// `GalleryTileChrome`. Same physics, same source of truth: every constant here is the
/// `DesignTokens.Card` group the chrome reads — scale 1.02, shadow opacity/y-offset
/// interpolation, spring(0.28, 0.85). The shadow radius is deliberately a single constant,
/// per the note in `GalleryTileChrome`: a blur radius that changes has to be re-rasterised
/// every frame of the spring, while opacity and offset do not.
private struct CardHoverEffect: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .shadow(
                color: .black.opacity(isActive
                    ? DesignTokens.Card.shadowOpacity
                    : DesignTokens.Card.restShadowOpacity),
                radius: DesignTokens.Card.shadowRadius,
                x: 0,
                y: isActive
                    ? DesignTokens.Card.shadowYOffset
                    : DesignTokens.Card.restShadowYOffset
            )
            .scaleEffect(isActive && !reduceMotion ? 1.02 : 1.0)
            .animation(
                DesignTokens.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.85)),
                value: isActive
            )
    }
}

public extension View {
    func cardHoverEffect(isActive: Bool, reduceMotion: Bool) -> some View {
        modifier(CardHoverEffect(isActive: isActive, reduceMotion: reduceMotion))
    }
}
