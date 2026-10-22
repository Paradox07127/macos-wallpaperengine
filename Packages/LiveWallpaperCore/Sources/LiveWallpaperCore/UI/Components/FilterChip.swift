import SwiftUI

struct FilterChipBackground: ViewModifier {
    let isSelected: Bool
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(isSelected
                    ? DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.selectedFill)
                    : DesignTokens.Colors.textPrimary.opacity(0.04))
                Capsule().fill(DesignTokens.Colors.textPrimary.opacity(isHovered ? DesignTokens.Opacity.hoverFill : 0))
            }
            .overlay(Capsule().strokeBorder(
                isSelected
                    ? DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.strongStroke)
                    : DesignTokens.Colors.textPrimary.opacity(DesignTokens.Opacity.activeFill),
                lineWidth: isSelected ? 1 : 0.5
            ))
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

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
                .modifier(FilterChipBackground(isSelected: isSelected, isHovered: isHovered))
        }
        .buttonStyle(FilterChipPressStyle(reduceMotion: reduceMotion))
        .onHover { isHovered = $0 }
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isSelected)
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FilterChipPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.15)), value: configuration.isPressed)
    }
}
