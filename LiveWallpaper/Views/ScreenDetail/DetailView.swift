import SwiftUI
import AppKit
import LiveWallpaperCore
import UniformTypeIdentifiers

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

enum OverlayKind: Hashable, CaseIterable {
    case weather
    case monitor
    case music
    case clock

    var title: LocalizedStringKey {
        switch self {
        case .weather: "Weather"
        case .monitor: "Widgets"
        case .music: "Music"
        case .clock: "Clock"
        }
    }

    var applyToAllName: String {
        switch self {
        case .weather: String(localized: "Weather", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .monitor: String(localized: "Widgets", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .music: String(localized: "Music", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .clock: String(localized: "Clock", bundle: .appLanguage, comment: "Independent decorative clock overlay.")
        }
    }

    var feature: ProductFeature {
        switch self {
        case .weather: .videoEffects
        case .monitor, .music, .clock: .monitorOverlay
        }
    }
}

struct DetailView: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    /// Not persisted, and deliberately survives a display switch: arranging
    /// overlays across two screens must not reset the tab on every hop.
    @State private var selectedTab: DisplayDetailTab = .wallpaper
    @State private var showsSceneQuickActions = false
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
        if let attempt = screenManager.wallpaperLoads.attempt(for: screen), let failure = attempt.failure {
            if selectedTab != .wallpaper || !attempt.isInspecting {
                InlineNoticeBanner(
                    tint: DesignTokens.Colors.Status.warning,
                    symbol: "exclamationmark.triangle.fill",
                    title: Text("Last wallpaper application failed"),
                    message: Text(verbatim: LogPrivacyRedactor.scrub(failure.title)),
                    code: failure.cause.code,
                    surface: .content
                ) {
                    Button("View Details") {
                        screenManager.inspectWallpaperAttempt(true, for: screen)
                        selectedTab = .wallpaper
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
            }
        } else if let runtimeError {
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

    private struct DerivedViewState {
        var showsGuideEmptyState: Bool
        var showsInspector: Bool
        var showsHeaderWallpaperActions: Bool
    }

    private var showsOverlaysTab: Bool {
        featureCatalog.isEnabled(.monitorOverlay) || featureCatalog.isEnabled(.videoEffects)
    }

    private var derivedState: DerivedViewState {
        guard selectedTab == .wallpaper else {
            return DerivedViewState(
                showsGuideEmptyState: false,
                showsInspector: showsOverlaysTab,
                showsHeaderWallpaperActions: false
            )
        }

        if screenManager.inspectedWallpaperAttempt(for: screen) != nil {
            return DerivedViewState(showsGuideEmptyState: false, showsInspector: true, showsHeaderWallpaperActions: false)
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
                return draft.htmlSource != nil
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
    private var showsInspector: Bool { inspectorApplicable && inspectorUserVisible }
    private var showsHeaderWallpaperActions: Bool { derivedState.showsHeaderWallpaperActions }

    private enum DropFailure: Identifiable {
        case unrecognizedDrop
        case sceneLibraryDrop
        case sceneUnsupportedInBuild
        case videoFormatUnsupported
        case videoBookmarkFailed
        /// The file read fine and the copy into app storage failed — not permissions.
        case videoCopyFailed
        case htmlBookmarkFailed
        case htmlPickerWrongType

        var id: String {
            switch self {
            case .unrecognizedDrop: "unrecognizedDrop"
            case .sceneLibraryDrop: "sceneLibraryDrop"
            case .sceneUnsupportedInBuild: "sceneUnsupportedInBuild"
            case .videoFormatUnsupported: "videoFormatUnsupported"
            case .videoBookmarkFailed: "videoBookmarkFailed"
            case .videoCopyFailed: "videoCopyFailed"
            case .htmlBookmarkFailed: "htmlBookmarkFailed"
            case .htmlPickerWrongType: "htmlPickerWrongType"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .unrecognizedDrop: "Unsupported file type"
            case .sceneLibraryDrop: "That folder is a scene library"
            case .sceneUnsupportedInBuild: "This version doesn't play scenes"
            case .videoFormatUnsupported: "Video format not supported"
            case .videoBookmarkFailed: "Couldn't open video"
            case .videoCopyFailed: "Couldn't copy that video"
            case .htmlBookmarkFailed: "Couldn't open web resource"
            case .htmlPickerWrongType: "Pick a web file or folder"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .unrecognizedDrop:
                "Drop a video file, web file, or folder to use it as a wallpaper."
            case .sceneLibraryDrop:
                "It holds many wallpapers rather than one. Import it from the Workshop library instead."
            case .sceneUnsupportedInBuild:
                "This copy of Loomscreen plays video and web wallpapers. Drop one of those instead."
            case .videoFormatUnsupported:
                "Choose an .mp4, .mov, .m4v, or similar video file."
            case .videoBookmarkFailed:
                "macOS couldn't grant the app secure access to that file. Try a different video, or move the file to a folder you own."
            case .videoCopyFailed:
                "Loomscreen couldn't copy it into its own storage. Check free space and try again."
            case .htmlBookmarkFailed:
                "macOS couldn't grant the app secure access to that resource. Try moving it to a folder you own."
            case .htmlPickerWrongType:
                "The selection isn't a web file or a folder containing an index page."
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
        .frame(minWidth: DesignTokens.LibraryPage.minWidth, minHeight: DesignTokens.LibraryPage.minHeight)
        .background(DesignTokens.Colors.pageBackground)
        .toolbar {
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
        .onChange(of: screenManager.inspectedWallpaperAttempt(for: screen)?.id) { loadScreenConfiguration() }
        .onChange(of: screenManager.inspectedWallpaperAttempt(for: screen)?.configuration) { loadScreenConfiguration() }
        .onChange(of: screen.id) {
            cleanupPreviewPlayer()
            scheduleConfigurationLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { notification in
            if notification.userInfo?["screenID"] as? CGDirectDisplayID == screen.id,
               notification.userInfo?["failureID"] != nil {
                selectedTab = .wallpaper
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            scheduleConfigurationLoad()
        }
        .alert(
            dropFailure.map { Text($0.title) } ?? Text(verbatim: ""),
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
        .onPreferenceChange(SceneQuickActionsVisibleKey.self) { visible in
            showsSceneQuickActions = visible
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
            onResetPlayback: resetPlaybackSettings,
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
            showsSceneQuickActions: showsSceneQuickActions,
            appliesOverlayOnly: selectedTab == .overlays,
            showBookmarks: $showBookmarks,
            onApplyToAll: requestApplyToAll,
            onClearWallpaper: clearCurrentWallpaper
        )
    }

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
                onWeatherReactiveChange: { screenManager.setWeatherReactive($0, for: screen) },
                onWeatherWindChange: { screenManager.setWeatherWind($0, for: screen) },
                onWeatherIntensityChange: { screenManager.setWeatherIntensity($0, for: screen) }
            )
        } else {
            #if !LITE_BUILD
            if let attempt = screenManager.inspectedWallpaperAttempt(for: screen) {
                AttemptSceneProperties(screen: screen, attempt: attempt)
                    .id(attempt.id)
                    .frame(width: width)
            } else {
                wallpaperInspectorPanel(width: width)
            }
            #else
            wallpaperInspectorPanel(width: width)
            #endif
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
        case .unrecognizedDrop, .sceneUnsupportedInBuild:
            Button("Choose Video") { showFilePicker() }
            Button("Choose Web") { showHTMLSourcePicker() }
            Button("Cancel", role: .cancel) { }

        case .sceneLibraryDrop:
            Button("Cancel", role: .cancel) {}

        case .videoFormatUnsupported, .videoBookmarkFailed, .videoCopyFailed:
            Button("Choose Different Video") { showFilePicker() }
            Button("Cancel", role: .cancel) { }

        case .htmlBookmarkFailed, .htmlPickerWrongType:
            Button("Choose Different Source") { showHTMLSourcePicker() }
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
        selectedTab = .wallpaper

        let videoURLs = urls.filter(ResourceUtilities.isSupportedVideoURL)
        if videoURLs.count > 1 {
            handleMultipleVideoDrop(urls: videoURLs)
            return true
        }

        // Without this a dropped scene folder would fall through to the HTML
        // folder fallback and load as a web wallpaper.
        let sceneCapable = featureCatalog.isEnabled(.scene)
        if !sceneCapable, WallpaperImportRouter.isWallpaperEngineProjectFolder(droppedURL) {
            dropFailure = .sceneUnsupportedInBuild
            return false
        }

        switch WallpaperImportRouter.route(droppedURL, sceneCapable: sceneCapable) {
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
            dropFailure = .sceneUnsupportedInBuild
            return false
            #endif
        case .sceneLibrary:
            dropFailure = .sceneLibraryDrop
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
        let config = screenManager.inspectedWallpaperAttempt(for: screen)?.configuration ?? screenManager.getConfiguration(for: screen)
        // The equality guard is load-bearing: reassigning an identical draft
        // rebuilds the entire inspector on every settings commit.
        let next = DraftState.from(
            config: config,
            fallbackHasPreviewSource: screen.videoPlayer?.videoURL != nil
        )
        if draft != next {
            draft = next
        }

        if config?.wallpaperType != .video, lastPreviewPosterBookmarkData != nil {
            lastPreviewPosterBookmarkData = nil
        }
        if config == nil {
            previewController.cleanup()
        }

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
        // `sceneCapable: false` — routing here would silently switch the page's type.
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
        draft.selectedWallpaperType = .video

        switch ResourceUtilities.videoBookmark(for: url) {
        case let .success(bookmarkData):
            draft.hasPreviewSource = true
            lastPreviewPosterBookmarkData = bookmarkData
            previewController.loadPoster(from: url, syncTime: nil)
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        case .failure(.couldNotCopy):
            dropFailure = .videoCopyFailed
        case .failure(.couldNotBookmarkCopy):
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

    private func performClearWallpaper() {
        cleanupPreviewPlayer()
        screenManager.clearWallpaperForScreen(screen)
    }

    private func requestApplyToAll() {
        let others = max(0, screenManager.screens.count - 1)
        guard selectedTab == .overlays else {
            pendingDestructive = PendingDestructive(
                .applyConfigurationToAllDisplays(otherCount: others)
            ) {
                screenManager.applyConfigurationToAllDisplays(from: screen)
            }
            return
        }
        let kind = overlayKind
        pendingDestructive = PendingDestructive(
            .applyOverlayToAllDisplays(overlayName: kind.applyToAllName, otherCount: others)
        ) {
            screenManager.applyOverlayToAllDisplays(kind, from: screen)
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
