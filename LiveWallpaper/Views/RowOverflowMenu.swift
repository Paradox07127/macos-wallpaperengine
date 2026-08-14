import SwiftUI

/// Shared hover ellipsis for 50pt list rows (`Row`, `SlotRow`).
struct RowOverflowMenu<Content: View>: View {
    let isHovering: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .opacity(isHovering ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(Text("More actions"))
    }
}
