import SwiftUI

/// Decides whether a one-line label scrolls instead of truncating. Split out of
/// the view so the rule can be tested without a render pass.
public enum MarqueeMetrics {
    /// Sub-pixel overflow is rounding noise, not text the reader is missing.
    public static let threshold: CGFloat = 1

    /// Points per second. Faster than `MarqueeText`'s vertical crawl (12 pt/s):
    /// that one reveals a line at a time and the eye waits for each line, while
    /// a path slides past continuously and 12 pt/s would take half a minute.
    public static let speed: CGFloat = 45

    /// Let the reader see what already fits before anything moves.
    public static let startDelay: TimeInterval = 0.5

    public static func overflow(textWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        max(0, textWidth - containerWidth)
    }

    public static func shouldScroll(
        textWidth: CGFloat,
        containerWidth: CGFloat,
        isHovering: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard isHovering, !reduceMotion, containerWidth > 0 else { return false }
        return overflow(textWidth: textWidth, containerWidth: containerWidth) > threshold
    }

    /// Constant reading speed, not constant duration: a path twice as long takes
    /// twice as long to pass, so a long one never blurs by.
    public static func duration(overflow: CGFloat) -> Double {
        max(0.6, Double(overflow / speed))
    }
}

/// Horizontal sibling of `MarqueeText`, borrowing its central trick: an
/// invisible base owns the layout while the copy the reader sees rides in
/// an `overlay`, which never resizes its base. Hanging `fixedSize` on the
/// label itself instead keeps it clamped to the row's width, scrolling the
/// *truncated* string with the tail hidden — the bug this replaced.
private struct MarqueeOnHover: ViewModifier {
    let truncationMode: Text.TruncationMode

    @State private var isHovering = false
    @State private var boxWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat {
        MarqueeMetrics.overflow(textWidth: contentWidth, containerWidth: boxWidth)
    }

    private var shouldScroll: Bool {
        MarqueeMetrics.shouldScroll(
            textWidth: contentWidth,
            containerWidth: boxWidth,
            isHovering: isHovering,
            reduceMotion: reduceMotion
        )
    }

    /// The crawl restarts whenever this changes, not only when scrolling
    /// flips: resizing the row changes how far the text must travel while
    /// the pointer stays put, and an animation aimed at the old distance
    /// would stop short. Rounded to half a point so measurement jitter
    /// can't restart it every frame.
    private var plan: ScrollPlan {
        ScrollPlan(isScrolling: shouldScroll, distance: (overflow * 2).rounded() / 2)
    }

    private struct ScrollPlan: Equatable {
        let isScrolling: Bool
        let distance: CGFloat
    }

    func body(content: Content) -> some View {
        // At rest this modifier is one truncated `Text`. Every inspector row
        // and gallery card carries one, so the hidden full-width copy — a
        // whole second text layout, needed only to decide overflow — mounts
        // only while the pointer is here. The crawl waits `startDelay`
        // before moving, so measuring on hover-in is in time.
        content
            .lineLimit(1)
            .truncationMode(truncationMode)
            .opacity(isHovering ? 0 : 1)
            .accessibilityHidden(isHovering)
            // `onGeometryChange` rather than a `GeometryReader` publishing into a
            // `PreferenceKey`: it reports a value the view already has, only when
            // that value actually changes, with no preference tree to reduce
            // through on every layout pass. macOS 13+, so no availability gate.
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { boxWidth = $0 }
            .background(alignment: .leading) {
                if isHovering {
                    // Full-width copy, hidden. `background` never resizes its
                    // base, so measuring the whole string cannot widen the row.
                    content
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
                }
            }
            .overlay(alignment: .leading) {
                if isHovering { visible(content) }
            }
            .clipped()
            .onChange(of: plan) { _, _ in restart() }
            .onHover { hovering in
                isHovering = hovering
                // The full-width copy is unmounted on exit, so its last reported
                // width would otherwise linger and claim the label still overflows.
                if !hovering { contentWidth = 0 }
            }
    }

    /// Scrolling shows the whole string at its natural width; at rest the
    /// ellipsis is still the correct resting state.
    @ViewBuilder
    private func visible(_ content: Content) -> some View {
        if shouldScroll {
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
        } else {
            content
                .lineLimit(1)
                .truncationMode(truncationMode)
        }
    }

    private func restart() {
        guard shouldScroll else {
            guard offset != 0 else { return }
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
            return
        }
        offset = 0
        withAnimation(
            .linear(duration: MarqueeMetrics.duration(overflow: overflow))
                .delay(MarqueeMetrics.startDelay)
                .repeatForever(autoreverses: true)
        ) {
            offset = -overflow
        }
    }
}

public extension View {
    /// One-line label that reveals its tail by scrolling while the pointer
    /// rests on it, instead of hiding it behind an ellipsis for good. Falls
    /// back to plain truncation when it already fits, when the pointer is
    /// away, and under Reduce Motion — the ellipsis is still the resting
    /// state. The multi-line card-title equivalent is `MarqueeText`. Meant
    /// for `Text`: while hovered the label renders three times — an
    /// invisible base owning the width, a hidden full-width copy that
    /// measures, and the copy the reader sees — so the wrapped view must be
    /// cheap and stateless. At rest it's a single truncated label.
    func marqueeOnHover(truncationMode: Text.TruncationMode = .middle) -> some View {
        modifier(MarqueeOnHover(truncationMode: truncationMode))
    }
}
