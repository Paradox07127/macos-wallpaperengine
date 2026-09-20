import AppKit
import LiveWallpaperCore
import SwiftUI

/// Home = the AppKit stage plus the SwiftUI chrome layered over it. Owns the stage model and
/// feeds it displays, covers and shelf cards; consumes the stage's event stream. The library
/// is the stage's p = 2 state, so this one view serves both the home and library pages.
struct HomePage: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog
    let router: EditDeskRouter
    /// Owned by `EditDeskRoot`: a page switch unmounts this view, and a centre rebuilt here would
    /// drop whatever the other pages queued.
    let toasts: EditDeskToastCenter
    @State private var stage = EditDeskStageModel()
    @State private var library: SavedLibraryModel?
    @State private var thumbnails = ShelfThumbnailCache()
    @State private var segment: LibrarySegment = .wallpapers
    @State private var chipID = Self.chipID(.all)
    /// Set before a stage snap changes `router.page`, so that change is not echoed back as a command.
    @State private var pageChangeFromStage = false
    /// Bumped per display before each capture; a capture that finishes after a newer one started is dropped.
    @State private var coverGenerations: [CGDirectDisplayID: Int] = [:]
    /// Read by the library grid so a thumbnail landing in the cache re-renders the tiles.
    @State private var thumbnailRevision = 0
    @State private var applies = ApplyQueue()
    /// The library item the S4 modal shows; nil when closed.
    @State private var presentedItemID: String?
    /// The detail host reports its tile flights so the stage stays locked while a tile returns.
    @State private var detailBusy = false
    @AppStorage(EditDeskPreferences.shelfStyle, store: .appScoped())
    private var shelfStyleRaw = EditDeskPreferences.shelfStyleDefault.rawValue
    @AppStorage(EditDeskPreferences.background, store: .appScoped())
    private var backgroundRaw = EditDeskPreferences.backgroundDefault.rawValue
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
    final class ApplyQueue {
        private var tasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
        private var running = 0

        var isIdle: Bool {
            running == 0
        }

        func run(for displayID: CGDirectDisplayID, _ work: @escaping @MainActor () async -> Void) {
            tasks[displayID]?.cancel()
            running += 1
            tasks[displayID] = Task { @MainActor [weak self] in
                await work()
                self?.running -= 1
            }
        }
    }

    /// The `onChange` fan-out lives in its own modifier: inlined it pushes the body past what the
    /// type checker will finish.
    private struct SyncHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .modifier(LibraryHooks(page: page))
                .onChange(of: page.reduceMotion) { page.stage.reduceMotion = page.reduceMotion }
                .onChange(of: page.screenManager.screens.map(\.id)) { page.syncDisplays() }
                .onChange(of: page.screenManager.suspendReasonsByScreen) { page.refreshAllStates() }
                .onChange(of: page.screenManager.screens.map { page.screenManager.wallpaperLoads.attempt(for: $0)?.failure }) {
                    page.refreshAllStates()
                }
                .onChange(of: page.screenManager.wallpaperSessionStateVersion) { page.refreshAllStates() }
                .onChange(of: page.shelfStyleRaw) { page.stage.shelfStyle = page.shelfStyle }
                .onChange(of: page.backgroundRaw) {
                    page.stage.opaqueBackground = page.backgroundRaw != EditDeskBackground.frosted.rawValue
                }
                .onChange(of: page.interactionLock, initial: true) { page.stage.interactionBlocked = page.interactionLock }
                .onChange(of: page.router.page) { page.syncProgress(to: page.router.page, animated: true) }
                .onChange(of: page.router.libraryFocus, initial: true) {
                    page.applyLibraryFocus(page.router.libraryFocus)
                }
        }
    }

    /// Split off `SyncHooks`: one chain of this many `onChange`s stops type-checking in time.
    private struct LibraryHooks: ViewModifier {
        let page: HomePage

        func body(content: Content) -> some View {
            content
                .onChange(of: page.library?.visibleItems) { page.syncShelf() }
                .onChange(of: page.shelfCapacity) { page.syncShelf() }
                .onChange(of: page.chipID, initial: true) { page.applyChip() }
                .onChange(of: page.library?.items.count) { page.applyChip() }
                .onChange(of: page.stage.visibleShelfRange) { page.loadShelfThumbnails() }
                .onChange(of: page.stage.visibleGridRange) { page.loadShelfThumbnails() }
        }
    }

    private var shelfStyle: ShelfStyle {
        ShelfStyle(rawValue: shelfStyleRaw) ?? EditDeskPreferences.shelfStyleDefault
    }

    /// The stage ignores wheel and clicks while anything is presented over it.
    fileprivate var interactionLock: Bool {
        presentedItemID != nil || router.detailDisplayID != nil || detailBusy
    }

    /// Shelf thumbnails are requested at the row card size on a 2× screen; the grid reuses them.
    private static let thumbnailPixelSize = CGSize(
        width: StageGeometry.cardSize.width * 2, height: StageGeometry.cardSize.height * 2
    )

    var body: some View {
        ZStack(alignment: .top) {
            // Order matters: the shelf's scrim and the filter chips belong *under* the cards, so
            // a card leaning or lifting over them is never clipped by a piece of chrome.
            EditDeskShelfScrim(visible: stage.showsShelf)
            shelfChrome
            EditDeskStageRepresentable(model: stage)
            HomeHints(progress: stage.progress, windowSize: stage.stageSize)
            hoverName
            libraryLayer
            TopBar(
                page: pageBinding,
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                searchText: queryBinding,
                showsSearch: router.page == .library,
                status: statusCapsule
            )
            DisplayDetailHost(
                router: router, stage: stage, library: library, modalPresented: presentedItemID != nil,
                refreshCover: { refreshCover(for: $0, crossfade: false) },
                busy: $detailBusy, toasts: toasts
            )
            if let library {
                LibraryModalHost(
                    library: library, stage: stage, thumbnails: thumbnails,
                    presentedItemID: $presentedItemID, apply: applyFromModal
                )
            }
            EditDeskToastHost(center: toasts)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: DesignTokens.Motion.exitDuration)), value: isLibraryOpen)
        .onAppear {
            if library == nil {
                library = SavedLibraryModel(screenManager: screenManager)
            }
            stage.reduceMotion = reduceMotion
            stage.shelfStyle = shelfStyle
            stage.opaqueBackground = backgroundRaw != EditDeskBackground.frosted.rawValue
            stage.dropHintText = String(localized: "Drop to replace", bundle: .appLanguage)
            syncDisplays()
            syncShelf()
            if router.page == .library {
                stage.setProgress(2, animated: false)
            } else if HomeDefaultState(rawValue: homeDefaultRaw) == .halfOpen, stage.progress == 0 {
                stage.setProgress(1, animated: false)
            }
        }
        .task { await consumeEvents() }
        .modifier(SyncHooks(page: self))
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in syncDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let id = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            refreshState(for: id)
            refreshCover(for: id, crossfade: true)
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var shelfChrome: some View {
        if stage.showsShelf {
            chipsRow
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
                .padding(.top, StageGeometry.chipRowTop(progress: stage.progress, windowSize: stage.stageSize))
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var libraryLayer: some View {
        if isLibraryOpen {
            librarySurface
                .padding(.top, StageGeometry.gridTop)
                .transition(.opacity)
        }
    }

    /// Deliberately not `progress == 2`: the first pixel of a return swipe would tear the grid
    /// down and lose the scroll position, and a cancelled swipe would rebuild it.
    private var isLibraryOpen: Bool {
        router.page == .library && stage.snappedIndex == 2 && stage.progress > StageGeometry.libraryHandoffProgress
    }

    private var statusCapsule: StatusCapsule {
        StatusCapsule(
            content: StatusCapsuleContent(rawValue: statusCapsuleRaw) ?? EditDeskPreferences.statusCapsuleContentDefault,
            renderingScreenCount: screenManager.screens.filter { screenManager.getConfiguration(for: $0) != nil }.count,
            batterySaverOn: SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery,
            onOpenPerformanceSettings: { router.openSettings(.performancePower, anchor: .performancePause) }
        )
    }

    private var queryBinding: Binding<String> {
        Binding(get: { library?.query ?? "" }, set: { library?.query = $0 })
    }

    /// Writing `router.page` straight from the pill skips `select`, which is what records the page
    /// to come back to and what turns Workshop away when the SKU does not have it.
    private var pageBinding: Binding<EditDeskRouter.Page> {
        Binding(get: { router.page }, set: { router.select($0) })
    }

    private var chipsRow: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            if router.page == .library {
                LibrarySegmentPicker(selection: $segment)
            }
            LibraryChipsRow(
                chips: SavedLibraryModel.Chip.allCases.map { LibraryChip(id: Self.chipID($0), title: Self.chipTitle($0)) },
                selection: $chipID,
                sortTitle: Self.sortTitle(library?.sort ?? .recentlyUsed),
                sortMenu: {
                    Button("Recently Used") { library?.sort = .recentlyUsed }
                    Button("Name") { library?.sort = .name }
                    Button("Type") { library?.sort = .type }
                },
                onImport: promptImport
            )
        }
    }

    /// Lives outside the (conditionally built) chip row: routing can set the chip while the shelf is
    /// still hidden, and the row would then appear selected while the model kept the old filter.
    fileprivate func applyChip() {
        guard let library else { return }
        library.chip = Self.chip(for: chipID)
        guard library.chip == .fourK else { return }
        // The 4K chip hides unprobed videos, so it has to trigger their probe itself — including
        // items that arrive while the chip is already selected.
        let candidates = library.items
            .filter { ($0.kind == .video || $0.kind == .aerial) && $0.metadata == nil }
            .map(\.id)
        guard !candidates.isEmpty else { return }
        Task { await library.probeMetadata(for: candidates) }
    }

    private var hoverCaption: String? {
        guard let id = stage.hoveredCard, let item = library?.items.first(where: { $0.id == id }) else { return nil }
        return item.title + " · " + Self.kindName(item.kind)
    }

    /// The name rides over the card the pointer is on: inside the thumbnail the card to the right
    /// covers all but the near edge, so a title drawn there is unreadable.
    @ViewBuilder
    private var hoverName: some View {
        if let caption = hoverCaption, let rect = stage.hoveredCardRect, stage.showsShelf {
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
        case .nowPlaying: "nowPlaying"
        case .fourK: "fourK"
        }
    }

    private static func chip(for id: String) -> SavedLibraryModel.Chip {
        SavedLibraryModel.Chip.allCases.first { chipID($0) == id } ?? .all
    }

    private static func chipTitle(_ chip: SavedLibraryModel.Chip) -> LocalizedStringKey {
        switch chip {
        case .all: "All"
        case .recent: "Recent"
        case .steam: "Steam"
        case .local: "Local"
        case .aerials: "Aerials"
        case .nowPlaying: "Now Playing"
        case .fourK: "4K"
        }
    }

    private static func sortTitle(_ sort: SavedLibraryModel.Sort) -> LocalizedStringKey {
        switch sort {
        case .recentlyUsed: "Recently Used"
        case .name: "Name"
        case .type: "Type"
        }
    }

    private static func kindName(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .video: String(localized: "Video", bundle: .appLanguage)
        case .web: String(localized: "Web", bundle: .appLanguage)
        case .scene: String(localized: "Scene", bundle: .appLanguage)
        case .aerial: String(localized: "Aerial", bundle: .appLanguage)
        }
    }

    // MARK: Library page

    @ViewBuilder
    private var librarySurface: some View {
        switch segment {
        case .wallpapers:
            if library?.chip == .aerials {
                AerialsLibraryView()
            } else {
                wallpaperGrid
            }
        case .schemes:
            SchemeLibraryView()
        case .systemWallpaper:
            if #available(macOS 26.0, *) {
                SystemWallpaperLibraryView()
            }
        }
    }

    private var wallpaperGrid: some View {
        ScrollView {
            if let library, library.visibleItems.isEmpty {
                IllustratedEmptyState(symbol: "square.grid.2x2", title: "No wallpapers yet")
            } else if let library {
                LibraryGalleryGrid(
                    size: .medium, aspect: .wide,
                    initialWidth: stage.stageSize.width - 2 * DesignTokens.LibraryGrid.horizontalPadding
                ) {
                    ForEach(library.visibleItems) { item in
                        LibraryGridTile(item: item, image: gridImage(for: item, revision: thumbnailRevision))
                            .onTapGesture { presentedItemID = item.id }
                            .task(id: item.id) { await library.probeMetadata(for: [item.id]) }
                    }
                }
                .libraryGridPadding()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(GridTopReporter { stage.gridAtTop = $0 })
        .background(DesignTokens.EditDesk.Colors.background)
    }

    /// `revision` is only read so the grid re-renders when a thumbnail lands in the cache.
    private func gridImage(for item: LibraryItem, revision _: Int) -> CGImage? {
        guard let request = item.thumbnail else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cached = thumbnails.cached(request, pixelSize: Self.thumbnailPixelSize, scale: scale) {
            return cached
        }
        Task { @MainActor in
            guard await thumbnails.image(request, pixelSize: Self.thumbnailPixelSize, scale: scale) != nil else { return }
            thumbnailRevision += 1
            syncShelf()
        }
        return nil
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

    private func applyLibraryFocus(_ focus: EditDeskRouter.LibraryFocus) {
        switch focus {
        case .wallpapers:
            segment = .wallpapers
        case .schemes:
            segment = .schemes
        case .systemWallpaper:
            segment = .systemWallpaper
        case .aerials:
            segment = .wallpapers
            chipID = Self.chipID(.aerials)
        }
    }

    // MARK: Displays

    private func syncDisplays() {
        stage.displays = screenManager.screens.map { screen in
            let presentation = ScreenPresentation.presentation(
                for: screen, refreshRate: screenManager.getScreenRefreshRate(for: screen.id)
            )
            return StageDisplay(
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
        }
        for display in stage.displays where display.cover == nil && display.state != .empty {
            refreshCover(for: display.id, crossfade: false)
        }
    }

    private func state(for screen: Screen) -> StageDisplay.State {
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
        }
    }

    private func refreshState(for id: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == id }),
              let index = stage.displays.firstIndex(where: { $0.id == id }) else { return }
        stage.displays[index].state = state(for: screen)
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
        let visible = library.visibleItems.filter { $0.kind != .aerial }
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
                onBadge: item.onDisplays.isEmpty ? nil : "ON",
                isDraggable: item.isSupported
            )
        }
        loadShelfThumbnails()
    }

    private func loadShelfThumbnails() {
        guard let library else { return }
        let visible = library.visibleItems.filter { $0.kind != .aerial }
        guard !visible.isEmpty else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Exactly what the band draws: a ceiling of `max(capacity, drawn)` would float up to
        // whatever the row laid out and never bind.
        // Two runs, not the span between them: the grid's slice starts at the top of the library
        // while the row can be scrolled hundreds of cards away.
        let windows = [stage.visibleShelfRange, stage.visibleGridRange].map { $0.clamped(to: 0 ..< visible.count) }
        for index in Set(windows.joined()) {
            let item = visible[index]
            guard let request = item.thumbnail,
                  thumbnails.cached(request, pixelSize: Self.thumbnailPixelSize, scale: scale) == nil else { continue }
            Task { @MainActor in
                guard let image = await thumbnails.image(request, pixelSize: Self.thumbnailPixelSize, scale: scale),
                      let slot = stage.shelfItems.firstIndex(where: { $0.id == item.id }),
                      // The item's source can change while its preview decodes; a stale decode must
                      // not paint over the newer one.
                      library.visibleItems.first(where: { $0.id == item.id })?.thumbnail == request
                else { return }
                stage.shelfItems[slot].thumbnail = image
            }
        }
        dropThumbnailsOutside(windows, of: visible)
    }

    /// `StageCard` holds its preview strongly, so without this every card ever scrolled past stays
    /// resident and the cache's own cost limit never gets a say.
    private func dropThumbnailsOutside(_ windows: [Range<Int>], of visible: [LibraryItem]) {
        guard stage.shelfItems.count == visible.count else { return }
        let keep = Set(windows.flatMap { visible[$0].map(\.id) })
        for index in stage.shelfItems.indices where stage.shelfItems[index].thumbnail != nil {
            if !keep.contains(stage.shelfItems[index].id) {
                stage.shelfItems[index].thumbnail = nil
            }
        }
    }

    /// GAP_ANALYSIS §6: `视频 · 4K · 1:32`, `网页 · 域名`, `场景`, `Aerial · 地点`.
    private func metaLine(for item: LibraryItem) -> String {
        var parts = [Self.kindName(item.kind)]
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
                router.showDetail(id)
            case let .snapped(index):
                if index == 2, router.page == .home {
                    pageChangeFromStage = true
                    router.select(.library)
                } else if index < 2, router.page == .library {
                    pageChangeFromStage = true
                    router.select(.home)
                }
            case let .playbackTapped(id, action):
                guard let screen = screenManager.screens.first(where: { $0.id == id }) else { continue }
                switch action {
                case .toggle:
                    guard let controller = screen.playbackController else { continue }
                    if controller.isPlaying {
                        controller.pause()
                    } else {
                        controller.play()
                    }
                    screenManager.markWallpaperSessionStateChanged()
                case .next:
                    screenManager.advancePlaylist(for: screen)
                case .previous:
                    screenManager.regressPlaylist(for: screen)
                }
            case let .dropped(cardID, displayID):
                applies.run(for: displayID) { await applyCard(cardID, to: displayID) }
            case let .cardTapped(cardID):
                presentedItemID = cardID
            case let .cardApplyRequested(cardID):
                // VoiceOver's "Apply" is the keyboard equivalent of a drop: it lands on the main display.
                guard let screen = screenManager.screens.first(where: { CGDisplayIsMain($0.id) != 0 })
                    ?? screenManager.screens.first else { continue }
                applies.run(for: screen.id) { await applyCard(cardID, to: screen.id) }
            case .displayContextMenu, .dropCancelled:
                continue
            }
        }
    }

    private func applyCard(_ cardID: StageCard.ID, to displayID: CGDirectDisplayID) async {
        guard let item = library?.items.first(where: { $0.id == cardID }),
              let screen = screenManager.screens.first(where: { $0.id == displayID }),
              let intent = ModalActions.intent(for: item) else {
            stage.shake(card: cardID)
            return
        }
        await apply(intent, to: screen, card: cardID)
    }

    private func apply(_ intent: ApplyIntent, to screen: Screen, card: StageCard.ID?) async {
        let router = ApplyRouter(
            manager: screenManager, bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)
        )
        let report = await router.apply(intent, to: screen)
        guard !Task.isCancelled else { return }
        if report.exitedSpanMode {
            toasts.post(String(localized: "Left span mode", bundle: .appLanguage), style: .info)
        }
        switch report.outcome {
        case .applied:
            break
        case let .registeredPreset(name):
            toasts.post(name, style: .info)
        case let .failed(failure):
            toasts.post(failure.toastText, style: .failure)
            if let card {
                stage.shake(card: card)
            }
        }
    }

    /// The modal's apply path: the same queue and toasts as a drop, minus the card to shake.
    private func applyFromModal(_ intent: ApplyIntent, to displayID: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == displayID }) else { return }
        applies.run(for: displayID) { await apply(intent, to: screen, card: nil) }
    }

    /// The "+ 导入" capsule: one picker, routed like a Finder drop onto the main display.
    private func promptImport() {
        guard let screen = screenManager.screens.first(where: { CGDisplayIsMain($0.id) != 0 }) ?? screenManager.screens.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        Task { await apply(.droppedFile(url), to: screen, card: nil) }
    }
}

/// Tells the stage whether the grid sits at its top, which is what lets a pull-down hand the
/// gesture back to it. Below macOS 15 there is no scroll geometry, so the handoff stays off.
private struct GridTopReporter: ViewModifier {
    let report: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top + 0.5
                } action: { _, atTop in
                    report(atTop)
                }
                .onAppear { report(true) }
                .onDisappear { report(false) }
        } else {
            content.onAppear { report(false) }
        }
    }
}

/// Full-library tile at p = 2. Thumbnails come from `ShelfThumbnailCache` like the shelf cards.
private struct LibraryGridTile: View {
    let item: LibraryItem
    let image: CGImage?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                DesignTokens.Colors.surfaceRaised
                Image(systemName: item.kind == .web ? "globe" : item.kind == .scene ? "cube.transparent" : "play.rectangle")
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(
                colors: [.clear, DesignTokens.EditDesk.Colors.gradientCardBottom],
                startPoint: .center, endPoint: .bottom
            )
            Text(verbatim: item.title)
                .font(DesignTokens.EditDesk.Typography.cardTitle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .lineLimit(1)
                .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        .aspectRatio(StageGeometry.cardAspectRatio, contentMode: .fit)
        .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .settledHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: item.title))
    }
}
