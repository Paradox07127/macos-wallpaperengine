import LiveWallpaperCore
import SwiftUI

/// SCREENS S1: traffic lights are the system's own, this just reserves their space
/// (x 16 + 3×12pt dots + 2×8pt gaps).
struct TopBar<Trailing: View>: View {
    @Binding var page: EditDeskRouter.Page
    let workshopAvailable: Bool
    @Binding var searchText: String
    let showsSearch: Bool
    /// The window's own width; the onboarding capsule drops its label when the row gets tight.
    let windowWidth: CGFloat
    /// nil on pages that carry a control of their own instead (S8's Steam menu).
    let status: StatusCapsule?
    @ViewBuilder let trailing: () -> Trailing

    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?

    /// The two the budget cannot derive: the pill is sized by its own localized titles and the
    /// status capsule by its content. Measured, so no number here restates theirs.
    @State private var pillWidth: CGFloat = 0
    @State private var statusWidth: CGFloat = 0

    private static var trafficLightReserve: CGFloat {
        68
    }

    private var budget: TopBarBudget.Layout {
        TopBarBudget.layout(
            windowWidth: windowWidth, pillWidth: pillWidth, showsSearch: showsSearch,
            capsuleWidth: OnboardingCapsuleFit.width(
                progress: progress, windowWidth: windowWidth, showsSearch: showsSearch
            ),
            statusWidth: statusWidth
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.trafficLightReserve)
            Spacer(minLength: 0)
            trailingContent
        }
        .overlay(alignment: .center) {
            NavPill(selection: $page, workshopAvailable: workshopAvailable)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { pillWidth = $0 }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: DesignTokens.EditDesk.Spacing.topBar)
        .background(WindowDragRegion())
    }

    private var trailingContent: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            if showsSearch {
                LibrarySearchField(
                    text: $searchText,
                    prompt: workshopAvailable ? "Search by name or tag" : "Search by name",
                    minWidth: budget.searchWidth,
                    idealWidth: budget.searchWidth,
                    maxWidth: budget.searchWidth
                )
            }
            if budget.showsCapsule {
                OnboardingCapsule(windowWidth: windowWidth, showsSearch: showsSearch)
            }
            trailing()
            status
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { statusWidth = $0 }
        }
    }
}

extension TopBar where Trailing == EmptyView {
    init(
        page: Binding<EditDeskRouter.Page>,
        workshopAvailable: Bool,
        searchText: Binding<String>,
        showsSearch: Bool,
        windowWidth: CGFloat,
        status: StatusCapsule?
    ) {
        self.init(
            page: page, workshopAvailable: workshopAvailable, searchText: searchText,
            showsSearch: showsSearch, windowWidth: windowWidth, status: status, trailing: { EmptyView() }
        )
    }
}
