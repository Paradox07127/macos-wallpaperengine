import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperPage: View {
    let router: EditDeskRouter

    @Environment(\.featureCatalog) private var featureCatalog
    /// The window's own content size, which the top bar's budget is measured against.
    @State private var stageSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {
            SystemWallpaperLibraryView(isEmbedded: true)
                .padding(.top, DesignTokens.EditDesk.Spacing.topBar)
            TopBar(
                page: Binding(get: { router.page }, set: { router.select($0) }),
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stageSize.width,
                status: nil
            )
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
    }
}
