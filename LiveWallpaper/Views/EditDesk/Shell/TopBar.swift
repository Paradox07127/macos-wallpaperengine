import LiveWallpaperCore
import SwiftUI

/// SCREENS S1: traffic lights are the system's own, this just reserves their space
/// (x 16 + 3×12pt dots + 2×8pt gaps).
struct TopBar<Trailing: View>: View {
    @Binding var page: EditDeskRouter.Page
    let workshopAvailable: Bool
    @Binding var searchText: String
    let showsSearch: Bool
    /// nil on pages that carry a control of their own instead (S8's Steam menu).
    let status: StatusCapsule?
    @ViewBuilder let trailing: () -> Trailing

    private static var trafficLightReserve: CGFloat {
        68
    }

    private static var searchFieldWidth: CGFloat {
        220
    }

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
            trailing()
            status
        }
    }
}

extension TopBar where Trailing == EmptyView {
    init(
        page: Binding<EditDeskRouter.Page>,
        workshopAvailable: Bool,
        searchText: Binding<String>,
        showsSearch: Bool,
        status: StatusCapsule?
    ) {
        self.init(
            page: page, workshopAvailable: workshopAvailable, searchText: searchText,
            showsSearch: showsSearch, status: status, trailing: { EmptyView() }
        )
    }
}
