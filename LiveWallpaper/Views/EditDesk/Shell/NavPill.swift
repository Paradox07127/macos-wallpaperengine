import LiveWallpaperCore
import SwiftUI

struct NavPill: View {
    @Binding var selection: EditDeskRouter.Page
    let workshopAvailable: Bool

    private var items: [EditDeskRouter.Page] {
        workshopAvailable ? [.home, .library, .workshop, .settings] : [.home, .library, .settings]
    }

    var body: some View {
        GlassSegmentedPicker(selection: $selection, values: items, shell: .editDesk) { item, isSelected in
            Text(title(for: item))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(isSelected ? DesignTokens.EditDesk.Colors.textPrimary : DesignTokens.EditDesk.Colors.textSecondary)
        }
        .fixedSize()
    }

    private func title(for item: EditDeskRouter.Page) -> LocalizedStringKey {
        switch item {
        case .home: "Overview"
        case .library: "Wallpaper Library"
        case .workshop: "Workshop"
        case .settings: "Settings"
        }
    }
}
