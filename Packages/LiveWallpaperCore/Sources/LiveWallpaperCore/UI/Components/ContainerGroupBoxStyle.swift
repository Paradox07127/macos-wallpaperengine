import SwiftUI

public struct ContainerGroupBoxStyle: GroupBoxStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            configuration.label
                .font(DesignTokens.Typography.sectionTitle)
            configuration.content
        }
        .padding(.horizontal, DesignTokens.GroupBox.inset)
        .padding(.vertical, DesignTokens.GroupBox.inset)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                .strokeBorder(
                    DesignTokens.Colors.separator.opacity(DesignTokens.Opacity.strongStroke),
                    lineWidth: DesignTokens.Card.strokeWidth
                )
        )
    }
}
