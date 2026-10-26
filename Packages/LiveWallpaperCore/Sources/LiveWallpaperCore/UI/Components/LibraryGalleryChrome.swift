import SwiftUI

public struct LibraryStatusBar<Trailing: View>: View {
    private let summary: Text
    private let trailing: Trailing

    public init(summary: Text, @ViewBuilder trailing: () -> Trailing) {
        self.summary = summary
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            summary
            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                trailing
            }
        }
        .font(DesignTokens.Typography.metric)
        .foregroundStyle(DesignTokens.Colors.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.LibraryStatusBar.horizontalPadding)
        .padding(.vertical, DesignTokens.LibraryStatusBar.verticalPadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .atlasRole("LibraryStatusBar")
    }
}

public extension LibraryStatusBar where Trailing == EmptyView {
    init(summary: Text) {
        self.init(summary: summary) { EmptyView() }
    }
}

public extension View {
    func libraryGridPadding() -> some View {
        padding(.horizontal, DesignTokens.LibraryGrid.horizontalPadding)
            .padding(.vertical, DesignTokens.LibraryGrid.verticalPadding)
    }

    /// macOS 26+: the content scrolls under the bars and fades out beneath them, so the bars draw no background;
    /// earlier: the bars stack above and below it.
    @ViewBuilder
    func libraryScrollBars(
        @ViewBuilder top: () -> some View,
        @ViewBuilder bottom: () -> some View
    ) -> some View {
        if #available(macOS 26.0, *) {
            modifier(LibraryScrollBars(top: top(), bottom: bottom()))
        } else {
            VStack(spacing: 0) {
                top()
                self
                bottom()
            }
        }
    }

    /// The footer-only form of `libraryScrollBars(top:bottom:)`.
    @ViewBuilder
    func libraryScrollBars(@ViewBuilder bottom: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            modifier(LibraryScrollBars(top: EmptyView(), bottom: bottom()))
        } else {
            VStack(spacing: 0) {
                self
                bottom()
            }
        }
    }
}

private struct LibraryScrollBars<Top: View, Bottom: View>: ViewModifier {
    let top: Top
    let bottom: Bottom
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // The mask keeps to the safe area between the bars, then reaches out by their heights; filling the
            // whole frame instead would cover the title-bar strip the scroll view extends under.
            .mask {
                VStack(spacing: 0) {
                    fade(under: topHeight, from: .top)
                    Color.black
                    fade(under: bottomHeight, from: .bottom)
                }
                .padding(.top, -topHeight)
                .padding(.bottom, -bottomHeight)
            }
            // Measured through a stack: the modifier on a bare EmptyView makes the inset take the whole height.
            // The shape stops clicks in a bar's gaps; without it they reach the faded cards beneath.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) { top }
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { topHeight = $0 }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) { bottom }
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottomHeight = $0 }
            }
    }

    /// Clear at the outer edge, nearly clear at the bar's inner edge so its controls stay legible, and opaque one
    /// grid inset further in, where cards at rest begin.
    @ViewBuilder
    private func fade(under barHeight: CGFloat, from edge: VerticalEdge) -> some View {
        if barHeight > 0 {
            let height = barHeight + DesignTokens.LibraryGrid.verticalPadding
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.2), location: barHeight / height),
                    .init(color: .black, location: 1),
                ],
                startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )
            .frame(height: height)
        }
    }
}
