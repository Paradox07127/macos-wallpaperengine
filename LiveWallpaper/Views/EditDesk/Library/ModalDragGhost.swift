import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// MOTION 7–9: the card that follows a modal-preview drag. The host positions it and owns the
/// drop; this only reflects the two states the drag can report back.
struct ModalDragGhost: View {
    static let size = CGSize(width: 140, height: 79)

    let image: CGImage?
    let isOverTarget: Bool
    /// Every change runs the MOTION 9 failure shake once; the value itself carries no meaning.
    let shakeTrigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        artwork
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.shelfCard))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.shelfCard)
                    .strokeBorder(DesignTokens.EditDesk.Colors.strokeHotShell, lineWidth: 2)
            }
            .shadow(
                color: DesignTokens.EditDesk.Shadow.hoverCard.color,
                radius: DesignTokens.EditDesk.Shadow.hoverCard.radius,
                y: DesignTokens.EditDesk.Shadow.hoverCard.y
            )
            .rotationEffect(.degrees(-5))
            .scaleEffect(isOverTarget && !reduceMotion ? 0.8 : 1)
            .animation(.easeOut(duration: 0.18), value: isOverTarget)
            .modifier(DragGhostShake(trigger: shakeTrigger, reduceMotion: reduceMotion))
            .allowsHitTesting(false)
            .transition(transition)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            DesignTokens.Colors.surfaceRaised
        }
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity.animation(.easeOut(duration: 0.15))
            : .scale.combined(with: .opacity).animation(.spring(response: 0.25, dampingFraction: 0.82))
    }
}

private struct DragGhostShake: ViewModifier {
    let trigger: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(DesignTokens.Opacity.dimmedContent, duration: 0.075)
                    LinearKeyframe(1.0, duration: 0.075)
                }
            }
        } else {
            content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-6, duration: 0.075)
                    CubicKeyframe(6, duration: 0.075)
                    CubicKeyframe(-6, duration: 0.075)
                    CubicKeyframe(0, duration: 0.075)
                }
            }
        }
    }
}
