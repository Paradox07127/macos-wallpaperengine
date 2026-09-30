import SwiftUI

/// Choice rows in a custom popover follow the system menu's blue hover highlight.
/// Keep this off input forms and slider panels, whose buttons have separate roles.
public struct PopupMenuOptionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(DesignTokens.Typography.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .foregroundStyle(highlighted ? DesignTokens.Colors.onAccentFill
                : (configuration.role == .destructive ? DesignTokens.Colors.Status.danger : DesignTokens.Colors.textPrimary))
            .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabledContent)
            .background(highlighted ? DesignTokens.Colors.accent : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

public extension View {
    func popupMenuOptions(width: CGFloat) -> some View {
        buttonStyle(PopupMenuOptionStyle())
            .padding(DesignTokens.Spacing.xs)
            .frame(width: width)
            .presentationCompactAdaptation(.popover)
    }
}
