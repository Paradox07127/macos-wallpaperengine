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
    @Environment(PageGuideSession.self) private var pageGuide: PageGuideSession?
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    @Environment(WallpaperExportService.self) private var exportService: WallpaperExportService?
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
    @State private var modalContentReady = false
    @State private var thumbnails = ShelfThumbnailCache()
    /// Set before a stage snap changes `router.page`, so that change is not echoed back as a command.
    @State private var pageChangeFromStage = false
    /// Bumped per display before each capture; a capture that finishes after a newer one started is dropped.
    @State private var coverGenerations: [CGDirectDisplayID: Int] = [:]
    /// The generation whose capture last became a display's cover; behind `coverGenerations` while a newer one is out.
    @State private var landedCoverGenerations: [CGDirectDisplayID: Int] = [:]
    @State private var coverTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    /// `coverSignature` at each display's last configuration commit; a nil value is a removed configuration.
    @State private var coverSignatures: [CGDirectDisplayID: ScreenConfiguration?] = [:]
    #if !LITE_BUILD
    /// Per display, the earliest its Workshop cover may be saved; none for a display that has not switched since the page opened.
    @State private var workshopCoverNotBefore: [CGDirectDisplayID: ContinuousClock.Instant] = [:]
    #endif
    @State private var applies = ApplyQueue()
    /// The library item the S4 modal shows; nil when closed.
    @State private var presentedItemID: String?
    @State private var modalDetailTarget: CGDirectDisplayID?
    @State private var modalReturnPending = false
    @State private var modalHandoffGeneration = 0
    @State private var modalReturn: (itemID: String, page: EditDeskRouter.Page, target: CGDirectDisplayID?)?
    @State private var modalDetailPreview: (display: CGDirectDisplayID, image: CGImage, configuration: ScreenConfiguration)?
    @State private var libraryGridOpacity = 0.0
    @State private var libraryHandoffGeneration = 0
    /// A wallpaper dragged from the modal's preview or a grid tile toward the displays.
    @State private var libraryDrag = LibraryDragController()
    /// Which grid tile plays its GIF preview on hover.
    @State var gridPreview = LibraryGridPreview()
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

        /// One action on several displays: the group is entered before the tasks are made, so each inherits it.
        func runEach(_ screens: [Screen], _ work: @escaping @MainActor (Screen, ApplyCancellation) async -> Void) {
            let group = WallpaperSwitchGroup.forManualAction()
            // Each apply awaits before it dispatches, so the barrier has to know every display up front.
            for screen in screens {
                group.barrier.expect(screen.id)
            }
            WallpaperSwitchGroup.$current.withValue(group) {
                for screen in screens {
                    run(for: screen.id) { cancellation in
                        await work(screen, cancellation)
                        group.barrier.abandon(screen.id)
                    }
                }
            }
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
                .onChange(of: page.tileSize) {
                    page.stage.gridTileSize = page.tileSize
                    // The grid's range can stay put while its tiles change size, and only a range change reloads.
                    page.loadShelfThumbnails()
                }
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
            shelfUpdates(content: content)
                // The rename path: a display's drawn name comes out of these rows. Watched on the
                // whole library rather than the filtered rows, which also change on every keystroke.
                .onChange(of: page.library?.items) { page.refreshAllStates() }
                .onChange(of: page.shelfCapacity) { page.syncShelf() }
                .onChange(of: page.stage.visibleShelfRange) { page.loadShelfThumbnails() }
                .onChange(of: page.stage.visibleGridRange) { page.loadShelfThumbnails() }
        }

        private func shelfUpdates(content: Content) -> some View {
            content
                .onChange(of: page.library?.visibleItems) { page.syncShelf() }
                #if !LITE_BUILD
                .onChange(of: WPEPropertyLabelTranslator.wallpaperNames.revision) { page.refreshWallpaperNames() }
                #endif
                // State refreshes rewrite `stage.displays` without rebuilding the cards, whose capsules wave by it.
                .onChange(of: page.drawingDisplayIDs) { page.syncShelf() }
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
                .onChange(of: page.installedLibrary.updatedWorkshopIDs, initial: true) {
                    page.library?.updatedWorkshopIDs = page.installedLibrary.updatedWorkshopIDs
                }
                .onChange(of: page.installedLibrary.errorMessage, initial: true) {
                    HomePage.postInstalledLibraryError(page.installedLibrary, to: page.toasts)
                }
        }
    }

    /// Takes the model's error as it posts it, so the same failure never toasts twice.
    static func postInstalledLibraryError(_ model: InstalledLibraryModel, to toasts: EditDeskToastCenter) {
        guard let message = model.errorMessage else { return }
        toasts.post(message, style: .failure)
        model.errorMessage = nil
    }
    #endif

    /// Its own modifier for the same reason `LibraryHooks` is split off `SyncHooks`.
    private struct BrowseHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.stage.snappedIndex) {
                    clearSearchAtOverview()
                    page.syncBrowsing()
                }
                .onChange(of: page.presentedItemID) { page.syncBrowsing() }
                // The model outlives this view: a browse left open would keep ranking by its old snapshot.
                .onDisappear { page.library?.endBrowsing() }
                // Initial too: the model outlives this view, so a query can arrive with a mount on the overview.
                .onChange(of: page.router.page, initial: true) {
                    clearSearchAtOverview()
                }
                // Initial too: rows added while another page showed have no tags read for the kept query.
                .onChange(of: page.library?.query, initial: true) { Task { await page.library?.loadSearchTags() } }
        }

        private func clearSearchAtOverview() {
            // The shelf now has its own visible search control; retain its active query.
            if page.router.page == .home, page.stage.snappedIndex == 0 {
                page.library?.query = ""
            }
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
                    if page.handlesEscape, page.pageGuide?.context == nil {
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
                    Button("Rename") { page.rename(id, to: page.renameDraft) }
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
                // Clear item details before presenting the tour over the page.
                page.presentedItemID = nil
                switch step {
                case .home:
                    // Explain the display arrangement from its resting state.
                    page.stage.setProgress(0, animated: !page.reduceMotion)
                case .library, .workshop, .configuration, .overlay, .settings:
                    break
                }
            }
        }
    }

    private var shelfStyle: ShelfStyle {
        ShelfStyle(rawValue: shelfStyleRaw) ?? EditDeskPreferences.shelfStyleDefault
    }

    /// The stage ignores wheel and clicks while anything is presented over it or a library drag runs.
    fileprivate var interactionLock: Bool {
        presentedItemID != nil || router.detailDisplayID != nil || detailBusy || libraryDrag.payload != nil
    }

    /// A display's detail page is asked for or up: the overview's own layers go from under it.
    private var detailCovers: Bool {
        router.detailDisplayID != nil
    }

    private var topBarCovered: Bool {
        router.detailDisplayID != nil || detailBusy
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
            EditDeskDotGrid(stage: stage)
                .zIndex(-1)
                .modifier(CoveredByDetail(covered: detailCovers))
            EditDeskShelfScrim(stage: stage)
                .zIndex(-1)
                .modifier(CoveredByDetail(covered: detailCovers))
            EditDeskStageRepresentable(model: stage)
            hoverPlayback
                .modifier(CoveredByDetail(covered: detailCovers))
            ShelfDropHighlight(stage: stage)
                .modifier(CoveredByDetail(covered: detailCovers))
            HomeHints(stage: stage)
                .modifier(CoveredByDetail(covered: detailCovers))
            HoverCardName(stage: stage, library: library, enabled: router.page == .home && !interactionLock)
                .modifier(CoveredByDetail(covered: detailCovers))
            libraryLayer
                .modifier(CoveredByDetail(covered: detailCovers))
            shelfChrome
                .zIndex(landedOnLibrary ? 0 : -1)
                .modifier(CoveredByDetail(covered: detailCovers))
            wallpapersOffBanner
                .modifier(CoveredByDetail(covered: detailCovers))
            TopBar(
                page: pageBinding,
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stage.stageSize.width,
                status: statusCapsule
            )
            // Hidden and unhittable is not enough: the status capsule's focus and Escape handler would still respond under the detail page.
            .disabled(topBarCovered)
            .modifier(CoveredByDetail(covered: topBarCovered))
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
                busy: $detailBusy, toasts: toasts, onPresentationReady: modalDetailReady,
                previewFallback: modalPreview, backLabel: modalReturn == nil ? "Overview" : "Back",
                onBack: beginModalReturn, coveredPresentation: modalReturn != nil,
                onPresentationClosed: finishModalReturn
            )
            if let library, let modalActions {
                LibraryModalHost(
                    library: library, stage: stage, drag: libraryDrag, actions: modalActions,
                    requestRename: requestRename, requestDelete: requestDelete,
                    presentedItemID: $presentedItemID, preferredTarget: router.libraryTarget, applying: applies.inFlight,
                    currentCovers: currentCoverDisplays, showDisplay: showDisplayFromModal,
                    previewSeed: { item in
                        guard let thumbnail = gridThumbnail(for: item) else { return nil }
                        return Self.gridImage(thumbnail, in: thumbnails)
                    }, retainsUntilDetailReady: true, prepareDetail: { id, image in
                        guard let image, let screen = screenManager.screen(withID: id),
                              let configuration = screenManager.getConfiguration(for: screen) else { return }
                        modalDetailPreview = (id, image, configuration)
                    }, retainedItemID: modalReturn?.itemID,
                    contentReady: presentedItemID != nil && modalContentReady,
                    prepareDetailContent: { item in
                        #if !LITE_BUILD
                        for id in item.onDisplays {
                            guard let screen = screenManager.screen(withID: id),
                                  let configuration = screenManager.getConfiguration(for: screen),
                                  case let .scene(descriptor) = configuration.activeWallpaper,
                                  WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: configuration.wpeOrigin) == nil else { continue }
                            _ = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: configuration.wpeOrigin)
                        }
                        #endif
                    }
                )
            }
        }
        // Here, over both: a grid tile's drag is hit-tested against a strip `LibraryModalHost` draws.
        .coordinateSpace(name: EditDeskCoordinateSpace.name)
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
            stage.cardMenu = { id in library?.items.first { $0.id == id }.map { libraryMenu(for: $0) } ?? [] }
            syncDisplays()
            if router.page == .library {
                stage.setProgress(2, animated: false)
            } else if HomeDefaultState(rawValue: homeDefaultRaw) == .halfOpen, stage.progress == 0,
                      pageGuide?.context != .overview, screenManager.wallpapersGloballyEnabled {
                // Off, the stage stays at rest: the banner that turns wallpapers back on only shows there.
                stage.setProgress(1, animated: false)
            }
        }
        // These closures capture this view, whose state owns the objects holding them: left set, the page is never freed.
        .onDisappear {
            for task in coverTasks.values {
                task.cancel()
            }
            coverTasks.removeAll()
            modalHandoffGeneration += 1
            modalReturnPending = false
            stage.displayMenu = nil
            stage.cardMenu = nil
            modalActions?.detach()
            modalActions = nil
        }
        .task { await consumeEvents() }
        .modifier(SyncHooks(page: self))
        .modifier(BrowseHooks(page: self))
        .modifier(LibraryTargetHook(page: self))
        .modifier(OnboardingStepHook(page: self))
        .modifier(ApplyHook(page: self))
        .modifier(DisplayCommands(page: self))
        .modifier(LibraryItemCommands(page: self))
        .onChange(of: router.detailDisplayID) { _, id in
            if id == nil {
                returnToModal()
            }
        }
        .onChange(of: presentedItemID) { _, id in
            if id == nil {
                modalContentReady = false
            }
            if id == nil, modalDetailTarget != nil || modalReturnPending {
                let origin = modalReturn
                modalHandoffGeneration += 1
                modalReturnPending = false
                modalDetailTarget = nil
                modalReturn = nil
                router.closeDetail()
                if let origin {
                    router.select(origin.page)
                    router.libraryTarget = origin.target
                }
            }
        }
        .onChange(of: pageGuide?.context) {
            if pageGuide?.context != nil {
                presentedItemID = nil
            }
            if router.page == .home, pageGuide?.context == .overview {
                stage.setProgress(0, animated: !reduceMotion)
            }
        }
        .onChange(of: router.pendingAddWallpaper, initial: true) { consumeAddWallpaperRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in syncDisplays() }
        // Switching HDR keeps the layout signature, so ScreenManager skips its refresh and never posts `.screensRefreshed`.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in syncDisplays() }
        .onChange(of: configurationRevisions) { old, new in configurationsCommitted(from: old, to: new) }
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
        let configured = screenManager.getConfiguration(for: screen) != nil
        let others = screenManager.screens.filter { $0.id != screen.id }.sorted { $0.frame.minX < $1.frame.minX }
        let wallpaper = [
            StageMenuItem(title: String(localized: "Reload", bundle: .appLanguage), isEnabled: configured) {
                screenManager.reloadWallpaperForScreen(screen)
            },
            StageMenuItem(
                title: String(localized: "Apply to", bundle: .appLanguage), isEnabled: configured && !others.isEmpty,
                submenu: [
                    others.map { target in
                        StageMenuItem(title: target.name, isEnabled: true) { applyConfiguration(from: screen, to: target) }
                    },
                    [StageMenuItem(title: String(localized: "All Displays", bundle: .appLanguage), isEnabled: others.count > 1) {
                        pendingDestructive = PendingDestructive(
                            .applyConfigurationToAllDisplays(otherCount: others.count)
                        ) {
                            applyConfigurationToAllDisplays(from: screen)
                        }
                    }],
                ]
            ) {},
        ]
        let naming = [
            StageMenuItem(
                title: String(
                    localized: "Rename Display", bundle: .appLanguage,
                    comment: "Context menu item on a display on the home page stage that opens the rename alert, and that alert's title."
                ),
                isEnabled: true
            ) {
                renameDraft = screen.name
                renameTarget = id
            },
            StageMenuItem(title: String(localized: "Use System Name", bundle: .appLanguage), isEnabled: screen.customName != nil) {
                screenManager.setCustomName(nil, for: screen)
                syncDisplays()
            },
        ]
        let clear = [
            StageMenuItem(title: String(localized: "Clear Wallpaper", bundle: .appLanguage), isEnabled: configured, isDestructive: true) {
                requestClearWallpaper(on: screen)
            },
        ]
        return [wallpaper, naming, clear]
    }

    /// Neither the stage's name row nor the shelf's now-playing capsules watch the name, so both are redrawn here.
    private func rename(_ id: CGDirectDisplayID, to name: String) {
        guard let screen = screenManager.screens.first(where: { $0.id == id }) else { return }
        screenManager.setCustomName(name, for: screen)
        syncDisplays()
    }

    private func requestClearWallpaper(on screen: Screen) {
        pendingDestructive = PendingDestructive(.clearCurrentWallpaper(displayName: screen.name)) {
            clearWallpaper(on: screen)
        }
    }

    private func clearWallpaper(on screen: Screen) {
        // An apply still preparing would otherwise land after the clear and bring the wallpaper back.
        applies.cancel(screen.id)
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
        guard let content = screenManager.getConfiguration(for: screen)?.activeWallpaper else { return }
        let recording = undo?.begin(
            .applyToAllDisplays, displays: screenManager.screens.filter { $0.id != screen.id }, requiresConfigurationCommit: true
        )
        screenManager.applyConfigurationToAllDisplays(from: screen)
        recording?.announce(
            ApplyOutcome.appliedToAllText(wallpapersOn: screenManager.wallpapersGloballyEnabled), showing: content, to: toasts
        )
    }

    private func applyConfiguration(from source: Screen, to target: Screen) {
        guard let content = screenManager.getConfiguration(for: source)?.activeWallpaper else { return }
        let recording = undo?.begin(.applyWallpaper, displays: [target], requiresConfigurationCommit: true)
        screenManager.applyConfiguration(from: source, to: target)
        recording?.announce(
            ApplyOutcome.appliedText(on: target.name, wallpapersOn: screenManager.wallpapersGloballyEnabled), showing: content, to: toasts
        )
    }

    // MARK: Library item commands

    private func makeModalActions(library: SavedLibraryModel) -> ModalActions {
        #if LITE_BUILD
        ModalActions(
            library: library, screenManager: screenManager, thumbnails: thumbnails, undo: undo,
            exportService: exportService, confirm: { pendingDestructive = $0 },
            apply: applyFromModal, applyToAll: applyAllFromModal
        )
        #else
        if let doctor {
            return ModalActions(
                library: library, screenManager: screenManager, thumbnails: thumbnails, doctor: doctor,
                installedLibrary: installedLibrary, undo: undo, exportService: exportService,
                confirm: { pendingDestructive = $0 }, apply: applyFromModal, applyToAll: applyAllFromModal
            )
        }
        return ModalActions(
            inputs: .live(library: library, screenManager: screenManager), bookmarks: .shared,
            thumbnails: thumbnails, undo: undo, exportService: exportService,
            confirm: { pendingDestructive = $0 }, apply: applyFromModal, applyToAll: applyAllFromModal
        )
        #endif
    }

    private func libraryItem(_ id: String?) -> LibraryItem? {
        library?.items.first { $0.id == id }
    }

    /// A grid tile's or shelf card's context menu: the sections of that item's "…" menu in the modal.
    private func libraryMenu(for item: LibraryItem) -> [[StageMenuItem]] {
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
        chipsRow.pageGuideTarget(.libraryTools)
            .modifier(ShelfChromeRide(stage: stage))
    }

    /// Keep the wallpaper-off banner on the resting overview, clear of details and modals.
    private var isRestingOverview: Bool {
        router.page == .home && stage.atRest && !interactionLock
    }

    private var offBannerClaimsStage: Bool {
        isRestingOverview && !screenManager.wallpapersGloballyEnabled
    }

    /// The top band the display arrangement leaves to the off banner.
    fileprivate var stageTopInset: CGFloat {
        if offBannerClaimsStage {
            offBannerHeight + DesignTokens.EditDesk.Spacing.gutter
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

    private var libraryLayer: some View {
        ZStack {
            if isLibraryOpen {
                wallpaperGrid
                    .padding(.top, StageGeometry.topBarHeight)
                    // Hidden rather than unmounted while the stage carries the cards off: unmounting here would
                    // lose the scroll position, and a swipe pushed back would rebuild the grid at its top.
                    .opacity(stage.leavingLibrary ? 0 : libraryGridOpacity)
                    .allowsHitTesting(!stage.leavingLibrary)
                    .accessibilityHidden(stage.leavingLibrary)
                    .transition(.identity)
            }
        }
        .onChange(of: isLibraryOpen, initial: true) { _, open in coverLandedCards(gridOpen: open) }
        .onChange(of: reduceMotion) { _, _ in coverLandedCards(gridOpen: isLibraryOpen) }
    }

    /// The grid has no fill, so the cards the stage landed under it stop drawing once it has faded in
    /// over them; the stage itself shows them again the moment a return starts.
    private func coverLandedCards(gridOpen: Bool) {
        libraryHandoffGeneration += 1
        let generation = libraryHandoffGeneration
        stage.gridCoversCards = false
        guard gridOpen else {
            libraryGridOpacity = 0
            return
        }
        withAnimation(DesignTokens.motion(reduceMotion, .easeOut(duration: Self.libraryFadeDuration)), completionCriteria: .removed) {
            libraryGridOpacity = 1
        } completion: {
            guard generation == libraryHandoffGeneration, isLibraryOpen, !stage.leavingLibrary else { return }
            stage.gridCoversCards = true
        }
    }

    private var isLibraryOpen: Bool {
        Self.mountsLibraryGrid(
            page: modalReturn?.page == .library ? .library : router.page,
            snappedIndex: stage.snappedIndex, pastHandoff: stage.pastLibraryHandoff,
            leaving: stage.leavingLibrary
        )
    }

    /// The display the library was opened for, while its banner shows above the grid.
    private var libraryTargetScreen: Screen? {
        (modalReturn?.target ?? router.libraryTarget).flatMap { target in screenManager.screens.first { $0.id == target } }
    }

    /// Between the display banner and the grid inside the library's scroll view.
    private static let libraryStackSpacing = DesignTokens.Spacing.sm

    /// What the library stacks above the grid's first row inside its scroll view.
    private var gridContentInset: CGFloat {
        var inset: CGFloat = 0
        if libraryTargetScreen != nil {
            inset += libraryBannerHeight + Self.libraryStackSpacing
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
    static func mountsLibraryGrid(page: EditDeskRouter.Page, snappedIndex: Int, pastHandoff: Bool, leaving: Bool = false) -> Bool {
        page == .library && snappedIndex == 2 && (leaving || pastHandoff)
    }

    private var statusCapsule: StatusCapsule {
        StatusCapsule(
            content: StatusCapsuleContent(rawValue: statusCapsuleRaw) ?? EditDeskPreferences.statusCapsuleContentDefault,
            footerLabels: StatusCapsuleModel.footerLabels(
                configured: screenManager.screens.filter { screenManager.getConfiguration(for: $0) != nil }.count,
                wallpapersEnabled: screenManager.wallpapersGloballyEnabled,
                pausesOnBattery: SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
            ),
            memoryPressure: { [screenManager] in screenManager.memoryPressureLevel }
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
            LibraryChipsRow(
                chips: SavedLibraryModel.Chip.allCases.map { LibraryChip(id: Self.chipID($0), title: Self.chipTitle($0)) },
                selection: chipBinding,
                searchText: queryBinding,
                searchPrompt: featureCatalog.isEnabled(.wpeImport) ? "Search by name or tag" : "Search by name",
                searchShortPrompt: "Search",
                stage: stage,
                sort: Binding(get: { library?.sort ?? .recentlyUsed }, set: { library?.sort = $0 }),
                filter: Binding(get: { library?.filter }, set: { library?.filter = $0 }),
                filterCount: {
                    #if LITE_BUILD
                    switch $0 {}
                    #else
                    return library?.count(of: $0) ?? 0
                    #endif
                },
                onImport: promptLibraryImport,
                keepsImportOnShelf: library?.items.isEmpty == true,
                showsAerialsControls: library?.chip == .aerials && library?.aerialsStatus.isAuthorized == true
            )
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

    /// The detail page's transport over the display under the pointer, at the slot the stage reports.
    private var hoverPlayback: some View {
        ZStack {
            if let playback = stage.hoveredPlayback {
                ZStack {
                    transport(playback)
                    GlassIconButton("trash", role: .destructive) { stage.emit(.clearWallpaperTapped(playback.displayID)) }
                        .help(Text("Clear Wallpaper"))
                        .position(x: playback.clearRect.midX, y: playback.clearRect.midY)
                }
                // One view per display: moving straight onto another fades rather than slides across the gap.
                .id(playback.displayID)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(!interactionLock)
        // VoiceOver presses these through the display's own actions on the stage.
        .accessibilityHidden(true)
        .animation(DesignTokens.Motion.stateChange, value: stage.hoveredPlayback?.displayID)
    }

    private func transport(_ playback: StagePlaybackOverlay) -> some View {
        HStack(spacing: 12) {
            if playback.showsPlaylistControls {
                GlassIconButton("backward.end.fill") { stage.emit(.playbackTapped(playback.displayID, .previous)) }
                    .disabled(!playback.canChangeEntry)
                    .help(Text("Previous Wallpaper"))
            }
            GlassIconButton(playback.glyph) { stage.emit(.playbackTapped(playback.displayID, .toggle)) }
                .disabled(!playback.canToggle)
                .help(Text(playback.intendsToPlay ? "Pause" : "Play"))
            if playback.showsPlaylistControls {
                GlassIconButton("forward.end.fill") { stage.emit(.playbackTapped(playback.displayID, .next)) }
                    .disabled(!playback.canChangeEntry)
                    .help(Text("Next Wallpaper"))
            }
        }
        .position(x: playback.rect.midX, y: playback.rect.midY)
    }

    private static func chipID(_ chip: SavedLibraryModel.Chip) -> String {
        switch chip {
        case .all: "all"
        case .bookmarks: "bookmarks"
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
        case .bookmarks: "Bookmarks"
        case .recent: "Recent"
        case .steam: "Steam"
        case .local: "Local"
        case .aerials: "Aerials"
        }
    }

    // MARK: Library page

    private enum LibraryGridContent {
        case aerialsStatus, firstRunGuide, noResults, grid
    }

    /// Which of `wallpaperGrid`'s branches is showing; nil without a library model.
    private var libraryGridContent: LibraryGridContent? {
        guard let library else { return nil }
        if library.chip == .aerials, library.aerialsStatus.isEmpty {
            return .aerialsStatus
        }
        if library.visibleItems.isEmpty {
            return library.items.isEmpty ? .firstRunGuide : .noResults
        }
        return .grid
    }

    private var wallpaperGrid: some View {
        GeometryReader { geometry in
            ScrollView {
                // Spaced explicitly: `gridContentInset` has to know how far down the first row starts.
                VStack(spacing: Self.libraryStackSpacing) {
                    if let screen = libraryTargetScreen {
                        libraryTargetBanner(for: screen)
                            .transition(.opacity)
                    }
                    if let library, library.chip == .aerials, library.aerialsStatus.isEmpty {
                        AerialsSourceStatusCard()
                            .transition(.opacity)
                    } else if let library, library.visibleItems.isEmpty {
                        if library.items.isEmpty {
                            LibraryGuideCard(
                                icon: "square.grid.2x2",
                                tint: DesignTokens.Colors.accent,
                                title: "No wallpapers yet",
                                message: "Adds the selected files to the Wallpaper Library without changing any display.",
                                actionTitle: "Add to Library",
                                actionSystemImage: "plus",
                                action: promptLibraryImport
                            )
                            .transition(.opacity)
                        } else {
                            let clearsSearch = !library.query.isEmpty
                            let clearsFilters = library.chip != .all || library.filter != nil
                            IllustratedEmptyState(
                                symbol: "magnifyingglass",
                                title: library.query.isEmpty ? "No Results" : "No results for “\(library.query)” in Wallpaper Library",
                                primary: .clearing(search: clearsSearch, filters: clearsFilters) {
                                    if clearsSearch {
                                        library.query = ""
                                    }
                                    if clearsFilters {
                                        library.chip = .all
                                        library.filter = nil
                                    }
                                }
                            )
                            .transition(.opacity)
                        }
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
                                        openLibraryItem(item.id)
                                    }
                                } label: {
                                    LibraryGridTile(
                                        item: item, thumbnail: gridThumbnail(for: item), thumbnails: thumbnails, badges: badges,
                                        preview: gridPreview
                                    )
                                }
                                .buttonStyle(.plain)
                                .libraryDragSource(libraryDrag, enabled: item.isSupported) { dragPayload(for: item) }
                                .contextMenu {
                                    WallpaperMenuRows(sections: libraryMenu(for: item))
                                }
                                .accessibilityLabel(Text(verbatim: badges.accessibilityLabel(title: item.title.translatedWallpaperName, kind: item.kind)))
                                .accessibilityValue(Text(verbatim: item.statusBadge ?? ""))
                                .accessibilityAction(named: Text("Apply")) { quickApply(item.id) }
                                .task(id: item.id) { await library.probeMetadata(for: [item.id]) }
                            }
                        }
                        .libraryGridPadding()
                        .transition(.opacity)
                    }
                }
                // Keyed on the branch, not the items: a filter change inside the grid must not animate its lazy layout.
                .animation(
                    DesignTokens.motion(reduceMotion, DesignTokens.Motion.stateChange),
                    value: libraryGridContent
                )
                .animation(
                    DesignTokens.motion(reduceMotion, DesignTokens.Motion.stateChange),
                    value: libraryTargetScreen != nil
                )
                // The reader sits inside the bars' safe-area insets, so this is the height left between them.
                .frame(minHeight: library?.visibleItems.isEmpty == true ? geometry.size.height : nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(GridTopReporter(atTop: { stage.gridAtTop = $0 }, offset: { stage.gridScrollOffset = $0 }))
            .onChange(of: interactionLock, initial: true) { gridPreview.obscured = $1 }
            .onChange(of: reduceMotion, initial: true) { gridPreview.reduceMotion = $1 }
        }
        .libraryScrollBars {
            // Reserves the chips row's band; the row itself stays on `shelfChrome` so it can ride the stage in flight.
            Color.clear
                .frame(height: StageGeometry.gridTop - StageGeometry.topBarHeight)
        } bottom: {
            if let library, !library.items.isEmpty {
                LibraryStatusBar(summary: statusSummary(library))
            }
        }
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

    private func dragPayload(for item: LibraryItem) -> LibraryDragController.Payload? {
        guard let modalActions else { return nil }
        return LibraryDragController.Payload(
            item: item, image: gridThumbnail(for: item).flatMap { Self.gridImage($0, in: thumbnails) },
            actions: modalActions.actions(for: item)
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
        if modalReturn != nil, router.detailDisplayID != nil {
            return
        }
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

    /// Start enrichment only after the first presentation; file and Steam results must not rebuild an entering panel.
    private func openLibraryItem(_ itemID: String) {
        modalHandoffGeneration += 1
        let generation = modalHandoffGeneration
        modalContentReady = false
        withAnimation(DesignTokens.Motion.modalPresentation(reduceMotion: reduceMotion), completionCriteria: .removed) {
            presentedItemID = itemID
        } completion: {
            // Paging may have selected another item while the panel was entering.
            guard presentedItemID != nil, modalHandoffGeneration == generation else { return }
            modalContentReady = true
        }
    }

    private func showDisplayFromModal(_ display: CGDirectDisplayID) {
        guard let itemID = presentedItemID else { return }
        modalHandoffGeneration += 1
        modalReturnPending = false
        if modalReturn == nil {
            modalReturn = (itemID, router.page, router.libraryTarget)
        }
        modalDetailTarget = display
        let alreadyShown = router.detailDisplayID == display && !detailBusy
        router.showDetail(display)
        if alreadyShown {
            modalDetailReady(display)
        }
    }

    private func beginModalReturn() {
        guard router.detailDisplayID != nil, !modalReturnPending else { return }
        guard let origin = modalReturn, library?.items.contains(where: { $0.id == origin.itemID }) == true else {
            router.closeDetail()
            return
        }
        modalHandoffGeneration += 1
        let generation = modalHandoffGeneration
        modalReturnPending = true
        withAnimation(DesignTokens.Motion.modalPresentation(reduceMotion: reduceMotion), completionCriteria: .removed) {
            presentedItemID = origin.itemID
        } completion: {
            guard modalReturnPending, modalHandoffGeneration == generation, presentedItemID == origin.itemID else { return }
            modalReturnPending = false
            modalContentReady = true
            router.closeDetail()
        }
    }

    private func modalDetailReady(_ display: CGDirectDisplayID) {
        guard modalDetailTarget == display else { return }
        modalDetailTarget = nil
        withAnimation(DesignTokens.Motion.modalDismissal(reduceMotion: reduceMotion)) {
            presentedItemID = nil
        }
    }

    private func modalPreview(_ id: CGDirectDisplayID) -> CGImage? {
        guard let preview = modalDetailPreview, preview.display == id,
              let screen = screenManager.screen(withID: id),
              screenManager.getConfiguration(for: screen)?.activeWallpaper == preview.configuration.activeWallpaper else { return nil }
        return preview.image
    }

    private func returnToModal() {
        guard let origin = modalReturn, router.pendingOnboardingStep == nil, pageGuide?.context == nil else { return }
        modalDetailTarget = nil
        router.select(origin.page)
        router.libraryTarget = origin.target
    }

    private func finishModalReturn() {
        guard router.detailDisplayID == nil else { return }
        modalReturnPending = false
        modalReturn = nil
        modalDetailPreview = nil
    }

    // MARK: Displays

    /// Its own property: inlined in `LibraryHooks`, this filter slows that body's type-check past the 300 ms warning.
    private var drawingDisplayIDs: [CGDirectDisplayID] {
        stage.displays.filter { $0.state == .ok }.map(\.id)
    }

    private func syncDisplays() {
        let connected = Set(screenManager.screens.map(\.id))
        for id in Array(coverTasks.keys) where !connected.contains(id) {
            coverTasks.removeValue(forKey: id)?.cancel()
            coverGenerations[id, default: 0] &+= 1
        }
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
            let configuration = screenManager.getConfiguration(for: screen)
            if Self.reconcileCover(&display, hasConfiguration: configuration != nil) {
                coverGenerations[screen.id, default: 0] &+= 1
            }
            if coverSignatures[screen.id] == nil {
                coverSignatures[screen.id] = Self.coverSignature(of: configuration)
            }
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
                symbol: failureClass.symbol, text: failureClass.kickerText, failureClass: failureClass
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
            // An old cover can remain while the replacement warms up. Retry unfulfilled generations
            // on runtime changes as well as on startup, without stacking concurrent requests.
            if display.state != .empty, coverTasks[display.id] == nil,
               display.cover == nil || coverGenerations[display.id] != landedCoverGenerations[display.id] {
                refreshCover(for: display.id, crossfade: true)
            }
        }
    }

    /// Not `refreshAllStates()`: that also starts a cover capture for a display still missing one.
    private func refreshWallpaperNames() {
        syncShelf()
        for display in stage.displays {
            refreshState(for: display.id)
        }
    }

    private func refreshState(for id: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == id }),
              let index = stage.displays.firstIndex(where: { $0.id == id }) else { return }
        stage.displays[index].state = state(for: screen)
        describeWallpaper(for: screen, in: &stage.displays[index])
        if Self.reconcileCover(&stage.displays[index], hasConfiguration: screenManager.getConfiguration(for: screen) != nil) {
            coverTasks.removeValue(forKey: id)?.cancel()
            coverGenerations[id, default: 0] &+= 1
        }
    }

    private var configurationRevisions: [CGDirectDisplayID: UInt] {
        Dictionary(screenManager.screens.map { ($0.id, $0.configurationRevision) }, uniquingKeysWith: { $1 })
    }

    /// Displays that appear or leave are `syncDisplays`'s; this handles commits on displays present before and after.
    private func configurationsCommitted(from old: [CGDirectDisplayID: UInt], to new: [CGDirectDisplayID: UInt]) {
        for (id, revision) in new {
            guard let previous = old[id], previous != revision else { continue }
            refreshState(for: id)
            let signature = screenManager.screen(withID: id).flatMap { Self.coverSignature(of: screenManager.getConfiguration(for: $0)) }
            guard coverSignatures[id] != .some(signature) else { continue }
            coverSignatures[id] = signature
            refreshCover(for: id, crossfade: true)
        }
    }

    /// Drops the cover of a display that no longer has a wallpaper; true when it has none, so an
    /// in-flight capture of the removed wallpaper is superseded even before its first cover landed.
    static func reconcileCover(_ display: inout StageDisplay, hasConfiguration: Bool) -> Bool {
        guard !hasConfiguration else { return false }
        display.cover = nil
        return true
    }

    /// The configuration with every sound-only field reset, so two configurations that draw the same compare equal.
    /// Fields are reset rather than visual ones listed: a new visual field must still recapture the cover.
    static func coverSignature(of configuration: ScreenConfiguration?) -> ScreenConfiguration? {
        guard var signature = configuration else { return nil }
        signature.muted = false
        signature.videoVolume = 0
        if case let .html(source, config) = signature.activeWallpaper {
            signature.activeWallpaper = .html(source: source, config: silenced(config))
        }
        signature.savedHTMLConfig = signature.savedHTMLConfig.map(silenced)
        return signature
    }

    private static func silenced(_ config: HTMLConfig) -> HTMLConfig {
        var config = config
        config.muteAudio = false
        config.audioVolume = 0
        return config
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
        let title = StageWallpaperName.resolve(
            libraryTitle: libraryTitle(for: configuration),
            originTitle: configuration.wpeOrigin?.title,
            fileURL: configuration.wallpaperType == .video ? screen.videoPlayer?.videoURL : nil,
            host: host,
            kind: display.wallpaperKind
        )
        #if !LITE_BUILD
        WPEPropertyLabelTranslator.wallpaperNames.enqueue(labels: [title], persist: true)
        #endif
        display.wallpaperTitle = title.translatedWallpaperName
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
        guard let screen = screenManager.screens.first(where: { $0.id == id }),
              screenManager.getConfiguration(for: screen) != nil else { return }
        let generation = (coverGenerations[id] ?? 0) + 1
        coverGenerations[id] = generation
        coverTasks[id]?.cancel()
        #if !LITE_BUILD
        let saveAt = Self.workshopCoverSaveTime(on: id, afterSwitch: crossfade, at: .now, notBefore: &workshopCoverNotBefore)
        #endif
        coverTasks[id] = Task { @MainActor in
            defer {
                if coverGenerations[id] == generation {
                    coverTasks[id] = nil
                }
            }
            if crossfade {
                // A fresh session has no frame yet right after the change notification.
                try? await Task.sleep(for: .milliseconds(600))
            }
            let captured = await Self.captureCover(
                retryDelays: Self.coverRetryDelays,
                isNewest: { !Task.isCancelled && coverGenerations[id] == generation },
                sleep: { try? await Task.sleep(for: $0) },
                capture: {
                    guard let screen = screenManager.screens.first(where: { $0.id == id }),
                          let configuration = screenManager.getConfiguration(for: screen) else { return nil }
                    return await WallpaperCoverCapture.captureWallpaper(screen: screen, configuration: configuration)?
                        .cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            )
            guard let image = captured,
                  !Task.isCancelled, coverGenerations[id] == generation,
                  let index = stage.displays.firstIndex(where: { $0.id == id }) else { return }
            if crossfade, stage.displays[index].cover != nil {
                stage.crossfadeCover(display: id, to: image, duration: DesignTokens.Motion.wallpaperCrossfadeDuration)
            }
            stage.displays[index].cover = image
            landedCoverGenerations[id] = generation
            #if !LITE_BUILD
            await saveWorkshopCover(for: id, generation: generation, at: saveAt)
            #endif
        }
    }

    /// A new session held through a transition, or one suspended, captures nil, so the card retries briefly.
    static let coverRetryDelays: [Duration] = Array(repeating: .milliseconds(400), count: 30)

    /// `isNewest`: no newer capture was asked for since; once false, nothing more is captured and nil is returned.
    static func captureCover(
        retryDelays: [Duration],
        isNewest: () -> Bool,
        sleep: (Duration) async -> Void,
        capture: () async -> CGImage?
    ) async -> CGImage? {
        guard isNewest() else { return nil }
        if let image = await capture(), isNewest() {
            return image
        }
        for delay in retryDelays {
            guard isNewest() else { return nil }
            await sleep(delay)
            guard isNewest() else { return nil }
            if let image = await capture(), isNewest() {
                return image
            }
        }
        return nil
    }

    #if !LITE_BUILD
    /// After a switch, how long the frame saved as the library cover waits: past an opening animation or fade-in.
    static let workshopCoverDelay: Duration = .seconds(10)

    /// When a capture asked for at `now` may save its frame: once the display's latest switch has waited
    /// `workshopCoverDelay`. A switch's own capture (`afterSwitch`) starts that wait.
    static func workshopCoverSaveTime(
        on id: CGDirectDisplayID, afterSwitch: Bool, at now: ContinuousClock.Instant,
        notBefore: inout [CGDirectDisplayID: ContinuousClock.Instant]
    ) -> ContinuousClock.Instant {
        if afterSwitch {
            notBefore[id] = now + workshopCoverDelay
        }
        return max(notBefore[id] ?? now, now)
    }

    /// `saveAt`: when the frame may be taken, from `workshopCoverSaveTime`.
    private func saveWorkshopCover(for id: CGDirectDisplayID, generation: Int, at saveAt: ContinuousClock.Instant) async {
        func running() -> (screen: Screen, configuration: ScreenConfiguration)? {
            guard let screen = screenManager.screens.first(where: { $0.id == id }),
                  let configuration = screenManager.getConfiguration(for: screen) else { return nil }
            return (screen, configuration)
        }
        await Self.saveWorkshopCover(
            after: saveAt - ContinuousClock.now,
            isNewest: { !Task.isCancelled && coverGenerations[id] == generation },
            target: {
                running().flatMap {
                    Self.workshopCoverEntry(running: $0.configuration, in: SettingsManager.shared.loadGlobalSettings().recentWPEImports)
                }
            },
            capture: {
                guard let display = running() else { return nil }
                return await WallpaperCoverCapture.wallpaperFrame(screen: display.screen, configuration: display.configuration)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
            },
            store: { frame, entry in
                guard let name = WallpaperCoverStore.shared.storeWorkshopCover(
                    frame, workshopID: entry.origin.workshopID, importedAt: entry.importedAt
                ) else { return }
                // Decoded before the rows change: a shelf card whose request is not cached yet draws blank.
                let card = ShelfThumbnailCache.Request.workshop(entry, coverRevision: WallpaperCoverStore.shared.revision(of: name))
                Task {
                    _ = await thumbnails.image(card, pixelSize: Self.thumbnailPixelSize, scale: NSScreen.main?.backingScaleFactor ?? 2)
                    library?.refresh()
                }
            }
        )
    }

    /// `isNewest`: no newer capture was asked for since. `target` is read again once the frame is in, so a switch, an
    /// edit or a re-import meanwhile drops the save; `store` gets the entry as read then.
    static func saveWorkshopCover(
        after delay: Duration,
        isNewest: () -> Bool,
        target: () -> WPEHistoryEntry?,
        capture: () async -> CGImage?,
        store: (CGImage, WPEHistoryEntry) -> Void
    ) async {
        guard let planned = target() else { return }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard isNewest(), let frame = await capture(), isNewest(),
              let current = target(), current.id == planned.id, current.importedAt == planned.importedAt else { return }
        store(frame, current)
    }

    /// The history entry of the Workshop project `configuration` runs as its author made it: a scene with no
    /// property edits or preset, a web page with none of its own settings changed. nil for anything else.
    /// Only once applied since its import: a download or an update re-imports without replacing the running session.
    static func workshopCoverEntry(running configuration: ScreenConfiguration, in history: [WPEHistoryEntry]) -> WPEHistoryEntry? {
        guard let origin = configuration.wpeOrigin, let entry = history.first(where: { $0.id == origin.workshopID }),
              let used = entry.lastUsedAt, used >= entry.importedAt else {
            return nil
        }
        switch configuration.activeWallpaper {
        case let .scene(descriptor):
            return descriptor.propertyOverrides.isEmpty && descriptor.presetID == nil ? entry : nil
        case let .html(source, config):
            let key = WallpaperEngineProjectIdentity.key(source: source, origin: origin)
            return config.projectWallpaperEngineProperties(forProjectKey: key).isEmpty ? entry : nil
        case .video:
            return entry
        }
    }
    #endif

    /// A cover shows what its display runs now only once the newest capture asked for has landed: until then,
    /// and for good when a capture fails, it is the wallpaper the display ran before.
    private var currentCoverDisplays: Set<CGDirectDisplayID> {
        Self.currentCovers(requested: coverGenerations, landed: landedCoverGenerations)
    }

    static func currentCovers(requested: [CGDirectDisplayID: Int], landed: [CGDirectDisplayID: Int]) -> Set<CGDirectDisplayID> {
        Set(requested.compactMap { id, generation in landed[id] == generation ? id : nil })
    }

    // MARK: Shelf

    private func syncShelf() {
        guard let library else { return }
        let visible = library.visibleItems
        #if !LITE_BUILD
        // `items`, not `visible`: a chip, filter or search would otherwise prune the rows it hides.
        WPEPropertyLabelTranslator.wallpaperNames.retainPersisted(Set(library.items.map(\.title)))
        WPEPropertyLabelTranslator.wallpaperNames.enqueue(labels: visible.map(\.title), persist: true)
        #endif
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        stage.shelfRenderBudget = shelfCapacity
        // The whole library goes on the shelf; the stage builds layers for the slice it draws and
        // reports it back so only those previews get decoded.
        stage.shelfItems = visible.map { item in
            StageCard(
                id: item.id,
                title: item.title.translatedWallpaperName,
                metaLine: metaLine(for: item),
                thumbnail: item.thumbnail.flatMap { thumbnails.cached($0, pixelSize: Self.thumbnailPixelSize, scale: scale) },
                nowPlaying: NowPlayingBadge(on: item.onDisplays, among: stage.displays),
                isDraggable: item.isSupported,
                statusBadge: item.statusBadge,
                previewOrigin: item.thumbnail?.scenePreviewOrigin
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
            case let .displayRenamed(id, name):
                rename(id, to: name)
            case let .snapped(index):
                if index < 2 {
                    // Here, not when the grid disappears: the nav pill unmounts it before the stage reads where the cards leave from.
                    stage.gridScrollOffset = 0
                }
                // The slide the nav pill runs when it is clicked.
                withAnimation(DesignTokens.motion(stage.reduceMotion, DesignTokens.Motion.selection)) {
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
                    DisplayDetailHost.togglePlayback(on: screen, manager: screenManager)
                case .next:
                    screenManager.advancePlaylist(for: screen)
                case .previous:
                    screenManager.regressPlaylist(for: screen)
                }
            case let .clearWallpaperTapped(id):
                guard let screen = screenManager.screens.first(where: { $0.id == id }) else { continue }
                requestClearWallpaper(on: screen)
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
            case let .displayDropped(sourceID, targetID):
                guard let source = screenManager.screens.first(where: { $0.id == sourceID }),
                      let target = screenManager.screens.first(where: { $0.id == targetID }) else { continue }
                applyConfiguration(from: source, to: target)
            case let .filesDropped(urls, displayID):
                guard let screen = screenManager.screens.first(where: { $0.id == displayID }),
                      let intent = ApplyIntent.drop(urls) else { continue }
                applies.run(for: displayID) { await apply(intent, to: screen, card: nil, shakesDisplay: true, cancellation: $0) }
            case let .filesDroppedOnShelf(urls):
                importToLibrary(urls)
            case let .cardTapped(cardID):
                openLibraryItem(cardID)
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
        applies.runEach(screens) { screen, cancellation in
            await apply(intent, to: screen, card: nil, cancellation: cancellation, group: group)
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
            let text = [summary, outcome.failureSummary].compactMap(\.self).joined(separator: "\n")
            toasts.post(text, style: outcome.failed == 0 ? .success : .failure)
        }
    }
}

/// A layer of the overview, gone while a display's detail page is over it: the page has no fill, so
/// anything left here would show through it.
private struct CoveredByDetail: ViewModifier {
    let covered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            // The curve the detail's own top bar and inspector come in on.
            .animation(DesignTokens.Motion.detailChrome(reduceMotion: reduceMotion), value: covered)
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
                    geometry.contentOffset.y + geometry.contentInsets.top <= 0.5
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
