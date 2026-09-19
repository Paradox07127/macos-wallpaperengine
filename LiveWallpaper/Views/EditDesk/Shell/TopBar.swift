import LiveWallpaperCore
import SwiftUI

/// SCREENS S1: traffic lights are the system's own, this just reserves their space
/// (x 16 + 3×12pt dots + 2×8pt gaps).
struct TopBar: View {
    @Binding var page: EditDeskRouter.Page
    let workshopAvailable: Bool
    @Binding var searchText: String
    let showsSearch: Bool
    let status: StatusCapsule

    private static let trafficLightReserve: CGFloat = 68
    private static let searchFieldWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.trafficLightReserve)
            Spacer(minLength: 0)
            trailingContent
        }
        .overlay(alignment: .center) {
            NavPill(selection: $page, workshopAvailable: workshopAvailable)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: DesignTokens.EditDesk.Spacing.topBar)
    }

    private var trailingContent: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            if showsSearch {
                LibrarySearchField(
                    text: $searchText,
                    prompt: "Search · Tags · Author",
                    minWidth: Self.searchFieldWidth,
                    idealWidth: Self.searchFieldWidth,
                    maxWidth: Self.searchFieldWidth
                )
            }
            status
        }
    }
}
