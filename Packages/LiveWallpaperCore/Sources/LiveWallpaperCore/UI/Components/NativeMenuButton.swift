import SwiftUI

/// Native menu tracking with a SwiftUI trigger, so artwork labels retain their colour
/// and the whole visual button remains clickable. Borderless AppKit menus recolour labels.
public struct NativeMenuButton<Content: View, Label: View>: View {
    private let content: Content
    private let label: Label
    @Environment(\.isEnabled) private var isEnabled

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Menu { content } label: { label }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabledContent)
    }
}
