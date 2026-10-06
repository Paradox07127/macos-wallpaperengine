import SwiftUI

struct FilterChipBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .background(Capsule().fill(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.selectedFill)))
                .overlay(Capsule().strokeBorder(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.strongStroke), lineWidth: 1))
        } else {
            content
                .background(Capsule().fill(DesignTokens.Colors.textPrimary.opacity(0.04)))
                .overlay(Capsule().strokeBorder(DesignTokens.Colors.textPrimary.opacity(DesignTokens.Opacity.activeFill), lineWidth: 0.5))
        }
    }
}

extension View {
    public func filterChipBackground(isSelected: Bool) -> some View {
        modifier(FilterChipBackground(isSelected: isSelected))
    }
}

public struct FilterChip: View {
    private let title: Text
    private let isSelected: Bool
    private let action: () -> Void

    public init(title: Text, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            title
                .font(DesignTokens.EditDesk.Typography.body)
                .lineLimit(1)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(minHeight: DesignTokens.LibraryFilterBar.controlHeight)
                .filterChipBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
