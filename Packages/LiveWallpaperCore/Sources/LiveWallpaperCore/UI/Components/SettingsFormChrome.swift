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
            .frame(minWidth: minWidth, minHeight: minHeight)
            // Two frames on purpose: the first bounds the form, the second re-expands
            // the slot so the bounded form centers and the background still fills it.
            .frame(maxWidth: DesignTokens.Settings.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.Colors.pageBackground)
    }
}

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
