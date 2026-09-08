import SwiftUI

/// Shares GalleryTileChrome hover tokens. Keep shadow radius constant to avoid
/// rerasterizing the blur during the hover animation.
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
