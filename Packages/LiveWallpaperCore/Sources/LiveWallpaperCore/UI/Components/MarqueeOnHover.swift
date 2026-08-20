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

private struct MarqueeBoxWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Horizontal sibling of `MarqueeText`, and it borrows that view's central trick:
/// an invisible base owns the layout while the copy the reader sees rides in an
/// `overlay`, which never resizes its base. Hanging `fixedSize` on the label
/// itself instead keeps it clamped to the row's width, so it scrolls the
/// *truncated* string and the tail stays hidden — which is the bug this replaced.
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

    /// The crawl restarts whenever this changes, not only when scrolling flips:
    /// resizing the row changes how far the text has to travel while the pointer
    /// stays put, and an animation still aiming at the old distance would stop
    /// short of the tail. Rounded to half a point so measurement jitter can't
    /// restart it every frame.
    private var plan: ScrollPlan {
        ScrollPlan(isScrolling: shouldScroll, distance: (overflow * 2).rounded() / 2)
    }

    private struct ScrollPlan: Equatable {
        let isScrolling: Bool
        let distance: CGFloat
    }

    func body(content: Content) -> some View {
        // Base: truncated, invisible, and the only thing that owns width here.
        content
            .lineLimit(1)
            .truncationMode(truncationMode)
            .opacity(0)
            .accessibilityHidden(true)
            .background(measure(MarqueeBoxWidthKey.self))
            .background(alignment: .leading) {
                // Full-width copy, hidden. `background` never resizes its base,
                // so measuring the whole string cannot widen the row.
                content
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(measure(MarqueeContentWidthKey.self))
            }
            .overlay(alignment: .leading) {
                visible(content)
            }
            .clipped()
            .onPreferenceChange(MarqueeBoxWidthKey.self) { boxWidth = $0 }
            .onPreferenceChange(MarqueeContentWidthKey.self) { contentWidth = $0 }
            .onChange(of: plan) { _, _ in restart() }
            .onHover { isHovering = $0 }
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

    private func measure<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.width)
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
    /// One-line label that reveals its tail by scrolling while the pointer rests
    /// on it, instead of hiding it behind an ellipsis for good. Falls back to
    /// plain truncation when it already fits, when the pointer is away, and
    /// under Reduce Motion — so the ellipsis is still the resting state.
    ///
    /// The multi-line card-title equivalent is `MarqueeText`.
    ///
    /// Meant for `Text`: the label is rendered three times — an invisible base
    /// that owns the width, a hidden full-width copy that measures, and the copy
    /// the reader sees — so the wrapped view has to be cheap and stateless.
    func marqueeOnHover(truncationMode: Text.TruncationMode = .middle) -> some View {
        modifier(MarqueeOnHover(truncationMode: truncationMode))
    }
}
