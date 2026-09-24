import LiveWallpaperCore
import SwiftUI

struct NavPill: View {
    @Binding var selection: EditDeskRouter.Page
    let workshopAvailable: Bool

    static func items(workshopAvailable: Bool, systemWallpaperAvailable: Bool) -> [EditDeskRouter.Page] {
        [.home, .library, .schemes]
            + (systemWallpaperAvailable ? [.systemWallpaper] : [])
            + (workshopAvailable ? [.workshop] : [])
            + [.settings]
    }

    var body: some View {
        GlassSegmentedPicker(
            selection: $selection,
            values: Self.items(
                workshopAvailable: workshopAvailable, systemWallpaperAvailable: EditDeskRouter.systemWallpaperSupported
            ),
            shell: .editDesk
        ) { item, isSelected in
            Text(Self.title(for: item))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(isSelected ? DesignTokens.EditDesk.Colors.textPrimary : DesignTokens.EditDesk.Colors.textSecondary)
        }
        .fixedSize()
    }

    static func title(for item: EditDeskRouter.Page) -> LocalizedStringKey {
        switch item {
        case .home: "Overview"
        case .library: "Wallpaper Library"
        case .schemes: "Schemes"
        case .systemWallpaper: "System Wallpaper"
        case .workshop: "Workshop"
        case .settings: "Settings"
        }
    }
}
