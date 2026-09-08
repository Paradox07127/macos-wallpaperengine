import SwiftUI

/// Shared filter capsule with a fill and ring for selection.
struct FilterChipBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .background(Capsule().fill(Color.accentColor.opacity(DesignTokens.Opacity.selectedFill)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(DesignTokens.Opacity.strongStroke), lineWidth: 1))
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(DesignTokens.Opacity.activeFill), lineWidth: 0.5))
        }
    }
}

extension View {
    public func filterChipBackground(isSelected: Bool) -> some View {
        modifier(FilterChipBackground(isSelected: isSelected))
    }
}

/// Translucent filter pill for toolbar-style control rows.
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
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .filterChipBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
