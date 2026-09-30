import SwiftUI

public enum CapsuleButtonPreset: Sendable {
    case small
    case regular
    case large

    var font: Font {
        switch self {
        case .small: DesignTokens.Typography.subheadline
        case .regular: DesignTokens.Typography.callout
        case .large: DesignTokens.Typography.body
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: DesignTokens.Spacing.sm
        case .regular: DesignTokens.Spacing.md
        case .large: DesignTokens.Spacing.lg
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: DesignTokens.Spacing.xs
        case .regular: 6
        case .large: DesignTokens.Spacing.sm
        }
    }
}

public struct CapsuleButtonStyle: ButtonStyle {
    public var tint: Color
    public var preset: CapsuleButtonPreset

    public init(tint: Color = DesignTokens.Colors.accent, preset: CapsuleButtonPreset = .regular) {
        self.tint = tint
        self.preset = preset
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, preset: preset)
    }

    /// Inner view so we can read `\.isEnabled` (ButtonStyle.Configuration doesn't expose it).
    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let preset: CapsuleButtonPreset
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let effectiveTint = isEnabled ? tint : DesignTokens.Colors.textSecondary
            configuration.label
                .font(preset.font)
                .foregroundStyle(effectiveTint)
                .padding(.horizontal, preset.horizontalPadding)
                .padding(.vertical, preset.verticalPadding)
                .background(Capsule().fill(effectiveTint.opacity(DesignTokens.Opacity.selectedFill)))
                .overlay(Capsule().strokeBorder(effectiveTint.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 0.5))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? DesignTokens.Opacity.dimmedIcon : 1.0) : DesignTokens.Opacity.dimmedContent)
        }
    }
}
