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

    /// macOS 26+: the content scrolls under the bars and fades at their soft edges; earlier: the bars stack above and below it.
    @ViewBuilder
    func libraryScrollBars(
        @ViewBuilder top: () -> some View,
        @ViewBuilder bottom: () -> some View
    ) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .safeAreaBar(edge: .top, spacing: 0, content: top)
                .safeAreaBar(edge: .bottom, spacing: 0, content: bottom)
                .clipped()
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
            scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0, content: bottom)
                .clipped()
        } else {
            VStack(spacing: 0) {
                self
                bottom()
            }
        }
    }
}
