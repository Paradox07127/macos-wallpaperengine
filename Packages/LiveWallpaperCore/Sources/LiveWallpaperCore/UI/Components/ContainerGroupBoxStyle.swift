import SwiftUI

public struct ContainerGroupBoxStyle: GroupBoxStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                .strokeBorder(
                    DesignTokens.Colors.separator.opacity(0.55),
                    lineWidth: DesignTokens.Card.strokeWidth
                )
        )
    }
}
