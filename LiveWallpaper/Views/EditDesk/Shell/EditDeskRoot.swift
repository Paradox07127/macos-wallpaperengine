import AppKit
import LiveWallpaperCore
import SwiftUI

struct EditDeskRoot: View {
    static let restartOnboardingNotification = Notification.Name("EditDeskRestartOnboarding")
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var router: EditDeskRouter?
    @State private var pageGuide = PageGuideSession()
    @State private var progress: OnboardingProgress?
    /// One centre for every page: `HomePage` is not on the tree while Workshop is showing.
    @State private var toasts = EditDeskToastCenter()
    /// The window's undo history; it goes with the window, so closing it empties the history.
    @State private var undo: EditDeskUndoStack?
    /// Held by the window rather than `HomePage`, which other pages unmount: the library's chip, search
    /// and sort are still set when it comes back.
    @State private var library: SavedLibraryModel?
    @AppStorage(EditDeskPreferences.background, store: .appScoped())
    private var backgroundRaw = EditDeskPreferences.backgroundDefault.rawValue
    @AppStorage(LibraryTileSize.preferencesKey, store: .appScoped())
    private var libraryTileSizeRaw = LibraryTileSize.defaultSize.rawValue
    #if !LITE_BUILD
    @Environment(WorkshopServices.self) private var workshopServices
    @Environment(SteamCMDDoctorService.self) private var steamDoctor
    @State private var workshopSession: WorkshopSession?
    @State private var announcedTickets: Set<UUID> = []
    @State private var historicalFailure: WallpaperFailureSnapshot?
    @State private var historicalFailureDetails: WallpaperFailureSnapshot?
    @State private var bookmarkErrorToast: EditDeskToastCenter.Toast.ID?
    #endif
    @State private var libraryBookmarkErrorToast: EditDeskToastCenter.Toast.ID?
    private let initialNavigation: Navigation?
    private let initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest?
    private let initialOnboardingRequested: Bool
    /// The window's Edit › Undo; nil when the root is hosted in any other window.
    private let menuUndo: EditDeskMenuUndoManager?

    init(
        initialNavigation: Navigation? = nil,
        initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest? = nil,
        initialOnboardingRequested: Bool = false,
        menuUndo: EditDeskMenuUndoManager? = nil
    ) {
        self.initialNavigation = initialNavigation
        self.initialAddWallpaperRequest = initialAddWallpaperRequest
        self.initialOnboardingRequested = initialOnboardingRequested
        self.menuUndo = menuUndo
    }

    private var background: EditDeskBackground {
        EditDeskBackground(rawValue: backgroundRaw) ?? EditDeskPreferences.backgroundDefault
    }

    var body: some View {
        Group {
            if let router, let progress {
                @Bindable var router = router
                Group {
                    switch router.page {
                    case .home, .library:
                        // One page: the library is the stage's p = 2 state, not a separate view.
                        homePage(router)
                    case .schemes:
                        SchemesPage(router: router, toasts: toasts)
                    case .systemWallpaper:
                        // The router turns this page away before macOS 26.
                        if #available(macOS 26.0, *) {
                            SystemWallpaperPage(router: router)
                        }
                    case .workshop:
                        #if !LITE_BUILD
                        if let workshopSession {
                            WorkshopPage(router: router, session: workshopSession, toasts: toasts)
                        }
                        #else
                        Color.clear
                        #endif
                    case .settings:
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                TopBar(
                                    page: Binding(get: { router.page }, set: { router.select($0) }),
                                    workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                                    windowWidth: geometry.size.width, status: nil
                                )
                                // Above the columns, whose scroll view reaches up into this strip and would cover it.
                                .zIndex(1)
                                HStack(spacing: 0) {
                                    SettingsSidebar(
                                        selection: $router.settingsSelection,
                                        searchText: $router.settingsSearchText,
                                        pendingSearchAnchor: $router.pendingSettingsSearchAnchor,
                                        searchRequest: $router.settingsSearchRequest,
                                        onBack: router.backFromSettings,
                                        showsBackButton: false
                                    )
                                    .frame(width: SettingsWindowMetrics.sidebarColumnWidth)
                                    .pageGuideTarget(.settingsSidebar)
                                    Divider()
                                    SettingsDetailContent(
                                        selection: $router.settingsSelection,
                                        pendingSearchAnchor: $router.pendingSettingsSearchAnchor,
                                        searchText: router.settingsSearchText,
                                        searchRequest: router.settingsSearchRequest
                                    )
                                }
                            }
                        }
                        .ignoresSafeArea()
                    }
                }
                .allowsHitTesting(pageGuide.context == nil)
                .accessibilityHidden(pageGuide.context != nil)
                .environment(progress)
                .environment(router)
            } else {
                Color.clear
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if SettingsManager.shared.persistenceStatus.hasFailure {
                HStack {
                    Text("Your latest changes aren't saved yet. Keep Loomscreen open and retry.")
                    Spacer()
                    Button("Retry Save") {
                        Task { await SettingsManager.shared.flushPendingWrites() }
                    }
                    .disabled(SettingsManager.shared.persistenceStatus.isSaving)
                }
                .padding()
                .contentColumnBackground()
                .accessibilityIdentifier("settings.persistenceFailure")
            }
        }
        .overlay(alignment: .top) {
            EditDeskToastHost(center: toasts, onOpenDisplay: { router?.showDetail($0) })
        }
        #if !LITE_BUILD
        .onChange(of: deferredApplyTicketStates, initial: true) { _, _ in announceSettledTickets() }
        .onChange(of: WorkshopBookmarkStore.shared.hasStorageError, initial: true) { syncBookmarkErrorToast() }
        .onChange(of: toasts.toasts.map(\.id)) { syncBookmarkErrorToast() }
        .overlay(alignment: .bottomTrailing) {
            DownloadToastHost(
                visibleDisplayID: router?.page == .home ? router?.detailDisplayID : nil,
                activity: WorkshopFolderImportCoordinator.shared.progress,
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
        .onChange(of: LibraryBookmarkStore.shared.hasStorageError, initial: true) { syncLibraryBookmarkErrorToast() }
        .onChange(of: toasts.toasts.map(\.id)) { syncLibraryBookmarkErrorToast() }
        .environment(pageGuide)
        .overlayPreferenceValue(PageGuideAnchorKey.self) { anchors in
            PageGuideHost(session: pageGuide, anchors: anchors, onOpenWorkshopSettings: openGuideSettings)
                .ignoresSafeArea()
        }
        .onChange(of: router?.page) {
            if let router {
                pageGuide.closeIfOutsideRoute(router)
            }
        }
        .onChange(of: router?.detailDisplayID) {
            if let router {
                pageGuide.closeIfOutsideRoute(router)
            }
        }
        .modifier(UndoCommands(undo: undo, toasts: toasts))
        .environment(\.libraryTileSize, LibraryTileSize(rawValue: libraryTileSizeRaw) ?? .defaultSize)
        .providesGalleryCardPreferences()
        .background { EditDeskBackdrop(frosted: background == .frosted) }
        .frame(minWidth: StageGeometry.minimumWindow.width, minHeight: StageGeometry.minimumWindow.height)
        .onAppear {
            guard router == nil else { return }
            let progress = OnboardingProgress(
                defaults: .appScoped(), legacyDefaults: .standard,
                workshopAvailable: featureCatalog.isEnabled(.wpeImport)
            )
            self.progress = progress
            let undo = EditDeskUndoStack(
                manager: screenManager,
                router: ApplyRouter(
                    manager: screenManager, bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)
                ),
                bookmarks: BookmarkStore.shared
            )
            undo.onRecord = { [toasts] text, stepID in toasts.post(text, style: .success, undoStepID: stepID) }
            self.undo = undo
            menuUndo?.stack = undo
            menuUndo?.toasts = toasts
            let library = SavedLibraryModel(screenManager: screenManager)
            library.prepareLibrary(alsoKeeping: undo.retainedCoverFileNames)
            self.library = library
            let router = EditDeskRouter(
                initialNavigation: initialNavigation,
                initialAddWallpaperRequest: initialAddWallpaperRequest,
                initialOnboardingRequested: initialOnboardingRequested,
                isWorkshopAvailable: { [featureCatalog] in featureCatalog.isEnabled(.wpeImport) }
            )
            self.router = router
            if progress.handled.isEmpty, !progress.hasPresentedTour {
                router.onboardingRequested = true
            }
            Self.consumeOnboardingRequest(router: router, progress: progress, pageGuide: pageGuide)
            #if !LITE_BUILD
            let session = makeWorkshopSession(undo: undo)
            workshopSession = session
            // A launch-time "open Workshop scoped to this item" arrives before any page mounts.
            session.consumePendingDeepLink()
            #endif
        }
        #if !LITE_BUILD
        .modifier(RouterNotifications(router: router, screenManager: screenManager, workshopSession: workshopSession))
        #else
        .modifier(RouterNotifications(router: router, screenManager: screenManager))
        #endif
        .onChange(of: router?.onboardingRequested) {
            guard let router, let progress else { return }
            Self.consumeOnboardingRequest(router: router, progress: progress, pageGuide: pageGuide)
        }
    }

    private func openGuideSettings(_ anchor: SettingsSearchAnchor) {
        pageGuide.close()
        router?.openSettings(.workshopSetup, anchor: anchor)
    }

    /// Off `body`: the first `HomePage(…)` in this file pays for building HomePage's memberwise initializer.
    private func homePage(_ router: EditDeskRouter) -> some View {
        HomePage(router: router, toasts: toasts, library: library)
    }

    private func syncLibraryBookmarkErrorToast() {
        libraryBookmarkErrorToast = LibraryBookmarkStorageErrorToast.sync(.shared, shown: libraryBookmarkErrorToast, in: toasts)
    }

    static func consumeOnboardingRequest(router: EditDeskRouter, progress: OnboardingProgress, pageGuide: PageGuideSession) {
        guard router.onboardingRequested else { return }
        progress.reset()
        router.closeDetail()
        router.select(.home)
        router.onboardingRequested = false
        pageGuide.startTour(progress: progress, router: router)
    }

    #if !LITE_BUILD
    private var deferredApplyTicketStates: [UUID: DeferredApplyCoordinator.State] {
        Dictionary(uniqueKeysWithValues: workshopSession?.deferredApply.tickets.values.map { ($0.id, $0.state) } ?? [])
    }

    private func announceSettledTickets() {
        guard let workshopSession else { return }
        for ticket in workshopSession.deferredApply.tickets.values where ticket.state.isSettled {
            guard announcedTickets.insert(ticket.id).inserted else { continue }
            let screenName = DeferredApplyToasts.screenName(for: ticket.target, in: screenManager.screens)
            let messages = DeferredApplyToasts.messages(
                for: ticket.state, screenName: screenName, screenID: ticket.target.screenID,
                wallpapersOn: screenManager.wallpapersGloballyEnabled
            )
            for message in messages ?? [] {
                toasts.post(
                    message.text, style: message.style, screenID: message.screenID, persistent: message.persists,
                    undoStepID: message.undoStepID
                )
            }
        }
    }

    private func syncBookmarkErrorToast() {
        bookmarkErrorToast = BookmarkStorageErrorToast.sync(.shared, shown: bookmarkErrorToast, in: toasts)
    }

    private func makeWorkshopSession(undo: EditDeskUndoStack) -> WorkshopSession {
        let doctor = steamDoctor
        return WorkshopSession(
            browse: BrowseViewModel(services: workshopServices),
            deferredApply: DeferredApplyCoordinator(
                manager: screenManager,
                router: ApplyRouter(
                    manager: screenManager,
                    bookmarks: BookmarkStore.shared,
                    sceneCapable: featureCatalog.isEnabled(.scene)
                ),
                undo: undo
            ),
            confirmReadiness: { await doctor.autoConfirmDownloadReadinessIfNeeded() },
            ingestDownloads: { await WorkshopFolderImportCoordinator.shared.ingestExistingDownloads(using: doctor) }
        )
    }

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

/// ⌘Z and ⇧⌘Z for every page, and the undo history in their environment. Off `body`, which is already
/// slow to type-check.
private struct UndoCommands: ViewModifier {
    let undo: EditDeskUndoStack?
    let toasts: EditDeskToastCenter
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .background { shortcuts }
            .environment(undo)
    }

    /// Off while another window is key: SwiftUI falls back to the main window's shortcut, so ⌘Z in a
    /// sheet or the menu bar panel would otherwise undo a wallpaper.
    private var shortcuts: some View {
        ZStack {
            Button { run(redo: false) } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
            Button { run(redo: true) } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .disabled(!appearsActive)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// These buttons take ⌘Z before the Edit menu does, so a text field being edited gets it back as `undo:`.
    private func run(redo: Bool) {
        switch EditDeskUndoKeyRoute.current {
        case .text:
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        case .ignore:
            break
        case .stack:
            undo?.perform(redo: redo, announcingTo: toasts)
        }
    }
}

/// The app's navigation notifications, for the router. Off `body`, which is slow to type-check.
private struct RouterNotifications: ViewModifier {
    let router: EditDeskRouter?
    let screenManager: ScreenManager
    #if !LITE_BUILD
    let workshopSession: WorkshopSession?
    #endif

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openGeneralSettings)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsSection)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { notification in
                router?.handle(notification)
                #if !LITE_BUILD
                workshopSession?.consumePendingDeepLink()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAppleAerials)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: .promptAddWallpaper)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: EditDeskRoot.restartOnboardingNotification)) { router?.handle($0) }
            .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in
                router?.screensRefreshed(availableDisplayIDs: screenManager.screens.map(\.id))
            }
    }
}
