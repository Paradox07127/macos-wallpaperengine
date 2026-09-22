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
    /// Held while a tile is in flight either way, so the stage stays locked through the return.
    @Binding var busy: Bool
    /// The page's own toast stack, so overlay copies and wallpaper applies queue in one place.
    let toasts: EditDeskToastCenter

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?
    @State private var coordinator: DetailTransitionCoordinator?
    @State private var section: DetailSection = .wallpaper
    @AppStorage("loomscreen.editDesk.inspectorWidth", store: .appScoped()) private var inspectorWidth = 372.0
    @AppStorage("loomscreen.editDesk.inspectorVisible", store: .appScoped()) private var inspectorVisible = true
    @AppStorage("loomscreen.editDesk.layersVisible", store: .appScoped()) private var layersVisible = true
    @State private var liveInspectorWidth: Double?
    /// The same optimistic-write draft the old inspector uses; the HUD and the panel both write it.
    @State private var draft = DraftState.default
    @State private var overlaySessions: [String: OverlayEditorSession] = [:]
    @State private var overlaySession: OverlayEditorSession?
    @State private var schemeNameDraft = ""
    @State private var showSchemeCapture = false
    @State private var showAutomation = false
    @State private var pendingAction: PendingAction?
    @State private var pendingDestructive: PendingDestructive?
    /// Shared with the old detail page so the colour group's disclosure survives switching pages.
    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false

    private enum PendingAction: Identifiable {
        case clearWallpaper, applyToAll, copyOverlays

        var id: Self {
            self
        }
    }

    var body: some View {
        ZStack {
            if let id = coordinator?.shownDisplayID, let screen = screenManager.screens.first(where: { $0.id == id }) {
                let status = heroStatus(screen)
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
                                             inspectorVisible: $inspectorVisible,
                                             inspectorWidth: $inspectorWidth, liveInspectorWidth: $liveInspectorWidth,
                                             topInset: showsOverlayOnboarding ? OnboardingCardMetrics.blockHeight - DetailGeometry.topBarHeight : 0,
                                             recapture: { refreshCover(id); overlaySession.capturePreview() },
                                             back: router.closeDetail)
                        }
                    },
                    overlayTopInset: 0,
                    isEmpty: screenManager.getConfiguration(for: screen) == nil && screenManager.inspectedWallpaperAttempt(for: screen) == nil,
                    emptyScreen: screen, chooseFile: { chooseFile(screen) }, pasteURL: { pasteURL(id) },
                    inspectorVisible: $inspectorVisible, layersVisible: $layersVisible,
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
                .confirmationDialog(pendingTitle, isPresented: pendingBinding, titleVisibility: .visible, presenting: pendingAction) { action in
                    Button(pendingConfirmTitle(action)) { perform(action, on: screen) }
                    Button("Cancel", role: .cancel) {}
                } message: { action in
                    Text(pendingMessage(action))
                }
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
        .onChange(of: coordinator?.busy ?? false, initial: true) { _, value in
            busy = value
        }
        .onChange(of: stage.stageSize) { coordinator?.windowDidResize() }
        .onChange(of: inspectorWidth) { coordinator?.windowDidResize() }
        .onChange(of: inspectorVisible) { coordinator?.windowDidResize() }
        .onChange(of: screenManager.screens.map(\.id)) {
            if let id = overlaySession?.identity?.displayID, !screenManager.screens.contains(where: { $0.id == id }) {
                overlaySession?.detach()
                overlaySession = nil
                pendingAction = nil
            }
        }
        .onDisappear { overlaySession?.detach() }
    }

    private var showsOverlayOnboarding: Bool {
        section == .overlay && progress?.handled.contains(.overlay) == false
    }

    // MARK: Handshake

    /// The hooks are reassigned here rather than at init so they capture the installed view.
    private func request(_ id: CGDirectDisplayID?) {
        if id != coordinator?.shownDisplayID {
            overlaySession?.detach()
            pendingAction = nil
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

    private func hud(for screen: Screen) -> some View {
        WallpaperPreviewHUD(showsViewport: draft.selectedWallpaperType != .html) {
            fitModePicker(for: screen)
        } playback: {
            WallpaperPlaybackControls(
                screen: screen,
                draft: $draft,
                screenManager: screenManager,
                onPlaybackSpeedChange: { screenManager.updatePlaybackSpeed($0, for: screen) },
                onResetPlayback: { resetPlaybackSettings(for: screen) }
            )
        } actions: {
            EmptyView()
        }
    }

    @ViewBuilder
    private func fitModePicker(for screen: Screen) -> some View {
        if draft.selectedWallpaperType != .html {
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
        pendingDestructive = PendingDestructive(.resetDisplaySettings(displayName: screen.name)) {
            screenManager.resetDisplaySettings(for: screen)
        }
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
            isPlaying: screen.playbackController?.isPlaying ?? false,
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
        DetailActions(
            back: router.closeDetail,
            selectDisplay: { router.showDetail($0) },
            saveAsScheme: { showSchemeCapture = true },
            applyToAll: { pendingAction = .applyToAll },
            clearWallpaper: { pendingAction = .clearWallpaper },
            playback: { action in
                switch action {
                case .toggle:
                    guard let controller = screen.playbackController else { return }
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
            },
            recapture: { refreshCover(screen.id) },
            copyOverlays: {
                if let session = overlaySession {
                    session.transition(to: session.identity, store: OverlayEditorScreenStore(manager: screenManager), editing: true)
                }
                pendingAction = .copyOverlays
            },
            snapEnabled: Binding(get: { overlaySession?.snapEnabled ?? true }, set: { overlaySession?.snapEnabled = $0 }),
            openAutomation: featureCatalog.isEnabled(.playlists) ? { showAutomation = true } : nil
        )
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { presented in
                if !presented {
                    pendingAction = nil
                }
            }
        )
    }

    private var pendingTitle: Text {
        switch pendingAction {
        case .clearWallpaper: Text("Clear this display's wallpaper?")
        case .applyToAll: Text("Apply this display's wallpaper to all displays?")
        case .copyOverlays: Text("Copy overlays to other displays?")
        case nil: Text(verbatim: "")
        }
    }

    private func pendingConfirmTitle(_ action: PendingAction) -> LocalizedStringKey {
        switch action {
        case .clearWallpaper: "Clear Wallpaper"
        case .applyToAll: "Apply to All Displays"
        case .copyOverlays: "Copy to Other Displays"
        }
    }

    private func pendingMessage(_ action: PendingAction) -> LocalizedStringKey {
        switch action {
        case .clearWallpaper: "The desktop goes back to the system wallpaper; saved wallpapers are kept."
        case .applyToAll: "Every other connected display gets this wallpaper and its settings."
        case .copyOverlays: "This replaces overlays on every other connected display. Effects are skipped on displays without a wallpaper."
        }
    }

    private func perform(_ action: PendingAction, on screen: Screen) {
        switch action {
        case .clearWallpaper:
            screenManager.clearWallpaperForScreen(screen)
        case .applyToAll:
            screenManager.applyConfigurationToAllDisplays(from: screen)
        case .copyOverlays:
            guard let result = overlaySession?.copyToOtherDisplays() else { return }
            toasts.post(
                String(format: String(localized: "Copied to %lld / %lld displays", bundle: .appLanguage),
                       Int64(result.copied), Int64(result.total)),
                style: result.copied == result.total ? .success : .info
            )
        }
        // Clearing only bumps the session version; the draft would keep the old wallpaper's panel.
        reloadDraft(for: screen)
    }
}
