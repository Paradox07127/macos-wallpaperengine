import SwiftUI
import AppKit
import LiveWallpaperCore
import UniformTypeIdentifiers

/// The two things a display carries: what plays on it, and what floats over it.
/// Overlays are stored per display (`ScreenManager.monitorOverlay(for:)`), so the
/// display is their natural home — but they are not a wallpaper *type*, which is
/// why this is a tab above the type picker rather than a fourth segment in it.
enum DisplayDetailTab: Hashable, CaseIterable {
    case wallpaper
    case overlays

    var title: LocalizedStringKey {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .overlays:  return "Overlays"
        }
    }
}

/// The overlays tab's own pages, picked the same way wallpaper types are —
/// weather and the monitor board share nothing but the display they float over,
/// so stacking both sets of controls in one panel only made it longer.
enum OverlayKind: Hashable, CaseIterable {
    case weather
    case monitor
    case music

    var title: LocalizedStringKey {
        switch self {
        case .weather: return "Weather"
        case .monitor: return "Monitor"
        case .music:   return "Music"
        }
    }

    var feature: ProductFeature {
        switch self {
        case .weather: return .videoEffects
        // Music rides on the monitor board, so it ships wherever Monitor does.
        case .monitor, .music: return .monitorOverlay
        }
    }
}

struct DetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    /// Session state, not persisted: a display's reason for existing is its
    /// wallpaper, so a relaunch should land there. Surviving a display switch is
    /// deliberate though — arranging overlays across two screens shouldn't reset
    /// the tab on every hop.
    @State private var selectedTab: DisplayDetailTab = .wallpaper
    @State private var selectedOverlayKind: OverlayKind = .weather

    @State private var draft: DraftState = .default
    @State private var isLoading: Bool = false
    private var wallpaperSessionSummary: WallpaperSessionSummary {
        screenManager.wallpaperSummary(for: screen)
    }
    private var runtimeError: WallpaperRuntimeError? {
        screenManager.runtimeError(for: screen)
    }

    @ViewBuilder
    private var runtimeErrorBannerView: some View {
        if let runtimeError {
            let activeType = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
            let canRePick = activeType == .video || activeType == .html
            RuntimeErrorBanner(
                error: runtimeError,
                canRePick: canRePick,
                onRetry: { screenManager.retryRuntimeSession(for: screen) },
                onRePick: rePickRuntimeSource
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    private var detailTabPicker: some View {
        Picker("Display section", selection: $selectedTab) {
            ForEach(DisplayDetailTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Display section"))
        .accessibilityHint(Text("Switch between this display's wallpaper and its overlays"))
    }

    private var overlayKindPicker: some View {
        Picker("Overlay", selection: overlayKindSelection) {
            ForEach(availableOverlayKinds, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Overlay"))
        .accessibilityHint(Text("Choose which overlay to arrange"))
    }

    private var availableOverlayKinds: [OverlayKind] {
        OverlayKind.allCases.filter { featureCatalog.isEnabled($0.feature) }
    }

    /// Clamped to what this SKU ships, so a stale selection can't leave the page
    /// rendering an overlay the build doesn't have.
    private var overlayKind: OverlayKind {
        availableOverlayKinds.contains(selectedOverlayKind)
            ? selectedOverlayKind
            : (availableOverlayKinds.first ?? .weather)
    }

    private var overlayKindSelection: Binding<OverlayKind> {
        Binding(get: { overlayKind }, set: { selectedOverlayKind = $0 })
    }

    @ViewBuilder
    private var wallpaperTypePicker: some View {
        Picker("Wallpaper Type", selection: wallpaperTypeSelection) {
            ForEach(featureCatalog.capabilities.selectableWallpaperTypes) { type in
                Text(type.titleKey).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Wallpaper type"))
        .accessibilityHint(Text("Choose wallpaper type"))
    }

    private var wallpaperTypeSelection: Binding<WallpaperType> {
        Binding(
            get: { draft.selectedWallpaperType },
            set: { newType in
                guard draft.selectedWallpaperType != newType else { return }
                draft.selectedWallpaperType = newType
                handleWallpaperTypeSelection(newType)
            }
        )
    }

    private func handleWallpaperTypeSelection(_ newType: WallpaperType) {
        Logger.info("Wallpaper type selected for screen \(screen.id): \(newType.rawValue)", category: .ui)
        switch newType {
        case .video:
            screenManager.switchToVideoWallpaper(for: screen)
        case .html:
            screenManager.switchToHTMLWallpaper(for: screen)
        case .scene:
            break
        }
    }

    /// Collapses three booleans that were computed inline from overlapping
    /// store/runtime state into one place so the rules stay auditable.
    private struct DerivedViewState {
        var showsGuideEmptyState: Bool
        var showsInspector: Bool
        var showsHeaderWallpaperActions: Bool
    }

    /// Hidden only when neither overlay ships in this SKU.
    private var showsOverlaysTab: Bool {
        featureCatalog.isEnabled(.monitorOverlay) || featureCatalog.isEnabled(.videoEffects)
    }

    private var derivedState: DerivedViewState {
        // Overlays own the whole page: their inspector is the only control
        // surface, and it must not depend on a wallpaper being configured —
        // that dependency is exactly what made the old overlays tab unreachable
        // on a bare display.
        guard selectedTab == .wallpaper else {
            return DerivedViewState(
                showsGuideEmptyState: false,
                showsInspector: showsOverlaysTab,
                showsHeaderWallpaperActions: false
            )
        }

        let config = screenManager.getConfiguration(for: screen)
        let hasRuntimeOrPreview = screen.runtimeSession != nil
            || draft.hasPreviewSource
            || previewController.hasPreviewContent

        let showsGuide: Bool = !isLoading
            && config == nil
            && !hasRuntimeOrPreview
            && draft.selectedWallpaperType == .video

        let hasConfigurable = !showsGuide && (config != nil || hasRuntimeOrPreview)

        let showsInspector: Bool = {
            guard hasConfigurable else { return false }
            switch draft.selectedWallpaperType {
            case .video:
                return config?.wallpaperType == .video && (config?.hasConfiguredVideoSource ?? false)
            case .html:
                return true
            case .scene:
                return config?.wallpaperType == .scene
            }
        }()

        return DerivedViewState(
            showsGuideEmptyState: showsGuide,
            showsInspector: showsInspector,
            showsHeaderWallpaperActions: hasConfigurable
        )
    }

    private var shouldShowGuideEmptyState: Bool { derivedState.showsGuideEmptyState }
    private var inspectorApplicable: Bool { derivedState.showsInspector }
    /// Final visibility = applicable AND the user hasn't collapsed the panel.
    private var showsInspector: Bool { inspectorApplicable && inspectorUserVisible }
    private var showsHeaderWallpaperActions: Bool { derivedState.showsHeaderWallpaperActions }

    /// Each case carries enough context to render a meaningful retry / re-pick
    /// action instead of a dead-end "OK" dismissal.
    private enum DropFailure: Identifiable {
        case unrecognizedDrop
        case videoFormatUnsupported
        case videoBookmarkFailed
        case htmlBookmarkFailed
        case htmlPickerWrongType

        var id: String {
            switch self {
            case .unrecognizedDrop:       return "unrecognizedDrop"
            case .videoFormatUnsupported: return "videoFormatUnsupported"
            case .videoBookmarkFailed:    return "videoBookmarkFailed"
            case .htmlBookmarkFailed:     return "htmlBookmarkFailed"
            case .htmlPickerWrongType:    return "htmlPickerWrongType"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .unrecognizedDrop:       return "Unsupported file type"
            case .videoFormatUnsupported: return "Video format not supported"
            case .videoBookmarkFailed:    return "Couldn't open video"
            case .htmlBookmarkFailed:     return "Couldn't open web resource"
            case .htmlPickerWrongType:    return "Pick a web file or folder"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .unrecognizedDrop:
                return "Drop a video file, web file, or folder to use it as a wallpaper."
            case .videoFormatUnsupported:
                return "Choose an .mp4, .mov, .m4v, or similar video file."
            case .videoBookmarkFailed:
                return "macOS couldn't grant the app secure access to that file. Try a different video, or move the file to a folder you own."
            case .htmlBookmarkFailed:
                return "macOS couldn't grant the app secure access to that resource. Try moving it to a folder you own."
            case .htmlPickerWrongType:
                return "The selection isn't a web file or a folder containing an index page."
            }
        }
    }

    @State private var dropFailure: DropFailure?
    @State private var pendingDestructive: PendingDestructive?
    @State private var previewController = InspectorPreviewController()
    @State private var lastPreviewPosterBookmarkData: Data?

    @State private var isDraggingOver = false
    @State private var showBookmarks = false


    @AppStorage("Inspector.ColorExpanded") private var isColorExpanded = false
    @AppStorage("Inspector.Width") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?
    /// Persisted so a collapsed inspector stays collapsed across launches.
    @AppStorage("Inspector.Visible") private var inspectorUserVisible = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        InspectorSplit(
            isMounted: inspectorApplicable,
            isVisible: showsInspector,
            animationTrigger: AnyHashable(inspectorUserVisible),
            reduceMotion: reduceMotion,
            storedWidth: $inspectorWidth,
            liveWidth: $liveInspectorWidth,
            onClose: { inspectorUserVisible = false },
            main: { mainColumn },
            inspector: { width in inspectorPanel(width: width) }
        )
        // Same size floor as the DetailPageScaffold pages (Bookmarks/Aerials/
        // Workshop) — this page hand-rolls the scaffold, so it opts in here.
        .frame(minWidth: DesignTokens.LibraryPage.minWidth, minHeight: DesignTokens.LibraryPage.minHeight)
        .background(DesignTokens.Colors.pageBackground)
        .toolbar {
            // Leading, so it reads outer-to-inner left to right: which side of
            // the display you're editing, then which kind of wallpaper.
            if showsOverlaysTab {
                ToolbarItem(placement: .navigation) {
                    detailTabPicker
                }
            }
            if selectedTab == .wallpaper {
                ToolbarItem(placement: .principal) {
                    wallpaperTypePicker
                }
            } else if availableOverlayKinds.count > 1 {
                ToolbarItem(placement: .principal) {
                    overlayKindPicker
                }
            }
            // Hidden when there is no panel behind it. It is declared last, so
            // it still returns to the trailing edge when it comes back.
            if inspectorApplicable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspectorUserVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(Text(inspectorUserVisible ? "Hide the properties panel" : "Show the properties panel"))
                    .accessibilityLabel(Text("Toggle properties panel"))
                    .accessibilityHint(Text("Show or hide the wallpaper properties on the right"))
                }
            }
        }
        .confirmDestructive($pendingDestructive)
        .onAppear { scheduleConfigurationLoad() }
        .onDisappear { cleanupPreviewPlayer() }
        .onChange(of: screen.id) {
            cleanupPreviewPlayer()
            scheduleConfigurationLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            scheduleConfigurationLoad()
        }
        .alert(
            dropFailure.map { Text($0.title) } ?? Text(""),
            isPresented: dropFailurePresented,
            presenting: dropFailure
        ) { failure in
            dropFailureButtons(failure)
        } message: { failure in
            Text(failure.message)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDraggingOver = targeted
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            screenHeader

            runtimeErrorBannerView

            Divider()

            if selectedTab == .overlays {
                OverlayPreviewArea(
                    screen: screen,
                    draft: draft,
                    screenManager: screenManager,
                    kind: overlayKind,
                    backdrop: monitorBackdrop
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                wallpaperPreviewArea
            }
        }
    }

    private var wallpaperPreviewArea: some View {
        PreviewArea(
            screen: screen,
            draft: $draft,
            featureCatalog: featureCatalog,
            screenManager: screenManager,
            previewController: previewController,
            isLoading: isLoading,
            isDraggingOver: isDraggingOver,
            reduceMotion: reduceMotion,
            showsGuideEmptyState: shouldShowGuideEmptyState,
            onChooseVideo: showFilePicker,
            onChooseHTML: { draft.selectedWallpaperType = .html },
            onChooseScene: { draft.selectedWallpaperType = .scene },
            onSelectVideoFile: showFilePicker,
            onStartPreview: setupPreviewPlayer,
            onPlaybackSpeedChange: { screenManager.updatePlaybackSpeed($0, for: screen) },
            onFitModeChange: { screenManager.updateFitMode($0, for: screen) }
        )
    }

    private var screenHeader: some View {
        Header(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            wallpaperSessionSummary: wallpaperSessionSummary,
            reduceMotion: reduceMotion,
            showsHeaderWallpaperActions: showsHeaderWallpaperActions,
            showBookmarks: $showBookmarks,
            onApplyToAll: requestApplyToAll,
            onClearWallpaper: clearCurrentWallpaper
        )
    }

    /// A still of what's playing, so the board is arranged against the wallpaper
    /// it will actually sit on rather than a blank rectangle.
    private var monitorBackdrop: MonitorPreviewBackdrop {
        if draft.selectedWallpaperType == .video, let poster = previewController.posterImage {
            return .still(poster)
        }
        #if !LITE_BUILD
        if let url = draft.wpeOrigin?.sourcePreviewURL {
            return .projectPreview(url, bookmark: draft.wpeOrigin?.sourceFolderBookmark)
        }
        #endif
        return .none
    }

    @ViewBuilder
    private func inspectorPanel(width: CGFloat) -> some View {
        if selectedTab == .overlays {
            OverlaysInspectorPanel(
                screen: screen,
                draft: $draft,
                screenManager: screenManager,
                kind: overlayKind,
                inspectorPanelWidth: width,
                backdropAvailable: monitorBackdrop.isAvailable,
                onParticleEffectChange: { screenManager.updateParticleEffect($0, for: screen) },
                onParticleDensityChange: { screenManager.updateParticleDensity($0, for: screen) },
                onWeatherReactiveChange: { screenManager.setWeatherReactive($0, for: screen) }
            )
        } else {
            wallpaperInspectorPanel(width: width)
        }
    }

    private func wallpaperInspectorPanel(width: CGFloat) -> some View {
        DetailInspectorPanel(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            featureCatalog: featureCatalog,
            reduceMotion: reduceMotion,
            inspectorPanelWidth: width,
            isColorExpanded: $isColorExpanded,
            onWallpaperModeChange: { screenManager.updateWallpaperMode($0, for: screen) },
            showsResetPlayback: screenManager.displayPlaybackDiffersFromDefaults(for: screen),
            onResetPlaybackSettings: resetPlaybackSettings,
            showsResetDisplaySettings: screenManager.displaySettingsDifferFromDefaults(for: screen),
            onResetDisplaySettings: requestResetDisplaySettings
        )
    }

    private var dropFailurePresented: Binding<Bool> {
        Binding(
            get: { dropFailure != nil },
            set: { if !$0 { dropFailure = nil } }
        )
    }

    @ViewBuilder
    private func dropFailureButtons(_ failure: DropFailure) -> some View {
        switch failure {
        case .unrecognizedDrop:
            Button("Choose Video…") { showFilePicker() }
            Button("Choose Web…") { showHTMLSourcePicker() }
            Button("Cancel", role: .cancel) { }

        case .videoFormatUnsupported, .videoBookmarkFailed:
            Button("Choose Different Video…") { showFilePicker() }
            Button("Cancel", role: .cancel) { }

        case .htmlBookmarkFailed, .htmlPickerWrongType:
            Button("Choose Different Source…") { showHTMLSourcePicker() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func requestResetDisplaySettings() {
        pendingDestructive = PendingDestructive(
            .resetDisplaySettings(displayName: screen.name)
        ) {
            screenManager.resetDisplaySettings(for: screen)
        }
    }

    private func resetPlaybackSettings() {
        screenManager.resetPlaybackSettings(for: screen)
        loadScreenConfiguration()
    }

    // MARK: - Drag and Drop
    private func handleDrop(urls: [URL]) -> Bool {
        defer { isDraggingOver = false }
        guard let droppedURL = urls.first else { return false }
        // The drop target is the whole page, so a drop can land while the
        // overlays board is showing — surface the wallpaper it just changed
        // instead of leaving the user on a tab that doesn't reflect it.
        selectedTab = .wallpaper

        // A multi-file video drop becomes a playlist, so that case is checked
        // before single-URL routing.
        let videoURLs = urls.filter(ResourceUtilities.isSupportedVideoURL)
        if videoURLs.count > 1 {
            handleMultipleVideoDrop(urls: videoURLs)
            return true
        }

        switch WallpaperImportRouter.route(droppedURL, sceneCapable: featureCatalog.isEnabled(.scene)) {
        case .video(let url):
            handleSelectedFile(url: url)
            return true
        case .html(let source):
            applyHTMLDrop(source)
            return true
        case .sceneProject(let folderURL):
            #if !LITE_BUILD
            applySceneDrop(folderURL)
            return true
            #else
            dropFailure = .unrecognizedDrop
            return false
            #endif
        case .sceneLibrary:
            // A library root holds many projects and no single wallpaper to show
            // here; the toolbar's picker routes those into the Workshop library.
            dropFailure = .unrecognizedDrop
            return false
        case .unsupported:
            dropFailure = .unrecognizedDrop
            return false
        }
    }

    #if !LITE_BUILD
    private func applySceneDrop(_ url: URL) {
        draft.selectedWallpaperType = .scene
        Task { @MainActor in
            await screenManager.importWallpaperEngineProject(at: url, for: screen)
        }
    }
    #endif

    private func handleMultipleVideoDrop(urls: [URL]) {
        guard let primaryURL = urls.first else { return }
        let bookmarks = urls.compactMap { ResourceUtilities.createVideoBookmark(for: $0) }
        guard let primaryBookmark = bookmarks.first, bookmarks.count == urls.count else {
            handleSelectedFile(url: primaryURL)
            return
        }
        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()
        draft.selectedWallpaperType = .video
        draft.hasPreviewSource = true
        lastPreviewPosterBookmarkData = primaryBookmark
        previewController.loadPoster(from: primaryURL, syncTime: nil)
        screenManager.replacePlaylist(ordered: bookmarks, primary: primaryBookmark, for: screen)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = false }
        }
    }

    private func applyHTMLDrop(_ source: HTMLSource) {
        draft.selectedWallpaperType = .html
        screenManager.setHTMLWallpaper(source: source, config: draft.htmlConfig, for: screen)
    }

    // MARK: - Helper Methods
    func setupPreviewPlayer() {
        guard let url = resolvePreviewVideoURL() else { return }
        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video {
            lastPreviewPosterBookmarkData = config.videoBookmarkData
        }
        previewController.startPlaybackPreview(from: url, syncTo: screen.videoPlayer?.player)
    }

    private func scheduleConfigurationLoad() {
        DispatchQueue.main.async {
            Task { @MainActor in
                loadScreenConfiguration()
            }
        }
    }

    private func loadScreenConfiguration() {
        let config = screenManager.getConfiguration(for: screen)
        draft = .from(
            config: config,
            fallbackHasPreviewSource: screen.videoPlayer?.videoURL != nil
        )

        if config?.wallpaperType != .video, lastPreviewPosterBookmarkData != nil {
            lastPreviewPosterBookmarkData = nil
        }
        if config == nil {
            previewController.cleanup()
        }

        // Restart an active preview when playlist rotation changes its bookmark.
        if previewController.player != nil,
           let config,
           config.wallpaperType == .video,
           let activeBookmark = config.videoBookmarkData,
           activeBookmark != lastPreviewPosterBookmarkData {
            setupPreviewPlayer()
            return
        }

        loadPreviewPosterIfNeeded()
    }

    private func cleanupPreviewPlayer() {
        lastPreviewPosterBookmarkData = nil
        draft.hasPreviewSource = false
        previewController.cleanup()
    }

    private func showFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        handleSelectedFile(url: url)
    }

    private func rePickRuntimeSource() {
        let activeType = screen.runtimeSession?.wallpaperType ?? draft.selectedWallpaperType
        switch activeType {
        case .video:
            showFilePicker()
        case .html:
            showHTMLSourcePicker()
        case .scene:
            draft.selectedWallpaperType = activeType
        }
    }

    private func showHTMLSourcePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // This picker is the Web tab's own "choose a source", so it stays
        // HTML-only — routing here would silently switch the page's type.
        guard case .html(let source) = WallpaperImportRouter.route(url, sceneCapable: false) else {
            dropFailure = .htmlPickerWrongType
            return
        }
        applyHTMLDrop(source)
    }

    private func handleSelectedFile(url: URL) {
        guard ResourceUtilities.isSupportedVideoURL(url) else {
            dropFailure = .videoFormatUnsupported
            return
        }

        withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = true }
        cleanupPreviewPlayer()
        // A drop routes by what the file is, so the page has to follow it — the
        // web branch already does this in `applyHTMLDrop`.
        draft.selectedWallpaperType = .video

        if let bookmarkData = ResourceUtilities.createVideoBookmark(for: url) {
            draft.hasPreviewSource = true
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.loadPoster(from: url, syncTime: nil)
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        } else {
            dropFailure = .videoBookmarkFailed
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2))) { isLoading = false }
        }
    }

    private func clearCurrentWallpaper() {
        pendingDestructive = PendingDestructive(
            .clearCurrentWallpaper(displayName: screen.name)
        ) {
            performClearWallpaper()
        }
    }

    /// Full clear: the trash button removes the screen's WHOLE wallpaper configuration and tears down the live session, whatever type is running.
    private func performClearWallpaper() {
        cleanupPreviewPlayer()
        screenManager.clearWallpaperForScreen(screen)
    }

    private func requestApplyToAll() {
        let others = max(0, screenManager.screens.count - 1)
        pendingDestructive = PendingDestructive(
            .applyConfigurationToAllDisplays(otherCount: others)
        ) {
            screenManager.applyConfigurationToAllDisplays(from: screen)
        }
    }

    private func loadPreviewPosterIfNeeded() {
        guard previewController.player == nil else { return }

        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video,
           let bookmarkData = config.videoBookmarkData {
            if lastPreviewPosterBookmarkData == bookmarkData,
               previewController.posterImage != nil || previewController.isLoading {
                return
            }
            guard let url = resolvePreviewVideoURL() else { return }
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.loadPoster(from: url, syncTime: screen.videoPlayer?.player?.currentTime())
            return
        }

        if lastPreviewPosterBookmarkData != nil {
            lastPreviewPosterBookmarkData = nil
        }
        guard let url = screen.videoPlayer?.videoURL else { return }
        previewController.loadPoster(from: url, syncTime: screen.videoPlayer?.player?.currentTime())
    }

    private func resolvePreviewVideoURL() -> URL? {
        if let config = screenManager.getConfiguration(for: screen),
           config.wallpaperType == .video,
           let bookmarkData = config.videoBookmarkData {
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { return nil }
            let url = resolved.url
            if resolved.didRefresh {
                screenManager.replaceActiveBookmark(resolved.bookmarkData, for: screen)
            }
            return url
        }

        return screen.videoPlayer?.videoURL
    }
}
