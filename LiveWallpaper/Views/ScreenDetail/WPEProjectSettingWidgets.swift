#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Per-control-type glyph for WPE custom-setting rows, so author properties
/// share the app-wide `SettingRow` geometry (icon block + title + control)
/// instead of a bespoke icon-less row.
enum WPEPropertyRowIcon {
    static func symbol(for type: WallpaperEngineProjectPropertySchema.PropertyType) -> String {
        switch type {
        case .bool:        return "switch.2"
        case .slider:      return "slider.horizontal.3"
        case .combo:       return "list.bullet"
        case .color:       return "paintpalette"
        case .textinput:   return "character.cursor.ibeam"
        case .file:        return "doc.badge.plus"
        case .directory:   return "folder.badge.plus"
        case .group, .text, .unsupported:
            return "questionmark"
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
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isHeader ? 2 : 1)
    }
}

struct WPEProjectNotice: View {
    let icon: String
    /// App-supplied LocalizedStringKey — gate notices live in source
    /// and flow through the four bundled languages.
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
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
