import SwiftUI

struct DestructiveControlTint: ViewModifier {
    init() {}

    func body(content: Content) -> some View {
        content
            // No plate behind it: a red-tinted plate behind red text is same-hue on
            // same-hue and reads as low-contrast.
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .tint(DesignTokens.Colors.Status.danger)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    public func destructiveControlTint() -> some View {
        modifier(DestructiveControlTint())
    }
}
