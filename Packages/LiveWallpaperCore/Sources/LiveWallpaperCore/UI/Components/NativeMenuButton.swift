import SwiftUI

/// Native menu tracking with a SwiftUI trigger, so artwork labels retain their colour
/// and the whole visual button remains clickable. Borderless AppKit menus recolour labels.
public struct NativeMenuButton<Content: View, Label: View>: View {
    private let toolbarItem: Bool
    private let content: Content
    private let label: Label
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter toolbarItem: The trigger sits in a `GlassToolbarGroup` and draws its keys' hover and press plate.
    public init(toolbarItem: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.toolbarItem = toolbarItem
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        styledMenu
            .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabledContent)
    }

    @ViewBuilder
    private var styledMenu: some View {
        let menu = Menu { content } label: { label }
            .menuStyle(.button)
            .menuIndicator(.hidden)
        if toolbarItem {
            menu.buttonStyle(ToolbarMenuTriggerStyle())
        } else {
            menu.buttonStyle(.plain)
        }
    }
}

private struct ToolbarMenuTriggerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TriggerBody(configuration: configuration)
    }

    private struct TriggerBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(GlassToolbarItemPlate(hovered: hovered, pressed: configuration.isPressed))
                .contentShape(Capsule())
                .onHover { hovered = $0 }
        }
    }
}
