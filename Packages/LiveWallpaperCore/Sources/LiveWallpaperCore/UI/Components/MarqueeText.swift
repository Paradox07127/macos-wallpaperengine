import SwiftUI

/// A fixed two-line title window. The text wraps normally; only when it still
/// doesn't fit does hovering scroll it vertically to reveal the rest.
///
/// The sizing base is a plain `Text` with `reservesSpace` — the visible copy
/// rides in an `overlay`, which never resizes its base. That is the whole point:
/// a title must never widen or heighten its card, or a grid row's cards start
/// overlapping each other and the sidebar.
///
/// Scrolling is hover-gated because a grid of titles all crawling at once is
/// distracting and needless animation work; Reduce Motion turns it off and the
/// text simply truncates.
public struct MarqueeText: View {
    private let text: String
    private let lineLimit: Int
    private let isActive: Bool
    /// Points per second. A line is ~16pt, so this reveals roughly one line
    /// every 1.3 seconds — slow enough to read on the way past.
    private let speed: CGFloat = 12
    /// Let the reader see what already fits before anything moves.
    private let startDelay: TimeInterval = 0.7

    @State private var contentHeight: CGFloat = 0
    @State private var windowHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String, lineLimit: Int = 2, isActive: Bool) {
        self.text = text
        self.lineLimit = lineLimit
        self.isActive = isActive
    }

    private var overflow: CGFloat { max(0, contentHeight - windowHeight) }
    private var shouldScroll: Bool { isActive && !reduceMotion && overflow > 0.5 }

    /// The crawl restarts whenever this changes, not just when scrolling turns on
    /// or off: resizing the window changes how far the text has to travel while
    /// the pointer stays put, and an animation still aiming at the old distance
    /// would stop short of the last line. Rounded to half a point so measurement
    /// jitter can't restart it every frame.
    private var plan: ScrollPlan {
        ScrollPlan(isScrolling: shouldScroll, distance: (overflow * 2).rounded() / 2)
    }

    private struct ScrollPlan: Equatable {
        let isScrolling: Bool
        let distance: CGFloat
    }

    public var body: some View {
        Text(verbatim: text)
            .lineLimit(lineLimit, reservesSpace: true)
            .opacity(0)
            .accessibilityHidden(true)
            // `onGeometryChange` rather than `GeometryReader` + `PreferenceKey`:
            // a grid page carries one of these per card, and this reports the
            // height only when it changes instead of reducing a preference on
            // every layout pass. macOS 13+, so no availability gate.
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { windowHeight = $0 }
            .overlay(alignment: .top) {
                Text(verbatim: text)
                    // Wraps at the base's width and grows downward; the base
                    // still owns the layout, so nothing here can widen the card.
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                    .offset(y: offset)
                    .accessibilityHidden(true)
            }
            .clipped()
            .onChange(of: plan) { _, _ in restart() }
            .onChange(of: text) { _, _ in offset = 0 }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: text))
    }

    private func restart() {
        guard shouldScroll else {
            guard offset != 0 else { return }
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
            return
        }
        offset = 0
        withAnimation(
            .linear(duration: Double(overflow / speed))
                .delay(startDelay)
                .repeatForever(autoreverses: true)
        ) {
            offset = -overflow
        }
    }
}
