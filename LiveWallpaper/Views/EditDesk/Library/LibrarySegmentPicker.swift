import LiveWallpaperCore
import SwiftUI

enum LibrarySegment: Hashable {
    case wallpapers, schemes, systemWallpaper
}

struct LibrarySegmentPicker: View {
    @Binding var selection: LibrarySegment

    private var values: [LibrarySegment] {
        if #available(macOS 26.0, *) {
            [.wallpapers, .schemes, .systemWallpaper]
        } else {
            [.wallpapers, .schemes]
        }
    }

    var body: some View {
        GlassSegmentedPicker(selection: $selection, values: values, shell: .editDesk) { segment, isSelected in
            Text(title(for: segment))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(isSelected ? DesignTokens.EditDesk.Colors.textPrimary : DesignTokens.EditDesk.Colors.textSecondary)
        }
        .fixedSize()
    }

    private func title(for segment: LibrarySegment) -> LocalizedStringKey {
        switch segment {
        case .wallpapers: "Wallpaper"
        case .schemes: "Schemes"
        case .systemWallpaper: "System Wallpaper"
        }
    }
}
