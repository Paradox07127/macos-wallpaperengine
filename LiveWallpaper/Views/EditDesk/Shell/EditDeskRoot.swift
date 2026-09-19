import LiveWallpaperCore
import SwiftUI

struct EditDeskRoot: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var router: EditDeskRouter?
    @AppStorage(EditDeskPreferences.background, store: .appScoped())
    private var backgroundRaw = EditDeskPreferences.backgroundDefault.rawValue
    #if !LITE_BUILD
    @State private var historicalFailure: WallpaperFailureSnapshot?
    @State private var historicalFailureDetails: WallpaperFailureSnapshot?
    #endif
    private let initialNavigation: Navigation?
    private let initialAddWallpaperPromptKind: String?

    init(initialNavigation: Navigation? = nil, initialAddWallpaperPromptKind: String? = nil) {
        self.initialNavigation = initialNavigation
        self.initialAddWallpaperPromptKind = initialAddWallpaperPromptKind
    }

    private var background: EditDeskBackground {
        EditDeskBackground(rawValue: backgroundRaw) ?? EditDeskPreferences.backgroundDefault
    }

    var body: some View {
        Group {
            if let router {
                @Bindable var router = router
                switch router.page {
                case .home, .library:
                    // One page: the library is the stage's p = 2 state, not a separate view.
                    HomePage(router: router)
                case .workshop:
                    #if !LITE_BUILD
                    PaneView()
                    #else
                    Color.clear
                    #endif
                case .settings:
                    HStack(spacing: 0) {
                        SettingsSidebar(
                            selection: $router.settingsSelection,
                            searchText: $router.settingsSearchText,
                            pendingSearchAnchor: $router.pendingSettingsSearchAnchor,
                            onBack: router.backFromSettings
                        )
                        .frame(width: SettingsWindowMetrics.sidebarColumnWidth)
                        Divider()
                        SettingsDetailContent(
                            selection: $router.settingsSelection,
                            pendingSearchAnchor: $router.pendingSettingsSearchAnchor
                        )
                    }
                }
            } else {
                Color.clear
            }
        }
        #if !LITE_BUILD
        .overlay(alignment: .bottomTrailing) {
            DownloadToastHost(
                visibleDisplayID: router?.page == .home ? router?.detailDisplayID : nil,
                onOpenFailure: openFailure
            )
            .padding(DesignTokens.Spacing.lg)
        }
        .infoOverlay(item: $historicalFailure) { failure, dismiss in
            VStack(spacing: 0) {
                WallpaperFailureView(
                    failure: failure,
                    isCurrentAttempt: false,
                    onShowDetails: { historicalFailureDetails = failure }
                )
                SheetFooterBar(primaryTitle: "Done", primaryAction: dismiss)
            }
            .frame(width: 600, height: 400)
        }
        .infoOverlay(item: $historicalFailureDetails) { failure, dismiss in
            WallpaperFailureDetails(failure: failure, onDismiss: dismiss)
        }
        #endif
        .background(EditDeskBackdrop(frosted: background == .frosted))
        .frame(minWidth: StageGeometry.minimumWindow.width, minHeight: StageGeometry.minimumWindow.height)
        .onAppear {
            guard router == nil else { return }
            router = EditDeskRouter(
                initialNavigation: initialNavigation,
                initialAddWallpaperPromptKind: initialAddWallpaperPromptKind,
                isWorkshopAvailable: { [featureCatalog] in featureCatalog.isEnabled(.wpeImport) }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGeneralSettings)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsSection)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .openAppleAerials)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .promptAddWallpaper)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { router?.handle($0) }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in
            router?.screensRefreshed(availableDisplayIDs: screenManager.screens.map(\.id))
        }
    }

    #if !LITE_BUILD
    private func openFailure(_ failure: WallpaperFailureSnapshot, screenID: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == screenID }),
              screenManager.wallpaperLoads.attempt(for: screen)?.id == failure.id else {
            historicalFailure = failure
            return
        }
        screenManager.inspectWallpaperAttempt(true, for: screen)
        router?.showDetail(screenID)
        NotificationCenter.default.post(name: .selectScreenInSettings, object: nil, userInfo: ["screenID": screenID, "failureID": failure.id])
    }
    #endif
}
