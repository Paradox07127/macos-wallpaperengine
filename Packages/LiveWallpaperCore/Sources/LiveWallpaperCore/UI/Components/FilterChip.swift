import SwiftUI

/// Shared capsule backing for filter chips: selected chips get a tinted Liquid
/// Glass capsule with an accent ring (selection stays unmistakable), deselected
/// chips keep a quiet flat fill. The single source of truth for chip chrome —
/// bespoke twins of this recipe drifted (0.07 vs 0.04 fills) before it existed.
public struct FilterChipBackground: ViewModifier {
    let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func body(content: Content) -> some View {
        if isSelected {
            content
                .adaptiveGlassSurface(.capsule, tint: .accentColor, interactive: true)
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
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
