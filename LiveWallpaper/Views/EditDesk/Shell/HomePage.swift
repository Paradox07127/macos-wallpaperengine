import AppKit
import LiveWallpaperCore
import SwiftUI

/// Home = the AppKit stage plus the SwiftUI chrome layered over it. Owns the stage model and
/// feeds it displays, covers and shelf cards; consumes the stage's event stream. The library
/// is the stage's p = 2 state, so this one view serves both the home and library pages.
struct HomePage: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.galleryCardPreferences) private var cardPreferences
    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    #if !LITE_BUILD
    /// Optional: a page mounted without the Workshop services (tests) still opens the modal, minus update and delete.
    @Environment(SteamCMDDoctorService.self) private var doctor: SteamCMDDoctorService?
    /// Installed Workshop projects and their daily update check, read by the grid's badges and the modal.
    @State private var installedLibrary = InstalledLibraryModel()
    #endif
    let router: EditDeskRouter
    /// Owned by `EditDeskRoot`: a page switch unmounts this view, and a centre rebuilt here would
    /// drop whatever the other pages queued.
    let toasts: EditDeskToastCenter
    let library: SavedLibraryModel?
    @State private var stage = EditDeskStageModel()
    /// The modal's actions, which the grid's and the shelf's context menus offer too.
    @State private var modalActions: ModalActions?
    @State private var thumbnails = ShelfThumbnailCache()
    /// Set before a stage snap changes `router.page`, so that change is not echoed back as a command.
    @State private var pageChangeFromStage = false
    /// Bumped per display before each capture; a capture that finishes after a newer one started is dropped.
    @State private var coverGenerations: [CGDirectDisplayID: Int] = [:]
    @State private var applies = ApplyQueue()
    /// The library item the S4 modal shows; nil when closed.
    @State private var presentedItemID: String?
    /// The detail host reports its tile flights so the stage stays locked while a tile returns.
    @State private var detailBusy = false
    /// The empty display the paste-URL alert is open for; nil closes it.
    @State private var pasteURLTarget: CGDirectDisplayID?
    @State private var pastedAddress = ""
    /// The wallpapers-off banner's measured height; the arrangement moves down by it.
    @State private var offBannerHeight: CGFloat = 0
    /// The library's display banner as laid out above the grid, its top padding included; the stage lands its cards below it.
    @State private var libraryBannerHeight: CGFloat = 0
    /// The display the rename alert is open for; nil closes it.
    @State private var renameTarget: CGDirectDisplayID?
    @State private var renameDraft = ""
    @State private var pendingDestructive: PendingDestructive?
    /// The library item the rename alert or delete confirmation is open for, from a context menu or the modal; nil closes it.
    @State private var renamingItemID: String?
    @State private var deletingItemID: String?
    @State private var itemNameDraft = ""
    @AppStorage(EditDeskPreferences.shelfStyle, store: .appScoped())
    private var shelfStyleRaw = EditDeskPreferences.shelfStyleDefault.rawValue
    @AppStorage(EditDeskPreferences.shelfCapacity, store: .appScoped())
    private var shelfCapacity = EditDeskPreferences.shelfCapacityDefault
    @AppStorage(EditDeskPreferences.statusCapsuleContent, store: .appScoped())
    private var statusCapsuleRaw = EditDeskPreferences.statusCapsuleContentDefault.rawValue
    @AppStorage(EditDeskPreferences.homeDefaultState, store: .appScoped())
    private var homeDefaultRaw = EditDeskPreferences.homeDefaultStateDefault.rawValue

    /// Applies run beside the event loop, not inside it: the stage stream has a single consumer, so
    /// awaiting a Workshop import in the loop stalls every later tap, snap and drop behind it.
    /// One task per display, and a newer request for that display supersedes the one in flight.
    @MainActor
    @Observable
    final class ApplyQueue {
        @ObservationIgnored private var tasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
        private var cancellations: [CGDirectDisplayID: ApplyCancellation] = [:]
        @ObservationIgnored private var running = 0

        /// Displays whose newest apply is still running.
        var inFlight: Set<CGDirectDisplayID> {
            Set(cancellations.keys)
        }

        var isIdle: Bool {
            running == 0
        }

        func run(for displayID: CGDirectDisplayID, _ work: @escaping @MainActor (ApplyCancellation) async -> Void) {
            tasks[displayID]?.cancel()
            // Task cancellation alone leaves the superseded candidate preparing, to commit later on its own.
            cancellations[displayID]?.cancel()
            running += 1
            let cancellation = ApplyCancellation()
            cancellations[displayID] = cancellation
            tasks[displayID] = Task { @MainActor [weak self] in
                await work(cancellation)
                guard let self else { return }
                running -= 1
                // A superseded apply finishes after the newer one has started; only the newest clears the display.
                if cancellations[displayID] === cancellation {
                    cancellations[displayID] = nil
                }
            }
        }

        func cancel(_ displayID: CGDirectDisplayID) {
            cancellations[displayID]?.cancel()
        }
    }

    /// The `onChange` fan-out lives in its own modifier: inlined, it slows the body's type-check past the 300 ms warning.
    private struct SyncHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .modifier(LibraryHooks(page: page))
                #if !LITE_BUILD
                .modifier(InstalledLibraryHooks(page: page))
                #endif
                .onChange(of: page.tileSize) { page.stage.gridTileSize = page.tileSize }
                .onChange(of: page.reduceMotion) { page.stage.reduceMotion = page.reduceMotion }
                .onChange(of: page.contrast, initial: true) { page.stage.increaseContrast = page.contrast == .increased }
                .onChange(of: page.shelfStyleRaw) { page.stage.shelfStyle = page.shelfStyle }
                .onChange(of: page.interactionLock, initial: true) { page.stage.interactionBlocked = page.interactionLock }
                .onChange(of: page.stageTopInset, initial: true) { page.stage.arrangementTopInset = page.stageTopInset }
                .modifier(DisplayHooks(page: page))
        }
    }

    /// Split off `SyncHooks`: in one chain with it, these `onChange`s slow its type-check past the 300 ms warning.
    private struct LibraryHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.library?.visibleItems) { page.syncShelf() }
                // State refreshes rewrite `stage.displays` without rebuilding the cards, whose capsules wave by it.
                .onChange(of: page.drawingDisplayIDs) { page.syncShelf() }
                // The rename path: a display's drawn name comes out of these rows. Watched on the
                // whole library rather than the filtered rows, which also change on every keystroke.
                .onChange(of: page.library?.items) { page.refreshAllStates() }
                .onChange(of: page.shelfCapacity) { page.syncShelf() }
                .onChange(of: page.stage.visibleShelfRange) { page.loadShelfThumbnails() }
                .onChange(of: page.stage.visibleGridRange) { page.loadShelfThumbnails() }
        }
    }

    /// Split off `SyncHooks`: in one chain with it, these handlers would push its type-check past the 300 ms warning.
    private struct DisplayHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.screenManager.screens.map(\.id)) { page.syncDisplays() }
                .onChange(of: page.screenManager.suspendReasonsByScreen) { page.refreshAllStates() }
                .onChange(of: page.screenManager.screens.map { page.screenManager.wallpaperLoads.attempt(for: $0)?.failure }) {
                    page.refreshAllStates()
                }
                .onChange(of: page.screenManager.wallpaperSessionStateVersion) { page.refreshAllStates() }
                .onChange(of: page.router.page) { page.syncProgress(to: page.router.page, animated: true) }
                .onChange(of: page.router.libraryFocus, initial: true) { page.consumeLibraryFocus() }
        }
    }

    #if !LITE_BUILD
    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct InstalledLibraryHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onAppear { page.installedLibrary.onAppear() }
                .onDisappear { page.installedLibrary.onDisappear() }
                .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
                    page.installedLibrary.historyDidChange()
                }
        }
    }
    #endif

    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct BrowseHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.stage.snappedIndex) { page.syncBrowsing() }
                .onChange(of: page.presentedItemID) { page.syncBrowsing() }
                // The model outlives this view: a browse left open would keep ranking by its old snapshot.
                .onDisappear { page.library?.endBrowsing() }
                // Initial too: the model outlives this view, so a query can arrive with a mount on the overview.
                .onChange(of: page.router.page, initial: true) {
                    if page.router.page != .library {
                        page.library?.query = ""
                    }
                }
                // Initial too: rows added while another page showed have no tags read for the kept query.
                .onChange(of: page.library?.query, initial: true) { Task { await page.library?.loadSearchTags() } }
        }
    }

    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct ApplyHook: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content.onChange(of: page.applies.inFlight) { page.refreshAllStates() }
        }
    }

    /// The display context menu's alerts and the Esc key, off `body` for the same reason as `SyncHooks`.
    private struct DisplayCommands: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .background {
                    if page.handlesEscape {
                        Button { page.pressEscape() } label: { EmptyView() }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
                }
                // `presenting:` hands the action the display it was opened for: dismissal clears the state.
                .alert("Rename Display", isPresented: page.renamePresented, presenting: page.renameTarget) { id in
                    TextField("Display name", text: page.$renameDraft)
                    Button("Cancel", role: .cancel) {}
                    Button("Rename") { page.rename(id) }
                }
                .confirmDestructive(page.$pendingDestructive)
        }
    }

    /// The library's rename alert and delete confirmation, for its context menus and the modal, off `body` for the same reason as `SyncHooks`.
    private struct LibraryItemCommands: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            let deleting = page.libraryItem(page.deletingItemID)
            content
                .wallpaperDeleteConfirmation(
                    itemID: page.$deletingItemID, title: deleting?.title ?? "",
                    deletesFiles: deleting.map { page.modalActions?.deletesFiles($0) == true } ?? false
                ) { id in
                    guard let item = page.libraryItem(id) else { return }
                    page.modalActions?.actions(for: item).deleteInstalled?()
                }
                .wallpaperRenameAlert(itemID: page.$renamingItemID, name: page.$itemNameDraft) { id in
                    guard let item = page.libraryItem(id) else { return }
                    page.modalActions?.actions(for: item).rename?(page.itemNameDraft)
                }
        }
    }

    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct LibraryTargetHook: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.router.libraryTarget) { _, target in
                    if target != nil {
                        page.library?.chip = .all
                    }
                }
                .onChange(of: page.gridContentInset, initial: true) { page.stage.gridContentInset = page.gridContentInset }
        }
    }

    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct OnboardingStepHook: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content.onChange(of: page.router.pendingOnboardingStep, initial: true) { _, step in
                guard let step else { return }
                page.router.pendingOnboardingStep = nil
                // An open modal keeps the step's card out of view.
                page.presentedItemID = nil
                switch step {
                case .home:
                    // The overview card only shows on a stage at rest, not with the shelf half open.
                    page.stage.setProgress(0, animated: !page.reduceMotion)
                case .library, .workshop, .overlay:
                    break
                }
            }
        }
    }

    private var shelfStyle: ShelfStyle {
        ShelfStyle(rawValue: shelfStyleRaw) ?? EditDeskPreferences.shelfStyleDefault
    }

    /// The stage ignores wheel and clicks while anything is presented over it.
    fileprivate var interactionLock: Bool {
        presentedItemID != nil || router.detailDisplayID != nil || detailBusy
    }

    /// Shelf thumbnails are requested at the row card size on a 2× screen; the grid shows them only
    /// until its own size decodes.
    private static let thumbnailPixelSize = CGSize(
        width: StageGeometry.cardSize.width * 2, height: StageGeometry.cardSize.height * 2
    )

    var body: some View {
        ZStack(alignment: .top) {
            // Order matters: the shelf's scrim and the filter chips belong *under* the cards, so a card
            // leaning or lifting over them is never clipped by a piece of chrome. Landed on the library,
            // the chips go over the grid instead, or it would hide them as a return swipe carries them down.
            libraryBannerMeasure
            EditDeskDotGrid()
                .zIndex(-1)
            LibraryPageUnderlay(stage: stage)
                .zIndex(-1)
            EditDeskShelfScrim(stage: stage)
                .zIndex(-1)
            EditDeskStageRepresentable(model: stage)
            ShelfDropHighlight(stage: stage)
            HomeHints(stage: stage)
            hoverName
            libraryLayer
            shelfChrome
                .zIndex(landedOnLibrary ? 0 : -1)
            homeOnboardingCard
            wallpapersOffBanner
            if router.detailDisplayID == nil, !detailBusy {
                TopBar(
                    page: pageBinding,
                    workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                    windowWidth: stage.stageSize.width,
                    status: statusCapsule
                )
            }
            DisplayDetailHost(
                router: router, stage: stage, library: library, modalPresented: presentedItemID != nil,
                refreshCover: { refreshCover(for: $0, crossfade: false) },
                chooseFile: { promptImport(onto: $0) },
                pasteURL: { id in
                    pastedAddress = DisplayDetailHost.editableWebAddress(
                        screenManager.screen(withID: id).flatMap { screenManager.getConfiguration(for: $0) }?.activeWallpaper
                    )
                    pasteURLTarget = id
                },
                dropFiles: { urls, screen in
                    guard let intent = ApplyIntent.drop(urls) else { return false }
                    applies.run(for: screen.id) { await apply(intent, to: screen, card: nil, cancellation: $0) }
                    return true
                },
                apply: applyFromModal,
                clearWallpaper: { clearWallpaper(on: $0) },
                applyToAllDisplays: { applyConfigurationToAllDisplays(from: $0) },
                applying: applies.inFlight,
                cancelApply: { applies.cancel($0) },
                busy: $detailBusy, toasts: toasts
            )
            if let library, let modalActions {
                LibraryModalHost(
                    library: library, stage: stage, actions: modalActions,
                    requestRename: requestRename, requestDelete: requestDelete,
                    presentedItemID: $presentedItemID, preferredTarget: router.libraryTarget, applying: applies.inFlight
                )
            }
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .onAppear {
            if modalActions == nil, let library {
                modalActions = makeModalActions(library: library)
            }
            // Not `.task`: leaving the page cancels that, and a cancelled probe reads as found.
            Task { await library?.recheckMissingSources() }
            stage.gridTileSize = tileSize
            stage.reduceMotion = reduceMotion
            stage.shelfStyle = shelfStyle
            stage.dropHintText = String(localized: "Drop to replace", bundle: .appLanguage)
            stage.displayMenu = { displayMenuSections(for: $0) }
            stage.cardMenu = { id in library?.items.first { $0.id == id }.map { [libraryMenu(for: $0)] } ?? [] }
            syncDisplays()
            if router.page == .library {
                stage.setProgress(2, animated: false)
            } else if HomeDefaultState(rawValue: homeDefaultRaw) == .halfOpen, stage.progress == 0,
                      progress?.handled.contains(.home) != false, screenManager.wallpapersGloballyEnabled {
                // Off, the stage stays at rest: the banner that turns wallpapers back on only shows there.
                stage.setProgress(1, animated: false)
            }
        }
        .task { await consumeEvents() }
        .modifier(SyncHooks(page: self))
        .modifier(BrowseHooks(page: self))
        .modifier(LibraryTargetHook(page: self))
        .modifier(OnboardingStepHook(page: self))
        .modifier(ApplyHook(page: self))
        .modifier(DisplayCommands(page: self))
        .modifier(LibraryItemCommands(page: self))
        .onChange(of: progress?.handled) {
            if router.page == .home, progress?.handled.isEmpty == true {
                stage.setProgress(0, animated: !reduceMotion)
            }
        }
        .onChange(of: router.pendingAddWallpaper, initial: true) { consumeAddWallpaperRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in syncDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let id = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            refreshState(for: id)
            refreshCover(for: id, crossfade: true)
        }
        // `presenting:` hands the action the display it was opened for: dismissal clears the state.
        .alert("Web address", isPresented: pasteURLPresented, presenting: pasteURLTarget) { id in
            TextField("example.com", text: $pastedAddress)
            Button("Cancel", role: .cancel) {}
            Button("Use") { applyPastedAddress(to: id) }
                .disabled(pastedWebsiteURL == nil)
        } message: { _ in
            Text("Enter a website address, such as https://example.com.")
        }
    }

    private var pastedWebsiteURL: URL? {
        guard case let .url(url)? = HTMLSource(userInput: pastedAddress) else { return nil }
        return url
    }

    private var pasteURLPresented: Binding<Bool> {
        Binding(get: { pasteURLTarget != nil }, set: { presented in
            if !presented {
                pasteURLTarget = nil
            }
        })
    }

    // MARK: Display commands

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { presented in
            if !presented {
                renameTarget = nil
            }
        })
    }

    /// The modal and the detail page answer Esc themselves; at rest on the overview there is nothing to leave.
    private var handlesEscape: Bool {
        !interactionLock && (router.page == .library || stage.snappedIndex > 0)
    }

    /// A key equivalent is offered Esc before a focused field is: the field editor gets it back as
    /// `cancelOperation:`, which is what ends the scheme rename and clears the search field.
    private func pressEscape() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
        } else {
            _ = stage.escape()
        }
    }

    private func displayMenuSections(for id: CGDirectDisplayID) -> [[StageMenuItem]] {
        guard let screen = screenManager.screens.first(where: { $0.id == id }) else { return [] }
        var naming = [StageMenuItem(
            title: String(localized: "Rename", bundle: .appLanguage, comment: "Context menu item that opens a rename alert, for a display on the Edit Desk stage or for a wallpaper."),
            isEnabled: true
        ) {
            renameDraft = screen.name
            renameTarget = id
        }]
        if screen.customName != nil {
            naming.append(StageMenuItem(title: String(localized: "Use System Name", bundle: .appLanguage), isEnabled: true) {
                screenManager.setCustomName(nil, for: screen)
                syncDisplays()
            })
        }
        let configured = screenManager.getConfiguration(for: screen) != nil
        let wallpaper = [
            StageMenuItem(title: String(localized: "Reload", bundle: .appLanguage), isEnabled: configured) {
                screenManager.reloadWallpaperForScreen(screen)
            },
            StageMenuItem(
                title: String(localized: "Apply to All Displays", bundle: .appLanguage),
                isEnabled: configured && screenManager.screens.count > 1
            ) {
                pendingDestructive = PendingDestructive(
                    .applyConfigurationToAllDisplays(otherCount: screenManager.screens.count - 1)
                ) {
                    applyConfigurationToAllDisplays(from: screen)
                }
            },
            StageMenuItem(title: String(localized: "Clear Wallpaper", bundle: .appLanguage), isEnabled: configured) {
                pendingDestructive = PendingDestructive(.clearCurrentWallpaper(displayName: screen.name)) {
                    clearWallpaper(on: screen)
                }
            },
        ]
        return [naming, wallpaper]
    }

    /// Neither the stage's name row nor the shelf's now-playing capsules watch the name, so both are redrawn here.
    private func rename(_ id: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == id }) else { return }
        screenManager.setCustomName(renameDraft, for: screen)
        syncDisplays()
    }

    private func clearWallpaper(on screen: Screen) {
        let recording = undo?.begin(.clearWallpaper, displays: [screen])
        screenManager.clearWallpaperForScreen(screen)
        recording?.announce(
            String(
                localized: "Cleared the wallpaper on \(screen.name)", bundle: .appLanguage,
                comment: "Toast after a display's wallpaper was cleared in the Edit Desk; it offers Undo. Placeholder is a display name."
            ),
            showing: nil, to: toasts
        )
    }

    private func applyConfigurationToAllDisplays(from screen: Screen) {
        let recording = undo?.begin(.applyToAllDisplays, displays: screenManager.screens.filter { $0.id != screen.id })
        let content = screenManager.getConfiguration(for: screen)?.activeWallpaper
        screenManager.applyConfigurationToAllDisplays(from: screen)
        recording?.announce(
            ApplyOutcome.appliedToAllText(wallpapersOn: screenManager.wallpapersGloballyEnabled), showing: content, to: toasts
        )
    }

    // MARK: Library item commands

    private func makeModalActions(library: SavedLibraryModel) -> ModalActions {
        #if LITE_BUILD
        ModalActions(
            library: library, screenManager: screenManager, thumbnails: thumbnails, undo: undo,
            apply: applyFromModal, applyToAll: applyAllFromModal
        )
        #else
        if let doctor {
            return ModalActions(
                library: library, screenManager: screenManager, thumbnails: thumbnails, doctor: doctor,
                installedLibrary: installedLibrary, undo: undo, apply: applyFromModal, applyToAll: applyAllFromModal
            )
        }
        return ModalActions(
            inputs: .live(library: library, screenManager: screenManager), bookmarks: .shared,
            thumbnails: thumbnails, undo: undo, apply: applyFromModal, applyToAll: applyAllFromModal
        )
        #endif
    }

    private func libraryItem(_ id: String?) -> LibraryItem? {
        library?.items.first { $0.id == id }
    }

    /// A grid tile's or shelf card's context menu: the rows of that item's "…" menu in the modal.
    private func libraryMenu(for item: LibraryItem) -> [StageMenuItem] {
        modalActions?.menuItems(
            for: item, requestRename: { requestRename(item) }, requestDelete: { requestDelete(item) }
        ) ?? []
    }

    private func requestRename(_ item: LibraryItem) {
        itemNameDraft = item.title
        renamingItemID = item.id
    }

    private func requestDelete(_ item: LibraryItem) {
        deletingItemID = item.id
    }

    // MARK: Chrome

    private var shelfChrome: some View {
        chipsRow.modifier(ShelfChromeRide(stage: stage))
    }

    /// R-27: the overview card belongs to the resting stage, so a half-open shelf, the detail page
    /// or any modal takes it off screen rather than layering it over them.
    private var isRestingOverview: Bool {
        router.page == .home && stage.progress == 0 && !interactionLock
    }

    /// While wallpapers are off the band is the off banner's, not the card's.
    private var showsHomeCard: Bool {
        isRestingOverview && screenManager.wallpapersGloballyEnabled
    }

    /// The gate above says *where* the card may hang; this one says whether it is actually drawn,
    /// which is what the arrangement gives up its top band for.
    fileprivate var homeCardClaimsStage: Bool {
        showsHomeCard && progress?.handled.contains(.home) == false
    }

    private var offBannerClaimsStage: Bool {
        isRestingOverview && !screenManager.wallpapersGloballyEnabled
    }

    /// The top band the display arrangement leaves to the off banner or the onboarding card.
    fileprivate var stageTopInset: CGFloat {
        if offBannerClaimsStage {
            offBannerHeight + DesignTokens.EditDesk.Spacing.gutter
        } else if homeCardClaimsStage {
            OnboardingCardMetrics.stageTopInset
        } else {
            0
        }
    }

    @ViewBuilder
    private var wallpapersOffBanner: some View {
        if offBannerClaimsStage {
            WallpapersOffBanner { screenManager.setWallpapersEnabled(true) }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { offBannerHeight = $0 }
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
                .padding(.top, StageGeometry.topBarHeight)
        }
    }

    @ViewBuilder
    private var homeOnboardingCard: some View {
        if showsHomeCard {
            OnboardingCard(page: .home) { action in
                switch action {
                case .chooseFile:
                    promptImport()
                case .tryAerials:
                    router.select(.library)
                    router.libraryFocus = .aerials
                case .importMore, .connectSteam, .importLocalLibrary, .addClock:
                    break
                }
            }
        }
    }

    private func performLibraryCardAction(_ action: OnboardingCardAction) {
        switch action {
        case .importMore:
            promptLibraryImport()
        case .chooseFile, .tryAerials, .connectSteam, .importLocalLibrary, .addClock:
            break
        }
    }

    private var libraryLayer: some View {
        ZStack {
            if isLibraryOpen {
                wallpaperGrid
                    .padding(.top, StageGeometry.gridTop)
                    // Hidden rather than unmounted while the stage carries the cards off: unmounting here would
                    // lose the scroll position, and a swipe pushed back would rebuild the grid at its top.
                    .opacity(stage.leavingLibrary ? 0 : 1)
                    .allowsHitTesting(!stage.leavingLibrary)
                    .accessibilityHidden(stage.leavingLibrary)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        // On this layer only: the top bar changes in the same update and keeps its own transaction.
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: Self.libraryFadeDuration)), value: isLibraryOpen)
    }

    private var isLibraryOpen: Bool {
        Self.mountsLibraryGrid(
            page: router.page, snappedIndex: stage.snappedIndex, progress: stage.progress, leaving: stage.leavingLibrary
        )
    }

    /// The display the library was opened for, while its banner shows above the grid.
    private var libraryTargetScreen: Screen? {
        router.libraryTarget.flatMap { target in screenManager.screens.first { $0.id == target } }
    }

    /// Between the display banner, the onboarding card and the grid inside the library's scroll view.
    private static let libraryStackSpacing = DesignTokens.Spacing.sm

    /// What the library stacks above the grid's first row inside its scroll view.
    private var gridContentInset: CGFloat {
        var inset: CGFloat = 0
        if libraryTargetScreen != nil {
            inset += libraryBannerHeight + Self.libraryStackSpacing
        }
        if progress?.handled.contains(.library) == false {
            inset += OnboardingCardMetrics.blockHeight + Self.libraryStackSpacing
        }
        return inset
    }

    /// The display banner laid out unseen at the grid's width, so its height is known before the grid mounts.
    @ViewBuilder
    private var libraryBannerMeasure: some View {
        if let screen = libraryTargetScreen {
            libraryTargetBanner(for: screen)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { libraryBannerHeight = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The grid's cross-fade over cards that have already landed on its tiles.
    private static let libraryFadeDuration: TimeInterval = 0.10

    /// True from the landing until the stage snaps back, return swipe included.
    private var landedOnLibrary: Bool {
        router.page == .library && stage.snappedIndex == 2
    }

    /// Not before the landing: mounted mid-swipe the grid covers cards still in flight and sits under the
    /// pointer for the rest of the swipe. Not `progress == 2` either: the first pixel of a return swipe
    /// would tear it down and lose the scroll position, and a cancelled swipe would rebuild it. `leaving`:
    /// the stage is carrying the cards off, and the grid stays until they land, however far they have gone.
    static func mountsLibraryGrid(page: EditDeskRouter.Page, snappedIndex: Int, progress: Double, leaving: Bool = false) -> Bool {
        page == .library && snappedIndex == 2 && (leaving || progress > StageGeometry.libraryHandoffProgress)
    }

    private var statusCapsule: StatusCapsule {
        StatusCapsule(
            content: StatusCapsuleContent(rawValue: statusCapsuleRaw) ?? EditDeskPreferences.statusCapsuleContentDefault,
            renderingScreenCount: StatusCapsuleModel.renderingCount(
                configured: screenManager.screens.filter { screenManager.getConfiguration(for: $0) != nil }.count,
                wallpapersEnabled: screenManager.wallpapersGloballyEnabled
            ),
            batterySaverOn: SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
        )
    }

    private var queryBinding: Binding<String> {
        Binding(get: { library?.query ?? "" }, set: { library?.query = $0 })
    }

    private var chipBinding: Binding<String> {
        Binding(get: { Self.chipID(library?.chip ?? .all) }, set: { library?.chip = Self.chip(for: $0) })
    }

    /// Writing `router.page` straight from the pill skips `select`, which is what records the page
    /// to come back to and what turns Workshop away when the SKU does not have it.
    private var pageBinding: Binding<EditDeskRouter.Page> {
        Binding(get: { router.page }, set: { router.select($0) })
    }

    private var chipsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s12) {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
                LibraryChipsRow(
                    chips: SavedLibraryModel.Chip.allCases.map { LibraryChip(id: Self.chipID($0), title: Self.chipTitle($0)) },
                    selection: chipBinding,
                    searchText: queryBinding,
                    searchPrompt: featureCatalog.isEnabled(.wpeImport) ? "Search by name or tag" : "Search by name",
                    stage: stage,
                    sort: Binding(get: { library?.sort ?? .recentlyUsed }, set: { library?.sort = $0 }),
                    onImport: promptLibraryImport
                )
                if library?.chip == .aerials, library?.aerialsStatus.isAuthorized == true {
                    AerialsSourceControls()
                }
            }
            shelfEmptyHint
        }
    }

    @ViewBuilder
    private var shelfEmptyHint: some View {
        if router.page == .home, let library, library.visibleItems.isEmpty {
            if library.chip == .aerials, library.aerialsStatus.isEmpty {
                AerialsSourceStatusCard(presentation: .inline)
            } else {
                Text(library.items.isEmpty ? "No wallpapers yet" : "No Results")
                    .font(DesignTokens.EditDesk.Typography.chip)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            }
        }
    }

    /// A browse lasts while the shelf or the library is snapped open, or the modal is up.
    private func syncBrowsing() {
        if stage.snappedIndex == 0, presentedItemID == nil {
            library?.endBrowsing()
        } else {
            library?.beginBrowsing()
        }
    }

    private var hoverCaption: String? {
        guard let id = stage.hoveredCard, let item = library?.items.first(where: { $0.id == id }) else { return nil }
        return item.title + " · " + item.kind.localizedName
    }

    /// The name rides over the card the pointer is on: inside the thumbnail the card to the right
    /// covers all but the near edge, so a title drawn there is unreadable.
    @ViewBuilder
    private var hoverName: some View {
        if router.page == .home, !interactionLock, stage.progress < 1.5,
           let caption = hoverCaption, let rect = stage.hoveredCardRect, stage.showsShelf {
            Text(verbatim: caption)
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
                .padding(.vertical, 4)
                .background(DesignTokens.EditDesk.Colors.panel, in: Capsule())
                .fixedSize()
                .position(x: rect.midX, y: rect.minY - 16)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private static func chipID(_ chip: SavedLibraryModel.Chip) -> String {
        switch chip {
        case .all: "all"
        case .recent: "recent"
        case .steam: "steam"
        case .local: "local"
        case .aerials: "aerials"
        }
    }

    private static func chip(for id: String) -> SavedLibraryModel.Chip {
        SavedLibraryModel.Chip.allCases.first { chipID($0) == id } ?? .all
    }

    static func chipTitle(_ chip: SavedLibraryModel.Chip) -> LocalizedStringKey {
        switch chip {
        case .all: "All"
        case .recent: "Recent"
        case .steam: "Steam"
        case .local: "Local"
        case .aerials: "Aerials"
        }
    }

    // MARK: Library page

    private var wallpaperGrid: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Spaced explicitly: `gridContentInset` has to know how far down the first row starts.
                VStack(spacing: Self.libraryStackSpacing) {
                    if let screen = libraryTargetScreen {
                        libraryTargetBanner(for: screen)
                    }
                    // R-27: eligibility is the page, not what the filter left behind, so the card rides
                    // above an empty result set just as it does above real tiles.
                    if progress?.handled.contains(.library) == false {
                        OnboardingCard(page: .library, perform: performLibraryCardAction)
                            .frame(height: OnboardingCardMetrics.blockHeight)
                    }
                    if let library, library.chip == .aerials, library.aerialsStatus.isEmpty {
                        AerialsSourceStatusCard()
                    } else if let library, library.visibleItems.isEmpty {
                        IllustratedEmptyState(
                            symbol: library.items.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                            title: library.items.isEmpty ? "No wallpapers yet" : "No Results"
                        )
                    } else if let library {
                        LibraryGalleryGrid(
                            size: tileSize, aspect: .wide,
                            initialWidth: stage.stageSize.width - 2 * DesignTokens.LibraryGrid.horizontalPadding
                        ) {
                            ForEach(library.visibleItems) { item in
                                let badges = item.cardBadges(
                                    among: stage.displays, updatedWorkshopIDs: updatedWorkshopIDs, preferences: cardPreferences
                                )
                                Button {
                                    // VoiceOver's VO key includes ⌥, so only a mouse click may count as an ⌥-click.
                                    if NSApp.currentEvent?.type == .leftMouseUp, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                                        quickApply(item.id)
                                    } else {
                                        presentedItemID = item.id
                                    }
                                } label: {
                                    LibraryGridTile(item: item, thumbnail: gridThumbnail(for: item), thumbnails: thumbnails, badges: badges)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { WallpaperMenuRows(items: libraryMenu(for: item)) }
                                .accessibilityLabel(Text(verbatim: badges.accessibilityLabel(title: item.title)))
                                .accessibilityValue(Text(verbatim: item.statusBadge ?? ""))
                                .accessibilityAction(named: Text("Apply")) { quickApply(item.id) }
                                .task(id: item.id) { await library.probeMetadata(for: [item.id]) }
                            }
                        }
                        .libraryGridPadding()
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(GridTopReporter(atTop: { stage.gridAtTop = $0 }, offset: { stage.gridScrollOffset = $0 }))
            if let library, !library.items.isEmpty {
                LibraryStatusBar(summary: statusSummary(library))
            }
        }
        .background(DesignTokens.EditDesk.Colors.background)
    }

    private func statusSummary(_ library: SavedLibraryModel) -> Text {
        let total = library.items.count
        let shown = library.visibleItems.count
        return shown == total ? Text("\(total) wallpapers") : Text("\(shown) of \(total) shown")
    }

    private func libraryTargetBanner(for screen: Screen) -> some View {
        InlineNoticeBanner(
            tint: DesignTokens.Colors.Status.info,
            symbol: "display",
            title: Text(
                "Choosing a wallpaper for \(screen.name)",
                comment: "Wallpaper library banner: the library was opened from this display's detail page."
            ),
            surface: .content
        ) {
            Button { router.showDetail(screen.id) } label: {
                Text("Back to \(screen.name)", comment: "Wallpaper library banner button that returns to the display's detail page.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.LibraryGrid.horizontalPadding)
        .padding(.top, DesignTokens.LibraryGrid.verticalPadding)
    }

    private var updatedWorkshopIDs: Set<String> {
        #if LITE_BUILD
        []
        #else
        installedLibrary.updatedWorkshopIDs
        #endif
    }

    private func gridThumbnail(for item: LibraryItem) -> LibraryGridTile.Thumbnail? {
        Self.gridThumbnail(
            for: item, stageWidth: stage.stageSize.width, size: tileSize, scale: NSScreen.main?.backingScaleFactor ?? 2
        )
    }

    static func gridThumbnail(
        for item: LibraryItem, stageWidth: CGFloat, size: LibraryTileSize, scale: CGFloat
    ) -> LibraryGridTile.Thumbnail? {
        guard let request = item.thumbnail else { return nil }
        let tileWidth = StageGeometry.gridCellSize(windowWidth: stageWidth, size: size).width
        return LibraryGridTile.Thumbnail(request, tileWidth: tileWidth, scale: scale)
    }

    /// Whether a finished decode still belongs on its card. `tile` is the grid tile a grid decode was for, nil for a
    /// shelf decode. The item's source can change while a decode runs, and so can the pixels its tile asks for; a newer
    /// decode may have landed by then and must not be painted over.
    static func decodeIsCurrent(
        _ request: ShelfThumbnailCache.Request, tile: LibraryGridTile.Thumbnail?, item: LibraryItem,
        stageWidth: CGFloat, tileSize: LibraryTileSize, scale: CGFloat
    ) -> Bool {
        guard let tile else { return item.thumbnail == request }
        return gridThumbnail(for: item, stageWidth: stageWidth, size: tileSize, scale: scale) == tile
    }

    /// The tile's own pixels if anything already decoded them, the shelf's copy otherwise.
    static func gridImage(_ thumbnail: LibraryGridTile.Thumbnail, in cache: ShelfThumbnailCache) -> CGImage? {
        cache.cached(thumbnail.request, pixelSize: thumbnail.pixelSize, scale: thumbnail.scale)
            ?? cache.cached(thumbnail.request, pixelSize: thumbnailPixelSize, scale: thumbnail.scale)
    }

    private func syncProgress(to page: EditDeskRouter.Page, animated: Bool) {
        if pageChangeFromStage {
            pageChangeFromStage = false
            return
        }
        switch page {
        case .library where stage.progress < 2:
            stage.setProgress(2, animated: animated)
        case .home where stage.progress > 0:
            stage.setProgress(0, animated: animated)
        default:
            break
        }
    }

    private func consumeLibraryFocus() {
        if let focus = router.takeLibraryFocus() {
            applyLibraryFocus(focus)
        }
    }

    private func applyLibraryFocus(_ focus: EditDeskRouter.LibraryFocus) {
        switch focus {
        case .aerials:
            library?.chip = .aerials
        }
    }

    // MARK: Displays

    /// Its own property: inlined in `LibraryHooks`, this filter slows that body's type-check past the 300 ms warning.
    private var drawingDisplayIDs: [CGDirectDisplayID] {
        stage.displays.filter { $0.state == .ok }.map(\.id)
    }

    private func syncDisplays() {
        stage.displays = screenManager.screens.map { screen in
            let presentation = ScreenPresentation.presentation(
                for: screen, refreshRate: screenManager.getScreenRefreshRate(for: screen.id)
            )
            var display = StageDisplay(
                id: screen.id,
                fingerprint: screen.displayFingerprint,
                frame: screen.frame,
                isBuiltin: CGDisplayIsBuiltin(screen.id) != 0,
                name: screen.name,
                badgeText: presentation.badge,
                statusText: presentation.status,
                cover: stage.displays.first { $0.id == screen.id }?.cover,
                state: state(for: screen)
            )
            describeWallpaper(for: screen, in: &display)
            return display
        }
        for display in stage.displays where display.cover == nil && display.state != .empty {
            refreshCover(for: display.id, crossfade: false)
        }
        // The shelf's now-playing capsules name the leftmost display, so a rename or a new arrangement relabels them.
        syncShelf()
    }

    private func state(for screen: Screen) -> StageDisplay.State {
        // The menu bar's own reading of the master switch; a failure chip from before it went off is stale.
        if screenManager.wallpaperSummary(for: screen).activity == .off {
            return .off(text: String(
                localized: "Turned Off", bundle: .appLanguage,
                comment: "Stage chip and VoiceOver state of a display while the master switch keeps every wallpaper off."
            ))
        }
        if applies.inFlight.contains(screen.id) {
            return .preparing(text: String(localized: "Preparing wallpaper…", bundle: .appLanguage))
        }
        if let cause = screenManager.wallpaperLoads.attempt(for: screen)?.failure?.cause
            ?? screenManager.runtimeError(for: screen).map(WallpaperFailureCause.runtime) {
            let failureClass = cause.failureClass
            return .failed(StageFailureChip(
                symbol: failureClass.symbol, text: failureClass.kickerText, tint: NSColor(failureClass.tint).cgColor
            ))
        }
        guard screenManager.getConfiguration(for: screen) != nil else { return .empty }
        if let reasons = screenManager.suspendReasonsByScreen[screen.id],
           let text = SuspendReasonText.localized(for: reasons) {
            return .paused(reasonText: text)
        }
        if screen.playbackController?.userIntendsToPlay == false {
            return .paused(reasonText: String(localized: "Paused", bundle: .appLanguage))
        }
        return .ok
    }

    private func refreshAllStates() {
        for display in stage.displays {
            refreshState(for: display.id)
            // Startup can mount the page before a restored session has produced its first frame.
            if display.cover == nil, display.state != .empty {
                refreshCover(for: display.id, crossfade: true)
            }
        }
    }

    private func refreshState(for id: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == id }),
              let index = stage.displays.firstIndex(where: { $0.id == id }) else { return }
        stage.displays[index].state = state(for: screen)
        describeWallpaper(for: screen, in: &stage.displays[index])
    }

    /// What the display draws on its own screen and which transport buttons it offers. Recomputed
    /// wherever the state is, so a playlist step, a schedule switch or a rename lands on the stage.
    private func describeWallpaper(for screen: Screen, in display: inout StageDisplay) {
        guard let configuration = screenManager.getConfiguration(for: screen) else {
            display.wallpaperTitle = ""
            display.wallpaperKind = ""
            display.showsPlaylistControls = false
            display.canChangePlaylistEntry = false
            display.canTogglePlayback = false
            display.intendsToPlay = false
            return
        }
        let host: String? = if case let .url(url)? = configuration.htmlSource {
            url.host()
        } else {
            nil
        }
        display.wallpaperKind = DisplayDetailHost.kindLine(configuration.activeWallpaper)
        display.wallpaperTitle = StageWallpaperName.resolve(
            libraryTitle: libraryTitle(for: configuration),
            originTitle: configuration.wpeOrigin?.title,
            fileURL: configuration.wallpaperType == .video ? screen.videoPlayer?.videoURL : nil,
            host: host,
            kind: display.wallpaperKind
        )
        // The same guards `WallpaperAutomationOrchestrator.advancePlaylist` runs: a button the
        // orchestrator would refuse is drawn dimmed rather than looking live.
        display.showsPlaylistControls = featureCatalog.isEnabled(.playlists) && configuration.canNavigatePlaylist
        display.canChangePlaylistEntry = display.showsPlaylistControls
        display.canTogglePlayback = screen.playbackController != nil
        display.intendsToPlay = screen.playbackController?.userIntendsToPlay == true
    }

    /// The library row for exactly the wallpaper this display is running. Matched on the content
    /// itself rather than through `onDisplays`, whose reverse links a variant or the Workshop
    /// original can share.
    private func libraryTitle(for configuration: ScreenConfiguration) -> String? {
        library?.items.first { item in
            switch item.source {
            case let .bookmark(bookmark): bookmark.content == configuration.activeWallpaper
            case let .aerial(asset): library?.aerial(asset, matches: configuration.activeWallpaper) == true
            #if !LITE_BUILD
            case let .workshop(entry): configuration.wpeOrigin?.workshopID == entry.origin.workshopID
            #endif
            }
        }?.title
    }

    /// Covers are stills of the app's own rendering (`WallpaperCoverCapture`), re-taken after
    /// every configuration change; the desktop itself is the live preview.
    private func refreshCover(for id: CGDirectDisplayID, crossfade: Bool) {
        let generation = (coverGenerations[id] ?? 0) + 1
        coverGenerations[id] = generation
        Task { @MainActor in
            if crossfade {
                // A fresh session has no frame yet right after the change notification.
                try? await Task.sleep(for: .milliseconds(600))
            }
            guard let screen = screenManager.screens.first(where: { $0.id == id }),
                  let configuration = screenManager.getConfiguration(for: screen),
                  let image = await WallpaperCoverCapture.captureWallpaper(screen: screen, configuration: configuration)?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil),
                  coverGenerations[id] == generation,
                  let index = stage.displays.firstIndex(where: { $0.id == id }) else { return }
            if crossfade, stage.displays[index].cover != nil {
                stage.crossfadeCover(display: id, to: image, duration: DesignTokens.Motion.wallpaperCrossfadeDuration)
            }
            stage.displays[index].cover = image
        }
    }

    // MARK: Shelf

    private func syncShelf() {
        guard let library else { return }
        let visible = library.visibleItems
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        stage.shelfRenderBudget = shelfCapacity
        // The whole library goes on the shelf; the stage builds layers for the slice it draws and
        // reports it back so only those previews get decoded.
        stage.shelfItems = visible.map { item in
            StageCard(
                id: item.id,
                title: item.title,
                metaLine: metaLine(for: item),
                thumbnail: item.thumbnail.flatMap { thumbnails.cached($0, pixelSize: Self.thumbnailPixelSize, scale: scale) },
                nowPlaying: NowPlayingBadge(on: item.onDisplays, among: stage.displays),
                isDraggable: item.isSupported,
                statusBadge: item.statusBadge
            )
        }
        loadShelfThumbnails()
    }

    private func loadShelfThumbnails() {
        guard let library else { return }
        let visible = library.visibleItems
        // Indices only line up while the shelf mirrors these rows; `syncShelf()` calls back in after rebuilding it.
        guard !visible.isEmpty, stage.shelfItems.map(\.id) == visible.map(\.id) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let grid = stage.visibleGridRange.clamped(to: visible.indices)
        func land(_ request: ShelfThumbnailCache.Request, pixelSize: CGSize, on id: StageCard.ID, tile: LibraryGridTile.Thumbnail?) {
            Task { @MainActor in
                guard let image = await thumbnails.image(request, pixelSize: pixelSize, scale: scale),
                      let item = library.visibleItems.first(where: { $0.id == id }),
                      // The model, not `tileSize`: this copy of the page was taken when the decode started.
                      Self.decodeIsCurrent(
                          request, tile: tile, item: item, stageWidth: stage.stageSize.width, tileSize: stage.gridTileSize,
                          scale: NSScreen.main?.backingScaleFactor ?? 2
                      )
                else { return }
                stage.landThumbnail(image, for: id)
            }
        }
        // A card leaving a scrolled grid may never have been on the shelf: the tile's own decode is what it showed.
        let missing = stage.refreshShelfThumbnails {
            visible[$0].thumbnail.flatMap { thumbnails.cached($0, pixelSize: Self.thumbnailPixelSize, scale: scale) }
                ?? gridThumbnail(for: visible[$0]).flatMap { Self.gridImage($0, in: thumbnails) }
        }
        for index in missing where !grid.contains(index) {
            if let request = visible[index].thumbnail {
                land(request, pixelSize: Self.thumbnailPixelSize, on: visible[index].id, tile: nil)
            }
        }
        // A card bound for the grid wears its tile's own decode, which is the image that tile mounts with.
        for index in grid {
            guard let tile = gridThumbnail(for: visible[index]) else { continue }
            if let image = thumbnails.cached(tile.request, pixelSize: tile.pixelSize, scale: tile.scale) {
                if stage.shelfItems[index].thumbnail !== image {
                    stage.landThumbnail(image, for: visible[index].id)
                }
            } else {
                land(tile.request, pixelSize: tile.pixelSize, on: visible[index].id, tile: tile)
            }
        }
    }

    /// GAP_ANALYSIS §6: `视频 · 4K · 1:32`, `网页 · 域名`, `场景`, `Aerial · 地点`.
    private func metaLine(for item: LibraryItem) -> String {
        var parts = [item.kind.localizedName]
        switch item.source {
        case let .bookmark(bookmark):
            if case let .html(source, _) = bookmark.content, case let .url(url) = source, let host = url.host() {
                parts.append(host)
            }
        case let .aerial(asset):
            if let category = asset.category {
                parts.append(category)
            }
        #if !LITE_BUILD
        case .workshop:
            break
        #endif
        }
        if case let .video(video)? = item.metadata {
            if let label = item.metadata?.resolutionShortLabel {
                parts.append(label)
            }
            if let duration = video.duration {
                parts.append(Self.durationText(duration))
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Events

    private func consumeEvents() async {
        for await event in stage.events {
            switch event {
            case let .displayTapped(id):
                let screen = screenManager.screens.first { $0.id == id }
                router.showDetail(id, failureID: screen.flatMap { screenManager.wallpaperLoads.attempt(for: $0)?.failure?.id })
            case let .snapped(index):
                if index < 2 {
                    // Here, not when the grid disappears: the nav pill unmounts it before the stage reads where the cards leave from.
                    stage.gridScrollOffset = 0
                }
                // The slide the nav pill runs when it is clicked.
                withAnimation(DesignTokens.motion(stage.reduceMotion, .snappy(duration: 0.18))) {
                    if index == 2, router.page == .home {
                        pageChangeFromStage = true
                        router.select(.library)
                    } else if index < 2, router.page == .library {
                        pageChangeFromStage = true
                        router.select(.home)
                    }
                }
            case let .playbackTapped(id, action):
                guard let screen = screenManager.screens.first(where: { $0.id == id }) else { continue }
                switch action {
                case .toggle:
                    guard let controller = screen.playbackController else { continue }
                    DisplayDetailHost.togglePlayback(controller)
                    screenManager.markWallpaperSessionStateChanged()
                case .next:
                    screenManager.advancePlaylist(for: screen)
                case .previous:
                    screenManager.regressPlaylist(for: screen)
                }
            case let .emptyActionTapped(id, action):
                guard let screen = screenManager.screens.first(where: { $0.id == id }) else { continue }
                switch action {
                case .chooseFile:
                    promptImport(onto: screen)
                case .pasteURL:
                    pastedAddress = ""
                    pasteURLTarget = id
                }
            case let .dropped(cardID, displayID):
                applies.run(for: displayID) { await applyCard(cardID, to: displayID, cancellation: $0) }
            case let .filesDropped(urls, displayID):
                guard let screen = screenManager.screens.first(where: { $0.id == displayID }),
                      let intent = ApplyIntent.drop(urls) else { continue }
                applies.run(for: displayID) { await apply(intent, to: screen, card: nil, shakesDisplay: true, cancellation: $0) }
            case let .filesDroppedOnShelf(urls):
                importToLibrary(urls)
            case let .cardTapped(cardID):
                presentedItemID = cardID
            case let .cardApplyRequested(cardID):
                quickApply(cardID)
            case .dropCancelled:
                continue
            }
        }
    }

    /// VoiceOver's "Apply" and an ⌥-click: a drop without the drag, onto the display `quickApplyTarget` picks.
    private func quickApply(_ cardID: StageCard.ID) {
        let screens = screenManager.screens
        guard let target = Self.quickApplyTarget(
            displays: screens.map(\.id),
            main: screens.first { CGDisplayIsMain($0.id) != 0 }?.id,
            libraryTarget: router.libraryTarget
        ) else { return }
        applies.run(for: target) { await applyCard(cardID, to: target, cancellation: $0) }
    }

    static func quickApplyTarget(
        displays: [CGDirectDisplayID], main: CGDirectDisplayID?, libraryTarget: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let libraryTarget, displays.contains(libraryTarget) {
            return libraryTarget
        }
        return main ?? displays.first
    }

    private func applyCard(_ cardID: StageCard.ID, to displayID: CGDirectDisplayID, cancellation: ApplyCancellation) async {
        guard let item = library?.items.first(where: { $0.id == cardID }),
              let screen = screenManager.screens.first(where: { $0.id == displayID }),
              let intent = ModalActions.intent(for: item) else {
            stage.shake(card: cardID)
            if library?.items.first(where: { $0.id == cardID })?.isSupported == false {
                toasts.post(String(localized: "Can't run on this Mac", bundle: .appLanguage), style: .failure)
            }
            return
        }
        await apply(intent, to: screen, card: cardID, cancellation: cancellation)
    }

    /// `shakesDisplay`: a Finder drop onto the stage has no card to shake, so a rejection shakes the display.
    /// `group`: the recording of an apply to several displays, which announces them once, together.
    private func apply(
        _ intent: ApplyIntent, to screen: Screen, card: StageCard.ID?, shakesDisplay: Bool = false,
        cancellation: ApplyCancellation, group: UndoRecording? = nil
    ) async {
        let router = ApplyRouter(
            manager: screenManager, bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)
        )
        let replacesOverlay = if case .scheme = intent {
            true
        } else {
            false
        }
        let recording = group ?? undo?.begin(.applyWallpaper, displays: [screen], includesOverlay: replacesOverlay)
        let report = await router.apply(intent, to: screen, cancellation: cancellation)
        let undoStepID = recording?.settle(screen.id, applied: report.outcome == .applied)
        if group != nil, let undoStepID {
            toasts.post(
                ApplyOutcome.appliedToAllText(wallpapersOn: screenManager.wallpapersGloballyEnabled), style: .success,
                undoStepID: undoStepID
            )
        }
        guard !Task.isCancelled, !report.cancelled else { return }
        if report.exitedSpanMode {
            toasts.post(String(localized: "Left span mode", bundle: .appLanguage), style: .info)
        }
        switch report.outcome {
        case .applied:
            // The group's own toast covers this display.
            guard group == nil else { break }
            let wallpapersOn = screenManager.wallpapersGloballyEnabled
            let text = if let count = report.queuedVideos, wallpapersOn {
                String(
                    localized: "Created a playlist of \(count) videos on \(screen.name)", bundle: .appLanguage,
                    comment: "Toast after several videos dropped together became a display's playlist. Placeholders are the video count and a display name."
                )
            } else {
                ApplyOutcome.appliedText(on: screen.name, wallpapersOn: wallpapersOn)
            }
            toasts.post(text, style: .success, screenID: screen.id, undoStepID: undoStepID)
        case let .registeredPreset(name):
            toasts.post(ApplyOutcome.registeredPresetText(name), style: .info)
        case let .failed(failure):
            toasts.post(failure.toastText, style: .failure, screenID: screen.id)
            if let card {
                stage.shake(card: card)
            } else if shakesDisplay {
                stage.shake(display: screen.id)
            }
        case let .prepareFailed(reason, attemptID):
            // A Pro scene attempt has already raised its failure card, which opens that attempt.
            if attemptID == nil {
                toasts.post(reason, style: .failure, screenID: screen.id)
            }
            if let card {
                stage.shake(card: card)
            } else if shakesDisplay {
                stage.shake(display: screen.id)
            }
        case .importingLibrary:
            // Not a rejection: the batch import reports its progress and result on its own card.
            break
        }
        switch report.outcome {
        case .applied, .failed(.sourceMissing), .failed(.videoBookmarkFailed), .failed(.htmlBookmarkFailed):
            // Not awaited: the display reads as preparing until this returns, and a probe can queue behind previews.
            if let library {
                Task { await library.recheck(intent) }
            }
        default:
            break
        }
    }

    /// The modal's apply path: the same queue and toasts as a drop, minus the card to shake.
    private func applyFromModal(_ intent: ApplyIntent, to displayID: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == displayID }) else { return }
        applies.run(for: displayID) { await apply(intent, to: screen, card: nil, cancellation: $0) }
    }

    /// The modal's All Displays, recorded as one undo step.
    private func applyAllFromModal(_ intent: ApplyIntent, to displayIDs: [CGDirectDisplayID]) {
        let screens = displayIDs.compactMap { id in screenManager.screens.first { $0.id == id } }
        let group = undo?.begin(.applyToAllDisplays, displays: screens)
        for screen in screens {
            applies.run(for: screen.id) { await apply(intent, to: screen, card: nil, cancellation: $0, group: group) }
        }
    }

    /// The menu bar's "+" names the display it was pressed for, so a picker that fell back to the
    /// main one would import onto a display the user never pointed at.
    private func consumeAddWallpaperRequest() {
        guard let request = router.pendingAddWallpaper else { return }
        router.pendingAddWallpaper = nil
        presentedItemID = nil
        router.closeDetail()
        guard let id = request.targetDisplayID else {
            promptImport()
            return
        }
        guard let screen = screenManager.screens.first(where: { $0.id == id }) else {
            toasts.post(
                String(localized: "The selected display is no longer available.", bundle: .appLanguage),
                style: .failure
            )
            return
        }
        promptImport(onto: screen)
    }

    /// The overview card and an untargeted add request: routed like a Finder drop onto the main display.
    private func promptImport() {
        guard let screen = screenManager.screens.first(where: { CGDisplayIsMain($0.id) != 0 }) ?? screenManager.screens.first else { return }
        promptImport(onto: screen)
    }

    /// This address-only prompt accepts remote URLs; the general HTML parser also supports inline content.
    private func applyPastedAddress(to displayID: CGDirectDisplayID) {
        guard let url = pastedWebsiteURL else {
            toasts.post(String(localized: "Enter a valid HTTP or HTTPS address.", bundle: .appLanguage), style: .failure)
            return
        }
        guard let screen = screenManager.screens.first(where: { $0.id == displayID }) else { return }
        applies.run(for: displayID) { await apply(.html(.url(url)), to: screen, card: nil, cancellation: $0) }
    }

    private func promptImport(onto screen: Screen) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = String(
            localized: "Import and Apply", bundle: .appLanguage,
            comment: "File picker confirm button: the chosen file joins the Wallpaper Library and goes on one display."
        )
        panel.message = String(
            localized: "Adds the file to the Wallpaper Library and applies it to \(screen.name).", bundle: .appLanguage,
            comment: "File picker message. Placeholder is a display name."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        applies.run(for: screen.id) { await apply(.droppedFile(url), to: screen, card: nil, cancellation: $0) }
    }

    private func promptLibraryImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = String(
            localized: "Add to Library", bundle: .appLanguage,
            comment: "File picker confirm button: the chosen files join the Wallpaper Library. Also the shelf's label while files are dragged over it."
        )
        panel.message = String(
            localized: "Adds the selected files to the Wallpaper Library without changing any display.", bundle: .appLanguage,
            comment: "File picker message for the Wallpaper Library's import."
        )
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        SettingsManager.shared.saveLastUsedDirectory(first.deletingLastPathComponent())
        importToLibrary(panel.urls)
    }

    private func importToLibrary(_ urls: [URL]) {
        let outcome = LibraryImporter(bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)).add(urls)
        #if !LITE_BUILD
        if !outcome.projectFolders.isEmpty {
            WorkshopFolderImportCoordinator.shared.importProjects(from: outcome.projectFolders)
        }
        #endif
        if let summary = outcome.summary {
            toasts.post(summary, style: outcome.failed == 0 ? .success : .failure)
        }
    }
}

/// The grid's page colour under the cards, filling in over the flight's last stretch so the grid takes over on it.
private struct LibraryPageUnderlay: View {
    /// Read in this `body`: read in `HomePage.body`, progress would re-run the whole page every frame.
    let stage: EditDeskStageModel

    var body: some View {
        DesignTokens.EditDesk.Colors.background
            .padding(.top, StageGeometry.gridTop)
            .opacity(HomeHints.ramp(stage.progress, from: 1.6, to: 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Rides the filter row on the shelf. `progress` is read here rather than in `HomePage.body` so a
/// frame of the gesture invalidates this layer alone, and the ride runs on `.offset`/`.opacity`
/// because a per-frame `.padding` would re-run the page's layout.
struct ShelfChromeRide: ViewModifier {
    let stage: EditDeskStageModel
    /// Below this the row is too faint to aim at, so it is neither clickable nor a tab stop.
    static let interactiveOpacity = 0.5

    /// Lags the shelf's own rise: the row belongs to cards that are not on screen yet.
    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 0.45, to: 0.95)
    }

    func body(content: Content) -> some View {
        let opacity = Self.opacity(stage.progress)
        return content
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: StageGeometry.chipRowTop(progress: stage.progress, windowSize: stage.stageSize))
            .opacity(opacity)
            .allowsHitTesting(opacity > Self.interactiveOpacity)
            .accessibilityHidden(opacity <= Self.interactiveOpacity)
    }
}

/// Tells the stage whether the grid sits at its top, which is what lets a pull-down hand the
/// gesture back to it, and how far it is scrolled, which is where the cards leave from. Below
/// macOS 15 there is no scroll geometry: the handoff stays off and the cards leave from the top.
private struct GridTopReporter: ViewModifier {
    let atTop: (Bool) -> Void
    let offset: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top + 0.5
                } action: { _, isAtTop in
                    atTop(isAtTop)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, scrolled in
                    offset(scrolled)
                }
                .onAppear {
                    atTop(true)
                    offset(0)
                }
                .onDisappear { atTop(false) }
        } else {
            content.onAppear { atTop(false) }
        }
    }
}

/// Full-library tile at p = 2. Thumbnails come from `ShelfThumbnailCache` like the shelf cards.
struct LibraryGridTile: View {
    /// The item's preview at the tile's own size in backing pixels.
    struct Thumbnail: Equatable {
        let request: ShelfThumbnailCache.Request
        let pixelSize: CGSize
        let scale: CGFloat

        init(_ request: ShelfThumbnailCache.Request, tileWidth: CGFloat, scale: CGFloat) {
            // Rounded up to 64px, or a live resize would key a new decode for every tile on every frame.
            let width = (tileWidth * scale / 64).rounded(.up) * 64
            self.request = request
            pixelSize = CGSize(width: width, height: (width / StageGeometry.cardAspectRatio).rounded())
            self.scale = scale
        }
    }

    private struct Load: Equatable {
        let thumbnail: Thumbnail?
        let appearance: Int
    }

    let item: LibraryItem
    /// nil when the item has no preview to decode.
    let thumbnail: Thumbnail?
    let thumbnails: ShelfThumbnailCache
    let badges: LibraryCardBadges
    /// Held by the tile because the shared cache can evict it while the tile is still on screen.
    @State private var loaded: (thumbnail: Thumbnail, image: CGImage)?
    /// Bumped each time the tile comes back on screen: `tileTask` runs once per id, so that appearance loads again.
    @State private var appearance = 0
    /// Without it the cache fallback below would redraw the image into the off-screen body LazyVGrid keeps.
    @State private var isOffScreen = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var image: CGImage? {
        guard let thumbnail, !isOffScreen else { return nil }
        if let loaded, loaded.thumbnail == thumbnail {
            return loaded.image
        }
        return HomePage.gridImage(thumbnail, in: thumbnails)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // An overlay, not a ZStack sibling: `scaledToFill` reports the picture's own proportions, which would size the tile.
            DesignTokens.Colors.surfaceRaised
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: item.kind == .web ? "globe" : item.kind == .scene ? "cube.transparent" : item.kind == .aerial ? "sparkles" : "play.rectangle")
                            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            if item.statusBadge != nil {
                LibraryTileUnavailableVeil()
            }
            LinearGradient(
                colors: [.clear, DesignTokens.EditDesk.Colors.gradientCardBottom],
                startPoint: .center, endPoint: .bottom
            )
            Group {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .strokeBorder(
                        contrast == .increased
                            ? DesignTokens.EditDesk.Colors.cardRimRingIncreased : DesignTokens.EditDesk.Colors.cardRimRing,
                        lineWidth: 1
                    )
                VStack(spacing: 0) {
                    Rectangle().fill(DesignTokens.EditDesk.Colors.cardRimHighlight).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(DesignTokens.EditDesk.Colors.cardRimShade).frame(height: 1)
                }
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(DesignTokens.EditDesk.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .lineLimit(1)
                if let status = item.statusBadge {
                    Text(verbatim: status)
                        .font(DesignTokens.EditDesk.Typography.metaMono)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.warning)
                        .lineLimit(1)
                }
            }
            .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        .overlay(alignment: .topLeading) {
            if let nowPlaying = badges.nowPlaying {
                NowPlayingCapsule(badge: nowPlaying, animates: nowPlaying.isLive)
                    .padding(DesignTokens.EditDesk.Spacing.s8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if badges.needsUpdate {
                ThumbnailBadge("Needs Update", systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                    .padding(DesignTokens.EditDesk.Spacing.s8)
            }
        }
        .aspectRatio(StageGeometry.cardAspectRatio, contentMode: .fit)
        .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .settledHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: item.title))
        // LazyVGrid may keep a scrolled-away tile alive, and any image the tile holds with it.
        .onAppear {
            // Bumped on the way back rather than on the way out, so the id never changes off screen.
            if isOffScreen {
                isOffScreen = false
                appearance += 1
            }
        }
        .onDisappear {
            isOffScreen = true
            loaded = nil
        }
        .tileTask(id: Load(thumbnail: thumbnail, appearance: appearance)) {
            guard let thumbnail,
                  let decoded = await thumbnails.image(thumbnail.request, pixelSize: thumbnail.pixelSize, scale: thumbnail.scale),
                  !Task.isCancelled else { return }
            loaded = (thumbnail, decoded)
        }
    }
}
