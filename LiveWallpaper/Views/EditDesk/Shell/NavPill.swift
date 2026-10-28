import LiveWallpaperCore
import SwiftUI

struct NavPill: View {
    @Binding var selection: EditDeskRouter.Page
    let workshopAvailable: Bool

    static func items(workshopAvailable: Bool, systemWallpaperAvailable: Bool) -> [EditDeskRouter.Page] {
        var items: [EditDeskRouter.Page] = [.home, .library, .schemes]
        #if !MAS_BUILD
        if systemWallpaperAvailable {
            items.append(.systemWallpaper)
        }
        #endif
        return items + (workshopAvailable ? [.workshop] : []) + [.settings]
    }

    var body: some View {
        GlassSegmentedPicker(
            selection: $selection,
            values: Self.items(
                workshopAvailable: workshopAvailable, systemWallpaperAvailable: EditDeskRouter.systemWallpaperSupported
            ),
            shell: .editDesk
        ) { item, _ in
            let label = Text(Self.title(for: item))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            if item == .schemes {
                label
                    .help(Text("Display setups you saved"))
                    .accessibilityHint(Text("Display setups you saved"))
            } else {
                label
            }
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
