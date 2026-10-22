#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

enum WPEPropertyRowIcon {
    static func symbol(for type: WallpaperEngineProjectPropertySchema.PropertyType) -> String {
        switch type {
        case .bool: "switch.2"
        case .slider: "slider.horizontal.3"
        case .combo: "list.bullet"
        case .color: "paintpalette"
        case .textinput: "character.cursor.ibeam"
        case .file: "doc.badge.plus"
        case .directory: "folder.badge.plus"
        case .sceneTexture: "photo.badge.plus"
        case .userShortcut: "bolt.circle"
        case .group, .text, .unsupported: "questionmark"
        }
    }
}

struct WPEProjectComboPicker: View {
    let property: WallpaperEngineProjectPropertySchema.Property
    let currentValue: WallpaperEngineProjectPropertyValue
    @Binding var selection: WallpaperEngineProjectPropertyValue
    let title: String
    let displayLabel: (String) -> String

    var body: some View {
        if property.options.isEmpty {
            Text(verbatim: currentValue.stringValue)
                .font(DesignTokens.Typography.code)
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: $selection) {
                if !property.options.contains(where: { $0.value == currentValue }) {
                    Text(verbatim: "·  \(currentValue.stringValue)")
                        .tag(currentValue)
                }
                ForEach(property.options) { option in
                    Text(verbatim: displayLabel(option.displayLabel))
                        .tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // Match the row title's priority while letting unbounded author labels truncate.
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 96, alignment: .trailing)
            .layoutPriority(1)
            .accessibilityLabel(title)
        }
    }
}

/// Author-supplied strings (`.group` header / `.text` body) already routed
/// through the `project.json` localization map at parse time.
struct WPEProjectTextBlock: View {
    let text: String
    let isHeader: Bool

    var body: some View {
        Text(verbatim: text)
            .font(isHeader ? DesignTokens.Typography.sectionTitle : DesignTokens.Typography.body)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isHeader ? 2 : 1)
    }
}

struct WPEProjectNotice: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
