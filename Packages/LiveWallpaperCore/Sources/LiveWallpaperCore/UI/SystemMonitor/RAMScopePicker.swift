import SwiftUI

public extension PowerMonitor.PowerSource {
    var iconName: String {
        switch self {
        case let .battery(level):
            if level <= 0.1 {
                return "battery.0"
            }
            if level <= 0.25 {
                return "battery.25"
            }
            if level <= 0.5 {
                return "battery.50"
            }
            if level <= 0.75 {
                return "battery.75"
            }
            return "battery.100"
        case .external:
            return "bolt.fill"
        }
    }
}

public struct RAMScopePicker: View {
    @Binding var selection: String

    public init(selection: Binding<String>) {
        _selection = selection
    }

    public var body: some View {
        GlassSegmentedPicker(
            selection: $selection,
            values: ["system", "app"],
            shell: .flat
        ) { value, isSelected in
            // Explicit LocalizedStringKey: a bare string ternary would type as
            // String and render verbatim, silently skipping the catalog.
            Text(value == "system" ? LocalizedStringKey("System") : LocalizedStringKey("App"))
                .font(isSelected
                    ? DesignTokens.Typography.captionEmphasized
                    : DesignTokens.Typography.caption)
                .accessibilityLabel(value == "system"
                    ? Text("Show whole-system CPU and memory usage", comment: "Status panel scope toggle a11y label when scope is the whole system.")
                    : Text("Show this app's CPU and memory usage", comment: "Status panel scope toggle a11y label when scope is the LiveWallpaper app only."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage scope"))
    }
}
