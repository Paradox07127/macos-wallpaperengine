import SwiftUI
import AppKit

extension View {
    public func settingsFormChrome(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> some View {
        modifier(SettingsFormChrome(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct SettingsFormChrome: ViewModifier {
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, DesignTokens.Settings.formHorizontalMargin, for: .scrollContent)
            .contentMargins(.vertical, DesignTokens.Settings.formVerticalMargin, for: .scrollContent)
            .background(DesignTokens.Colors.pageBackground)
            .frame(minWidth: minWidth, minHeight: minHeight)
    }
}

/// Shared chrome for lightweight settings-card popovers: one padding standard
/// and the popover presentation adaptation, with a per-popover content width.
/// Three popovers each carried their own padding (20/16/14) before this.
public struct SettingsPopoverChrome: ViewModifier {
    let width: CGFloat

    public init(width: CGFloat) {
        self.width = width
    }

    public func body(content: Content) -> some View {
        content
            .padding(DesignTokens.Spacing.lg)
            .frame(width: width)
            .presentationCompactAdaptation(.popover)
    }
}

extension View {
    public func settingsPopoverChrome(width: CGFloat) -> some View {
        modifier(SettingsPopoverChrome(width: width))
    }
}
