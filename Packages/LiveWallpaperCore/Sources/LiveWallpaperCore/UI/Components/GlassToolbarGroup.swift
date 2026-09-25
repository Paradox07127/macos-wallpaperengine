import SwiftUI

public enum GlassToolbarMetrics {
    /// A macOS 26+ toolbar glass group (`NSToolbarPlatterView`) measures 36pt tall on macOS 27.
    public static let height: CGFloat = 36
    /// A fixed `ToolbarSpacer` between two native groups.
    public static let groupSpacing = DesignTokens.Spacing.sm
    /// Kept below `groupSpacing`: a container spacing at or above the gap melts neighbouring capsules at rest.
    public static let containerSpacing = DesignTokens.Spacing.xs
}

/// Icon actions sharing one glass capsule, the way a macOS 26 toolbar groups its items.
public struct GlassToolbarGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .adaptiveGlassSurface(.capsule)
        .accessibilityElement(children: .contain)
    }
}

/// One icon action inside a `GlassToolbarGroup`; a destructive role draws a red glyph, never a plate.
public struct GlassToolbarItem: View {
    private let systemImage: String
    private let role: ButtonRole?
    private let action: () -> Void

    public init(_ systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.body)
                .imageScale(.large)
        }
        .buttonStyle(GlassToolbarItemStyle(destructive: role == .destructive))
    }
}

private struct GlassToolbarItemStyle: ButtonStyle {
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        ItemBody(configuration: configuration, destructive: destructive)
    }

    private struct ItemBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.appearsActive) private var appearsActive
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(glyph)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .frame(minWidth: GlassToolbarMetrics.height, minHeight: GlassToolbarMetrics.height)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(fillOpacity))
                        .padding(DesignTokens.Spacing.xxs)
                )
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .onHover { hovered = $0 }
        }

        private var glyph: AnyShapeStyle {
            guard isEnabled, appearsActive else { return AnyShapeStyle(.tertiary) }
            return destructive ? AnyShapeStyle(DesignTokens.Colors.Status.danger) : AnyShapeStyle(.primary)
        }

        private var fillOpacity: Double {
            if configuration.isPressed {
                return DesignTokens.Opacity.activeFill
            }
            return hovered && isEnabled ? DesignTokens.Opacity.hoverFill : 0
        }
    }
}
