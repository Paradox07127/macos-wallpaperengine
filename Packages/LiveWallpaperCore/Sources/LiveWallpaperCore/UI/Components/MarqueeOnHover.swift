import SwiftUI

public enum MarqueeMetrics {
    /// Sub-pixel overflow is rounding noise, not text the reader is missing.
    public static let threshold: CGFloat = 1

    /// Points per second. Deliberately faster than `MarqueeText`'s 12 pt/s vertical crawl.
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

/// An invisible base owns the layout; `fixedSize` on the label itself would clamp
/// it to the row width and scroll the *truncated* string.
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

    /// Distance is in the plan so a resize restarts the crawl; rounded to half a
    /// point so measurement jitter can't restart it every frame.
    private var plan: ScrollPlan {
        ScrollPlan(isScrolling: shouldScroll, distance: (overflow * 2).rounded() / 2)
    }

    private struct ScrollPlan: Equatable {
        let isScrolling: Bool
        let distance: CGFloat
    }

    func body(content: Content) -> some View {
        // The hidden full-width copy mounts only while hovered; the crawl waits
        // `startDelay`, so measuring on hover-in is in time.
        content
            .lineLimit(1)
            .truncationMode(truncationMode)
            .opacity(isHovering ? 0 : 1)
            .accessibilityHidden(isHovering)
            // `onGeometryChange`, not `GeometryReader` + `PreferenceKey`: no preference tree
            // to reduce through on every layout pass.
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
    /// While hovered the label renders three times, so the wrapped view must be cheap
    /// and stateless. The multi-line card-title equivalent is `MarqueeText`.
    func marqueeOnHover(truncationMode: Text.TruncationMode = .middle) -> some View {
        modifier(MarqueeOnHover(truncationMode: truncationMode))
    }
}
