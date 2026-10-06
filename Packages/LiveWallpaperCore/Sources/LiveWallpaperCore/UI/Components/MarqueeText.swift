import SwiftUI

/// An invisible text base owns the layout, so the scrolling copy cannot resize the card.
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

    private var overflow: CGFloat {
        max(0, contentHeight - windowHeight)
    }

    private var shouldScroll: Bool {
        isActive && !reduceMotion && windowHeight > 0 && overflow > 0.5
    }

    /// Distance is in the plan so a resize restarts the crawl; rounded to half a point
    /// so measurement jitter can't restart it every frame.
    private var plan: ScrollPlan {
        ScrollPlan(text: text, lineLimit: lineLimit, isScrolling: shouldScroll, distance: (overflow * 2).rounded() / 2)
    }

    private struct ScrollPlan: Equatable {
        let text: String
        let lineLimit: Int
        let isScrolling: Bool
        let distance: CGFloat
    }

    public var body: some View {
        Text(verbatim: text)
            .lineLimit(lineLimit, reservesSpace: true)
            .opacity(0)
            .accessibilityHidden(true)
            // `onGeometryChange`, not `GeometryReader` + `PreferenceKey`: no preference
            // reduced on every layout pass.
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
            .task(id: plan) { await restart(for: plan) }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: text))
    }

    private func restart(for plan: ScrollPlan) async {
        // Cancel the previous presentation animation without inheriting the
        // card's hover transition. The reading pause must precede the target
        // mutation: resetting and retargeting in one update coalesces them.
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard plan.isScrolling else { return }
        do {
            try await Task.sleep(for: .seconds(startDelay))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(
            .linear(duration: Double(plan.distance / speed))
                .repeatForever(autoreverses: true)
        ) {
            offset = -plan.distance
        }
    }
}
