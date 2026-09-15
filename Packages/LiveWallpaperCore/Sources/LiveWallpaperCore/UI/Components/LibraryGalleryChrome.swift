import SwiftUI

public struct LibraryStatusBar<Trailing: View>: View {
    private let summary: Text
    private let trailing: Trailing

    public init(summary: Text, @ViewBuilder trailing: () -> Trailing) {
        self.summary = summary
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack {
                summary
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Spacer(minLength: 0)
                    trailing
                }
            }
            .font(DesignTokens.Typography.metric)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.LibraryStatusBar.horizontalPadding)
            .padding(.vertical, DesignTokens.LibraryStatusBar.verticalPadding)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
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
}
