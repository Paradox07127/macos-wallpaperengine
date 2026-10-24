import SwiftUI

public enum GlassToolbarMetrics {
    /// `.regular` is a native toolbar group; `.compact` sits level with a 28pt `GlassIconButton`, as in a detail modal's title row.
    public enum Size: Sendable {
        case regular, compact

        /// The capsule's height and each key's minimum width.
        public var height: CGFloat {
            switch self {
            case .regular: GlassToolbarMetrics.height
            case .compact: DesignTokens.iconButtonDiameter(.large)
            }
        }
    }

    /// A macOS 26+ toolbar glass group (`NSToolbarPlatterView`) measures 36pt tall on macOS 27.
    public static let height: CGFloat = 36
    /// A fixed `ToolbarSpacer` between two native groups.
    public static let groupSpacing = DesignTokens.Spacing.sm
    /// Kept below `groupSpacing`: a container spacing at or above the gap melts neighbouring capsules at rest.
    public static let containerSpacing = DesignTokens.Spacing.xs
}

extension EnvironmentValues {
    @Entry var glassToolbarSize: GlassToolbarMetrics.Size = .regular
}

/// Icon actions sharing one glass capsule, the way a macOS 26 toolbar groups its items.
public struct GlassToolbarGroup<Content: View>: View {
    private let size: GlassToolbarMetrics.Size
    private let content: Content

    public init(size: GlassToolbarMetrics.Size = .regular, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .environment(\.glassToolbarSize, size)
        .adaptiveGlassSurface(.capsule)
        .accessibilityElement(children: .contain)
    }
}

/// One icon action inside a `GlassToolbarGroup`; a destructive role draws a red glyph, never a plate.
public struct GlassToolbarItem: View {
    private let systemImage: String
    private let tint: Color?
    private let role: ButtonRole?
    private let action: () -> Void

    @Environment(\.glassToolbarSize) private var size

    /// `tint` colours the glyph while it is enabled, such as a filled bookmark; nil keeps the role's colour.
    public init(_ systemImage: String, tint: Color? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.body)
                .imageScale(size == .compact ? .medium : .large)
        }
        .buttonStyle(GlassToolbarItemStyle(destructive: role == .destructive, tint: tint, size: size))
    }
}

private struct GlassToolbarItemStyle: ButtonStyle {
    let destructive: Bool
    let tint: Color?
    let size: GlassToolbarMetrics.Size

    func makeBody(configuration: Configuration) -> some View {
        ItemBody(configuration: configuration, destructive: destructive, tint: tint, size: size)
    }

    private struct ItemBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        let tint: Color?
        let size: GlassToolbarMetrics.Size
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.appearsActive) private var appearsActive
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(glyph)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .frame(minWidth: size.height, minHeight: size.height)
                .background(GlassToolbarItemPlate(hovered: hovered, pressed: configuration.isPressed))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .onHover { hovered = $0 }
        }

        private var glyph: AnyShapeStyle {
            guard isEnabled, appearsActive else { return AnyShapeStyle(.tertiary) }
            if let tint {
                return AnyShapeStyle(tint)
            }
            return destructive ? AnyShapeStyle(DesignTokens.Colors.Status.danger) : AnyShapeStyle(.primary)
        }
    }
}

/// The hover and press plate behind a key in a `GlassToolbarGroup`; a menu trigger in the group draws the same one.
public struct GlassToolbarItemPlate: View {
    private let hovered: Bool
    private let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(hovered: Bool, pressed: Bool) {
        self.hovered = hovered
        self.pressed = pressed
    }

    public var body: some View {
        Capsule()
            .fill(DesignTokens.Colors.textPrimary.opacity(fillOpacity))
            .padding(DesignTokens.Spacing.xxs)
    }

    private var fillOpacity: Double {
        if pressed {
            return DesignTokens.Opacity.activeFill
        }
        return hovered && isEnabled ? DesignTokens.Opacity.hoverFill : 0
    }
}
