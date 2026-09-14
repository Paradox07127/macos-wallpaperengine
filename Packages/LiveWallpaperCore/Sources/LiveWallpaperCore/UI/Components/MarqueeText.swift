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

    private var overflow: CGFloat { max(0, contentHeight - windowHeight) }
    private var shouldScroll: Bool { isActive && !reduceMotion && overflow > 0.5 }

    /// Distance is in the plan so a resize restarts the crawl; rounded to half a point
    /// so measurement jitter can't restart it every frame.
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
