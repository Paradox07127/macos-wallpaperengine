import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// Presents the display detail over the home page and runs the shared-element handshake with the
/// stage: `flyTile` → hero shown → tile concealed; back: tile revealed → hero hidden → `returnTile`.
/// `router.detailDisplayID` is the request; `shownDisplayID` is what is on screen, flight included.
struct DisplayDetailHost: View {
    let router: EditDeskRouter
    let stage: EditDeskStageModel
    let library: SavedLibraryModel?
    /// ESC belongs to the modal while it is open; the detail takes it back afterwards.
    let modalPresented: Bool
    let refreshCover: (CGDirectDisplayID) -> Void
    let chooseFile: (Screen) -> Void
    let pasteURL: (CGDirectDisplayID) -> Void
    let dropFiles: ([URL], Screen) -> Bool
    let apply: (ApplyIntent, CGDirectDisplayID) -> Void
    /// The home page's own display commands, which record themselves for undo.
    let clearWallpaper: (Screen) -> Void
    let applyToAllDisplays: (Screen) -> Void
    /// Displays with an apply still preparing; `cancelApply` stops one.
    let applying: Set<CGDirectDisplayID>
    let cancelApply: (CGDirectDisplayID) -> Void
    /// Held while a tile is in flight either way, so the stage stays locked through the return.
    @Binding var busy: Bool
    /// The page's own toast stack, so overlay copies and wallpaper applies queue in one place.
    let toasts: EditDeskToastCenter

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    @State private var coordinator: DetailTransitionCoordinator?
    @State private var section: DetailSection = .wallpaper
    @AppStorage("loomscreen.editDesk.inspectorWidth", store: .appScoped()) private var inspectorWidth = 372.0
    @AppStorage("loomscreen.editDesk.inspectorVisible", store: .appScoped()) private var inspectorVisible = true
    /// The overlay column opens and closes with its selection, so it has its own value: sharing the one
    /// above would hide the wallpaper column on every display after one visit to the overlays.
    @State private var overlayInspectorVisible = false
    @AppStorage("loomscreen.editDesk.layersVisible", store: .appScoped()) private var layersVisible = true
    @State private var liveInspectorWidth: Double?
    /// The same optimistic-write draft the old inspector uses; the HUD and the panel both write it.
    @State private var draft = DraftState.default
    @State private var overlaySessions: [String: OverlayEditorSession] = [:]
    @State private var overlaySession: OverlayEditorSession?
    @State private var schemeNameDraft = ""
    @State private var showSchemeCapture = false
    @State private var showAutomation = false
    @State private var confirmsOverlayCopy = false
    @State private var pendingDestructive: PendingDestructive?
    /// Set by Manage Schemes and Choose from Library: their page opens once the tile is home, not under
    /// the return flight.
    @State private var libraryHandoff: LibraryHandoff?
    /// "Adjust on the Preview" for a web wallpaper; off again whenever another display is shown.
    @State private var webTransformArmed = false
    #if !LITE_BUILD
    @State private var showsSceneLog = false
    #endif
    /// Shared with the old detail page so the colour group's disclosure survives switching pages.
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false

    private enum LibraryHandoff {
        case schemes
        /// The wallpaper grid, choosing for this display.
        case wallpapers(for: CGDirectDisplayID)
    }

    var body: some View {
        ZStack {
            if let id = coordinator?.shownDisplayID, let screen = screenManager.screens.first(where: { $0.id == id }) {
                let status = heroStatus(screen)
                let preview = previewState(for: screen)
                DisplayDetail(
                    displayName: screen.name,
                    tags: tags(current: id),
                    hero: status,
                    heroImage: cover(id),
                    backdropImage: cover(id),
                    windowSize: stage.stageSize,
                    section: sectionBinding,
                    heroVisible: coordinator?.heroVisible ?? false,
                    returning: coordinator?.phase == .returning,
                    actions: actions(for: screen),
                    hud: { hud(for: screen) },
                    inspector: { width in inspector(for: screen, width: width) },
                    overlayLogicalSize: screen.frame.size,
                    overlayCanvas: { size in
                        if let overlaySession {
                            OverlayWorkspace(session: overlaySession, cover: cover(id), screen: screen,
                                             size: size, layersVisible: $layersVisible,
                                             inspectorVisible: $overlayInspectorVisible,
                                             inspectorWidth: $inspectorWidth, liveInspectorWidth: $liveInspectorWidth,
                                             topInset: showsOverlayOnboarding ? OnboardingCardMetrics.blockHeight - DetailGeometry.topBarHeight : 0,
                                             recapture: { refreshCover(id); overlaySession.capturePreview() },
                                             back: router.closeDetail)
                        }
                    },
                    overlayTopInset: 0,
                    isEmpty: screenManager.getConfiguration(for: screen) == nil && screenManager.inspectedWallpaperAttempt(for: screen) == nil,
                    preview: preview,
                    wallpaperStatus: { wallpaperStatus(for: screen, preview: preview) },
                    emptyScreen: screen, webTransform: webTransform(for: screen),
                    schedulePausedUntil: draft.schedulePausedUntil,
                    inspectorVisible: sectionInspectorVisible, layersVisible: $layersVisible,
                    inspectorWidth: $inspectorWidth, liveInspectorWidth: $liveInspectorWidth
                )
                .dropDestination(for: URL.self) { urls, _ in
                    section == .wallpaper && dropFiles(urls, screen)
                }
                .onChange(of: screenManager.inspectedWallpaperAttempt(for: screen)?.id) { reloadDraft(for: screen) }
                .onChange(of: screenManager.inspectedWallpaperAttempt(for: screen)?.configuration) { reloadDraft(for: screen) }
                .onChange(of: screenManager.wallpaperSessionStateVersion) { reloadDraft(for: screen) }
                .onChange(of: screenManager.monitorOverlay(for: screen)) { overlaySession?.refreshAppliedConfiguration() }
                .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
                    guard notification.userInfo?["screenID"] as? CGDirectDisplayID == screen.id else { return }
                    reloadDraft(for: screen)
                }
                .sheet(isPresented: $showSchemeCapture) {
                    AppLanguageScope(defaults: .appScoped()) {
                        SchemeCapturePopover(screen: screen, nameDraft: $schemeNameDraft)
                            .environment(screenManager)
                    }
                }
                .sheet(isPresented: $showAutomation) {
                    if let library {
                        AppLanguageScope(defaults: .appScoped()) {
                            WallpaperAutomationSheet(screen: screen, library: library)
                                .environment(screenManager)
                        }
                    }
                }
                .confirmDestructive($pendingDestructive)
                .confirmationDialog("Copy overlays to other displays?", isPresented: $confirmsOverlayCopy, titleVisibility: .visible) {
                    Button("Copy to Other Displays") { copyOverlays(on: screen) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This replaces overlays on every other connected display. Effects are skipped on displays without a wallpaper.")
                }
                #if !LITE_BUILD
                .infoOverlay(isPresented: $showsSceneLog) { dismiss in
                    DetailSceneStatus(screen: screen, configuration: screenManager.getConfiguration(for: screen))?
                        .logSheet(onDismiss: dismiss)
                }
                #endif
                if section == .overlay, let overlaySession {
                    // R-27/R-28: the card stays in the canvas column and carries its own STEP line,
                    // because the detail top bar has no room for the capsule.
                    OnboardingCard(page: .overlay, trailingInset: DetailGeometry.inspectorWidth) { action in
                        switch action {
                        case .addClock:
                            overlaySession.setClockEnabled(true)
                        case .chooseFile, .tryAerials, .importMore, .connectSteam, .importLocalLibrary:
                            break
                        }
                    }
                    .frame(height: OnboardingCardMetrics.blockHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                if !modalPresented {
                    Button(action: router.closeDetail) { EmptyView() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    shortcuts(for: screen)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: DetailPreviewSpace.name)
        .onPreferenceChange(DetailPreviewFrameKey.self) { frames in
            for (display, frame) in frames {
                coordinator?.heroDidLayout(display: display, frame: frame)
            }
        }
        .onChange(of: router.detailDisplayID, initial: true) { _, id in
            request(id)
        }
        .onChange(of: router.pendingFailureID, initial: true) { openPendingFailure() }
        .onChange(of: router.pendingDetailSection, initial: true) { openPendingSection() }
        .onChange(of: coordinator?.busy ?? false, initial: true) { _, value in
            busy = value
            if !value, let libraryHandoff {
                openLibrary(libraryHandoff)
            }
        }
        .onChange(of: stage.stageSize) { coordinator?.windowDidResize() }
        .onChange(of: inspectorWidth) { coordinator?.windowDidResize() }
        .onChange(of: inspectorVisible) { coordinator?.windowDidResize() }
        .onChange(of: screenManager.screens.map(\.id)) {
            if let id = overlaySession?.identity?.displayID, !screenManager.screens.contains(where: { $0.id == id }) {
                overlaySession?.detach()
                overlaySession = nil
                confirmsOverlayCopy = false
            }
        }
        .onDisappear {
            overlaySession?.detach()
            closeShownFailure()
        }
    }

    private func openLibrary(_ handoff: LibraryHandoff) {
        libraryHandoff = nil
        guard coordinator?.shownDisplayID == nil else { return }
        switch handoff {
        case .schemes:
            router.select(.schemes)
        case let .wallpapers(displayID):
            router.libraryTarget = displayID
            router.select(.library)
        }
    }

    private var sectionInspectorVisible: Binding<Bool> {
        section == .overlay ? $overlayInspectorVisible : $inspectorVisible
    }

    private var showsOverlayOnboarding: Bool {
        section == .overlay && progress?.handled.contains(.overlay) == false
    }

    // MARK: Handshake

    /// The hooks are reassigned here rather than at init so they capture the installed view.
    private func request(_ id: CGDirectDisplayID?) {
        if id != coordinator?.shownDisplayID {
            overlaySession?.detach()
            confirmsOverlayCopy = false
            webTransformArmed = false
            closeShownFailure()
        } else if let session = overlaySession, section == .overlay, !session.isActive {
            session.transition(to: session.identity, store: OverlayEditorScreenStore(manager: screenManager), editing: true)
        }
        let coordinator = coordinator ?? DetailTransitionCoordinator(stage: stage, usesMeasuredFrame: true) { .zero }
        if self.coordinator == nil {
            self.coordinator = coordinator
        }
        coordinator.onShow = { target in
            // Synchronous: a deferred load would paint the previous display's draft for a frame.
            if let screen = screenManager.screens.first(where: { $0.id == target }) {
                reloadDraft(for: screen)
                if cover(target) == nil {
                    refreshCover(target)
                }
                let session = overlaySessions[screen.displayFingerprint] ?? OverlayEditorSession()
                overlaySessions[screen.displayFingerprint] = session
                session.onObjectPersisted = { progress?.record(.overlay) }
                session.onWidgetsRemoved = { [weak session, undo] removed in
                    undo?.recordRemoval(of: removed, from: screen) { session?.flushPendingEdits() }
                }
                overlaySession = session
                session.transition(
                    to: OverlayEditorIdentity(displayID: screen.id, fingerprint: screen.displayFingerprint),
                    store: OverlayEditorScreenStore(manager: screenManager), editing: section == .overlay
                )
                session.capturePreview()
            }
        }
        coordinator.onRelease = { overlaySession = nil }
        coordinator.request(id)
    }

    private func reloadDraft(for screen: Screen) {
        overlaySession?.refreshAppliedConfiguration()
        let config = screenManager.inspectedWallpaperAttempt(for: screen)?.configuration
            ?? screenManager.getConfiguration(for: screen)
        let next = DraftState.from(config: config, fallbackHasPreviewSource: screen.videoPlayer?.videoURL != nil)
        // The equality guard is load-bearing: an identical draft would rebuild the whole panel on every settings commit.
        if draft != next {
            draft = next
        }
    }

    private func closeShownFailure() {
        guard let shown = screenManager.screens.first(where: { $0.id == coordinator?.shownDisplayID }) else { return }
        Self.closeFailure(on: shown, manager: screenManager)
    }

    private func openPendingFailure() {
        guard let failureID = router.pendingFailureID else { return }
        router.pendingFailureID = nil
        guard let screen = screenManager.screens.first(where: { $0.id == router.detailDisplayID }),
              Self.openFailure(failureID, on: screen, manager: screenManager) else { return }
        sectionBinding.wrappedValue = .wallpaper
    }

    private func openPendingSection() {
        guard let pending = router.pendingDetailSection else { return }
        router.pendingDetailSection = nil
        sectionBinding.wrappedValue = pending
    }

    private var sectionBinding: Binding<DetailSection> {
        Binding(get: { section }, set: { next in
            guard section != next else { return }
            if let session = overlaySession {
                session.transition(to: session.identity, store: OverlayEditorScreenStore(manager: screenManager), editing: next == .overlay)
                if next == .overlay {
                    session.capturePreview()
                }
            }
            section = next
        })
    }

    // MARK: HUD

    /// The actions zone draws a leading divider unless it is exactly `EmptyView`, so the whole bar branches.
    @ViewBuilder
    private func hud(for screen: Screen) -> some View {
        #if !LITE_BUILD
        if let scene = DetailSceneStatus(screen: screen, configuration: screenManager.getConfiguration(for: screen)),
           scene.renderFailure != nil {
            hudBar(for: screen) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    SceneSkippedChip(state: scene.state, origin: scene.origin) { showsSceneLog = true }
                    SceneDiagnosticsButton { showsSceneLog = true }
                }
            }
        } else {
            hudBar(for: screen) { EmptyView() }
        }
        #else
        hudBar(for: screen) { EmptyView() }
        #endif
    }

    private func hudBar(for screen: Screen, @ViewBuilder actions: () -> some View) -> some View {
        WallpaperPreviewHUD {
            viewportControl(for: screen)
        } playback: {
            WallpaperPlaybackControls(
                screen: screen,
                draft: $draft,
                screenManager: screenManager,
                onPlaybackSpeedChange: { screenManager.updatePlaybackSpeed($0, for: screen) },
                onResetPlayback: { resetPlaybackSettings(for: screen) }
            )
        } actions: {
            actions()
        }
        // Rebuilt per display, so a popover left open cannot go on editing the next display.
        .id(screen.id)
    }

    private func webTransform(for screen: Screen) -> DetailWebTransform? {
        guard draft.selectedWallpaperType == .html else { return nil }
        return DetailWebTransform(screen: screen, config: $draft.htmlConfig, isArmed: webTransformArmed)
    }

    @ViewBuilder
    private func viewportControl(for screen: Screen) -> some View {
        if draft.selectedWallpaperType == .html {
            WebTransformControl(screen: screen, config: $draft.htmlConfig, isArmed: $webTransformArmed)
        } else {
            WallpaperFitModePicker(selection: $draft.selectedFitMode, modes: Self.fitModes(for: draft.selectedWallpaperType)) { mode in
                Self.writeFitMode(mode, type: draft.selectedWallpaperType, screen: screen, screenManager: screenManager)
            }
        }
    }

    /// A scene can be centred; video cannot, and a segment missing the mode a display is already on
    /// shows nothing selected and offers no way back to it.
    static func fitModes(for type: WallpaperType) -> [VideoFitMode] {
        usesSceneFitWriter(type) ? VideoFitMode.sceneModes : VideoFitMode.videoModes
    }

    /// Both writers persist the same `fitMode`, but `updateFitMode` only reaches `videoPlayer`: a
    /// running scene routed through it keeps its old scale until the next load.
    static func usesSceneFitWriter(_ type: WallpaperType) -> Bool {
        type == .scene
    }

    static func writeFitMode(
        _ mode: VideoFitMode, type: WallpaperType, screen: Screen, screenManager: ScreenManager
    ) {
        if usesSceneFitWriter(type) {
            screenManager.updateSceneFitMode(mode, for: screen)
        } else {
            screenManager.updateFitMode(mode, for: screen)
        }
    }

    private func resetPlaybackSettings(for screen: Screen) {
        screenManager.resetPlaybackSettings(for: screen)
        reloadDraft(for: screen)
    }

    /// What the web address prompt starts from: the running URL, or nothing for any other source.
    static func editableWebAddress(_ content: WallpaperContent?) -> String {
        guard case let .html(.url(url), _)? = content else { return "" }
        return url.absoluteString
    }

    /// The saved video or web page this display keeps but is not showing, which the old page's type
    /// picker switched back to.
    static func switchBackTypes(_ configuration: ScreenConfiguration?) -> [WallpaperType] {
        guard let configuration else { return [] }
        var types: [WallpaperType] = []
        if configuration.savedVideoBookmarkData != nil, configuration.wallpaperType != .video {
            types.append(.video)
        }
        if configuration.savedHTMLSource != nil, configuration.wallpaperType != .html {
            types.append(.html)
        }
        return types
    }

    // MARK: Failure inspection

    private func previewState(for screen: Screen) -> DetailPreviewState {
        .resolve(
            hasConfiguration: screenManager.getConfiguration(for: screen) != nil,
            attempt: screenManager.wallpaperLoads.attempt(for: screen),
            hasRuntimeError: screenManager.runtimeError(for: screen) != nil,
            applying: applying.contains(screen.id)
        )
    }

    @ViewBuilder
    private func wallpaperStatus(for screen: Screen, preview: DetailPreviewState) -> some View {
        switch preview {
        case .preparing, .prepareFailed:
            if let attempt = screenManager.inspectedWallpaperAttempt(for: screen) {
                WallpaperAttemptPreview(
                    screen: screen, attempt: attempt, onCancel: { cancelApply(screen.id) }, apply: { apply($0, screen.id) },
                    clearWallpaper: { clearWallpaper(screen) }
                )
            } else if applying.contains(screen.id) {
                WallpaperPreparingView(title: screen.name) { cancelApply(screen.id) }
            }
        case .lastAttemptFailed:
            if let failure = screenManager.wallpaperLoads.attempt(for: screen)?.failure {
                LastApplyFailureBanner(failure: failure) { screenManager.inspectWallpaperAttempt(true, for: screen) }
            }
        case .runtimeError, .empty, .hero:
            EmptyView()
        }
        if preview.showsRuntimeError, let error = screenManager.runtimeError(for: screen) {
            let type = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
            RuntimeErrorBanner(
                error: error, canRePick: type == .video || type == .html,
                onRetry: { screenManager.retryRuntimeSession(for: screen) },
                onRePick: { chooseFile(screen) }
            )
        }
        #if !LITE_BUILD
        if !preview.showsAttempt,
           let scene = DetailSceneStatus(screen: screen, configuration: screenManager.getConfiguration(for: screen)) {
            SceneRenderFailureBanner(state: scene.state, origin: scene.origin, surface: .content) {
                screenManager.retryRuntimeSession(for: screen)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.sm)
            EngineAssetsBanner(margins: EdgeInsets(
                top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md,
                bottom: 0, trailing: DesignTokens.Spacing.md
            ))
        }
        #endif
    }

    /// A failure route names the attempt it came from, so a stale ID from an older failure opens nothing.
    static func openFailure(_ failureID: UUID, on screen: Screen, manager: ScreenManager) -> Bool {
        guard manager.wallpaperLoads.attempt(for: screen)?.id == failureID else { return false }
        manager.inspectWallpaperAttempt(true, for: screen)
        return true
    }

    /// Only a failed attempt steps back; one still preparing keeps its page and its Cancel.
    static func closeFailure(on screen: Screen, manager: ScreenManager) {
        guard manager.wallpaperLoads.attempt(for: screen)?.phase == .failed else { return }
        manager.inspectWallpaperAttempt(false, for: screen)
    }

    // MARK: Inspector

    /// Same branch as the old page: while a load attempt is being inspected its own properties take
    /// the column, because the draft still describes the wallpaper that attempt is replacing.
    @ViewBuilder
    private func inspector(for screen: Screen, width: CGFloat) -> some View {
        #if !LITE_BUILD
        if let attempt = screenManager.inspectedWallpaperAttempt(for: screen) {
            AttemptSceneProperties(screen: screen, attempt: attempt)
                .id(attempt.id)
                .frame(width: width)
        } else {
            wallpaperInspector(for: screen, width: width)
        }
        #else
        wallpaperInspector(for: screen, width: width)
        #endif
    }

    private func wallpaperInspector(for screen: Screen, width: CGFloat) -> some View {
        DetailInspectorPanel(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            featureCatalog: featureCatalog,
            reduceMotion: reduceMotion,
            inspectorPanelWidth: width,
            isColorExpanded: $isColorExpanded,
            onWallpaperModeChange: { screenManager.updateWallpaperMode($0, for: screen) },
            showsResetDisplaySettings: screenManager.displaySettingsDifferFromDefaults(for: screen),
            onResetDisplaySettings: { requestResetDisplaySettings(for: screen) },
            onOpenAutomation: { showAutomation = true }
        )
    }

    private func requestResetDisplaySettings(for screen: Screen) {
        pendingDestructive = PendingDestructive(
            .resetDisplaySettings(displayName: screen.name, sceneCapable: featureCatalog.isEnabled(.scene))
        ) {
            Self.resetDisplaySettings(for: screen, manager: screenManager, undo: undo, toasts: toasts)
        }
    }

    /// Recorded as one step, so undo puts back the whole configuration the reset replaced.
    static func resetDisplaySettings(
        for screen: Screen, manager: ScreenManager, undo: EditDeskUndoStack?, toasts: EditDeskToastCenter
    ) {
        let recording = undo?.begin(.resetDisplaySettings, displays: [screen])
        let content = manager.getConfiguration(for: screen)?.activeWallpaper
        manager.resetDisplaySettings(for: screen)
        recording?.announce(
            String(
                localized: "Reset the settings of \(screen.name)", bundle: .appLanguage,
                comment: "Toast after a display's settings went back to the defaults in the Edit Desk; it offers Undo. Placeholder is a display name."
            ),
            showing: content, to: toasts
        )
    }

    private func requestClearWallpaper(for screen: Screen) {
        pendingDestructive = PendingDestructive(.clearCurrentWallpaper(displayName: screen.name)) {
            clearWallpaper(screen)
            // Clearing only bumps the session version; the draft would keep the old wallpaper's panel.
            reloadDraft(for: screen)
        }
    }

    /// Through the apply path, which records the overlay a scheme replaces, so undo puts both back.
    private func requestApplyScheme(_ scheme: ScreenScheme, to screen: Screen) {
        pendingDestructive = PendingDestructive(.applyScheme(schemeName: scheme.name, displayName: screen.name)) {
            apply(.scheme(scheme), screen.id)
        }
    }

    private func requestApplyToAll(from screen: Screen) {
        pendingDestructive = PendingDestructive(.applyConfigurationToAllDisplays(otherCount: screenManager.screens.count - 1)) {
            applyToAllDisplays(screen)
        }
    }

    private func switchToSaved(_ type: WallpaperType, on screen: Screen) {
        var switched = screenManager.getConfiguration(for: screen)
        let recording = undo?.begin(.applyWallpaper, displays: [screen])
        if type == .video {
            switched?.activateSavedVideoWallpaper()
            screenManager.switchToVideoWallpaper(for: screen)
        } else {
            switched?.activateSavedHTMLWallpaper()
            screenManager.switchToHTMLWallpaper(for: screen)
        }
        recording?.announce(
            ApplyOutcome.appliedText(on: screen.name, wallpapersOn: screenManager.wallpapersGloballyEnabled),
            showing: switched?.activeWallpaper, to: toasts
        )
    }

    // MARK: Content

    private func cover(_ id: CGDirectDisplayID) -> CGImage? {
        stage.displays.first { $0.id == id }?.cover
    }

    private func tags(current: CGDirectDisplayID) -> [DetailDisplayTag] {
        stage.displays.map { display in
            DetailDisplayTag(id: display.id, name: display.name, thumbnail: display.cover, isCurrent: display.id == current)
        }
    }

    private func heroStatus(_ screen: Screen) -> DetailHeroStatus {
        let configuration = screenManager.getConfiguration(for: screen)
        let item = library?.items.first { $0.onDisplays.contains(screen.id) }
        return DetailHeroStatus(
            title: item?.title ?? screen.name,
            kindLine: Self.kindLine(configuration?.activeWallpaper),
            intendsToPlay: screen.playbackController?.userIntendsToPlay,
            pauseReason: SuspendReasonText.localized(for: screenManager.suspendReasonsByScreen[screen.id] ?? []),
            performanceLine: nil,
            canNavigatePlaylist: featureCatalog.isEnabled(.playlists) && configuration?.canNavigatePlaylist == true
        )
    }

    /// Also the stage's on-screen type line, so both pages name a wallpaper's kind the same way.
    static func kindLine(_ content: WallpaperContent?) -> String {
        switch content {
        case .video: String(localized: "Video", bundle: .appLanguage)
        case .html: String(localized: "Web", bundle: .appLanguage)
        case .scene: String(localized: "Scene", bundle: .appLanguage)
        case nil: ""
        }
    }

    // MARK: Actions

    private func actions(for screen: Screen) -> DetailActions {
        let switchBack = Self.switchBackTypes(screenManager.getConfiguration(for: screen))
        return DetailActions(
            back: router.closeDetail,
            selectDisplay: { router.showDetail($0) },
            saveAsScheme: { showSchemeCapture = true },
            applyToAll: { requestApplyToAll(from: screen) },
            clearWallpaper: { requestClearWallpaper(for: screen) },
            playback: { action in
                switch action {
                case .toggle:
                    togglePlayback(on: screen)
                case .next:
                    screenManager.advancePlaylist(for: screen)
                case .previous:
                    screenManager.regressPlaylist(for: screen)
                }
            },
            recapture: { refreshCover(screen.id) },
            copyOverlays: {
                if let session = overlaySession {
                    session.transition(to: session.identity, store: OverlayEditorScreenStore(manager: screenManager), editing: true)
                }
                confirmsOverlayCopy = true
            },
            snapEnabled: Binding(get: { overlaySession?.snapEnabled ?? true }, set: { overlaySession?.snapEnabled = $0 }),
            openAutomation: featureCatalog.isEnabled(.playlists) ? { showAutomation = true } : nil,
            resumeSchedule: { screenManager.resumeSchedule(for: screen) },
            applyScheme: { requestApplyScheme($0, to: screen) },
            manageSchemes: {
                libraryHandoff = .schemes
                router.closeDetail()
            },
            chooseFromLibrary: library?.items.isEmpty == false ? {
                libraryHandoff = .wallpapers(for: screen.id)
                router.closeDetail()
            } : nil,
            importFile: { chooseFile(screen) },
            enterWebAddress: { pasteURL(screen.id) },
            switchBackToVideo: switchBack.contains(.video) ? { switchToSaved(.video, on: screen) } : nil,
            switchBackToWebPage: switchBack.contains(.html) ? { switchToSaved(.html, on: screen) } : nil,
            applyWebSource: { apply(.html($0), screen.id) }
        )
    }

    private func togglePlayback(on screen: Screen) {
        guard let controller = screen.playbackController else { return }
        Self.togglePlayback(controller)
        screenManager.markWallpaperSessionStateChanged()
    }

    /// Flips what the user asked for, which the button shows: under a policy pause the intent to play
    /// stays set while nothing plays, and the button reads Pause, so it must pause rather than play.
    static func togglePlayback(_ playback: any WallpaperPlaybackControllable) {
        if playback.userIntendsToPlay {
            playback.pause()
        } else {
            playback.play()
        }
    }

    /// ⌘n picks the n-th display in the top bar's order.
    private func shortcuts(for screen: Screen) -> some View {
        ZStack {
            Button { pressSpace(on: screen) } label: { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
            ForEach(Array(stage.displays.prefix(9).enumerated()), id: \.element.id) { index, display in
                Button {
                    // A sheet holds the key window; switching under it would hand it another display.
                    guard NSApp.keyWindow === NSApp.mainWindow else { return }
                    router.showDetail(display.id)
                } label: { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// A key equivalent can be offered the key before the focused field, which then gets its Space back;
    /// while a sheet holds the key window the desktop does not toggle either.
    private func pressSpace(on screen: Screen) {
        guard let key = NSApp.keyWindow else { return }
        if let field = key.firstResponder as? NSText {
            if let event = NSApp.currentEvent, event.type == .keyDown {
                field.keyDown(with: event)
            }
        } else if key === NSApp.mainWindow {
            togglePlayback(on: screen)
        }
    }

    private func copyOverlays(on screen: Screen) {
        guard let result = overlaySession?.copyToOtherDisplays() else { return }
        toasts.post(
            String(format: String(localized: "Copied to %lld / %lld displays", bundle: .appLanguage),
                   Int64(result.copied), Int64(result.total)),
            style: result.copied == result.total ? .success : .info
        )
        reloadDraft(for: screen)
    }
}
