import SwiftUI

struct RAMScopePicker: View {
    @Binding var selection: String
    var maxWidth: CGFloat?


    init(selection: Binding<String>, maxWidth: CGFloat? = nil) {
        self._selection = selection
        self.maxWidth = maxWidth
    }

    var body: some View {
        GlassSegmentedPicker(
            selection: $selection,
            values: ["system", "app"],
            shell: .flat
        ) { value, isSelected in
            // Explicit LocalizedStringKey: a bare string ternary would type as
            // String and render verbatim, silently skipping the catalog.
            Text(value == "system" ? LocalizedStringKey("All") : LocalizedStringKey("App"), bundle: .main)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .accessibilityLabel(value == "system"
                    ? Text("Show whole-system memory usage", comment: "RAM scope toggle a11y label when scope is the whole system.")
                    : Text("Show this app's memory usage", comment: "RAM scope toggle a11y label when scope is the LiveWallpaper app only."))
        }
        .frame(maxWidth: maxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("RAM scope"))
    }
}
