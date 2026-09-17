#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import SwiftUI

struct ScenePreviewTaskIdentity: Hashable {
    let workshopID: String
    let sessionID: ObjectIdentifier?
    let propertyOverridesRevision: ScenePropertyOverridesRevision
    let propertyCommitSequence: UInt64?
}

struct ScenePreviewLifecycleState: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false
    private(set) var sessionID: ObjectIdentifier?

    mutating func begin(sessionID: ObjectIdentifier?) -> UInt64 {
        generation &+= 1
        isActive = true
        self.sessionID = sessionID
        return generation
    }

    private(set) var workshopID: String?
    /// Set while the poster on screen belongs to a previous session or commit of the same scene.
    private(set) var awaitsFreshPoster = false

    /// Same scene with a poster on screen: keep it as the backdrop and re-capture once the new frame lands. Anything else starts from the idle state.
    mutating func restart(
        workshopID: String,
        sessionID: ObjectIdentifier?,
        livePoster: inout NSImage?,
        state: inout SceneRenderState
    ) -> UInt64 {
        let keepsPoster = self.workshopID == workshopID && livePoster != nil
        invalidate()
        self.workshopID = workshopID
        awaitsFreshPoster = keepsPoster
        if !keepsPoster {
            livePoster = nil
            state = .idle
        }
        return begin(sessionID: sessionID)
    }

    mutating func acceptFreshPoster() {
        awaitsFreshPoster = false
    }

    /// The poster on screen stays as the backdrop until the next capture replaces it.
    mutating func requestFreshPoster() {
        awaitsFreshPoster = true
    }

    /// A remembered poster stands in like a kept one: shown at once, replaced by the next capture.
    static func seeded(workshopID: String) -> ScenePreviewLifecycleState {
        var state = ScenePreviewLifecycleState()
        state.workshopID = workshopID
        state.awaitsFreshPoster = true
        return state
    }

    mutating func invalidate() {
        generation &+= 1
        isActive = false
        sessionID = nil
    }

    func accepts(
        _ candidate: UInt64,
        sessionID: ObjectIdentifier?,
        isCancelled: Bool
    ) -> Bool {
        isActive
            && !isCancelled
            && candidate == generation
            && self.sessionID == sessionID
    }
}

/// Last captured live frame per scene, so a re-entered page paints it on its first frame instead of the static poster.
@MainActor
enum ScenePosterMemory {
    /// Posters are up to 1440 px on the long side (~4.7 MB); one per display's applied scene is all a re-entry needs.
    static let capacity = 4
    private static var posters: [String: NSImage] = [:]
    /// Least recently remembered first.
    private static var order: [String] = []

    static func poster(for workshopID: String) -> NSImage? {
        posters[workshopID]
    }

    static func remember(_ image: NSImage, for workshopID: String) {
        posters[workshopID] = image
        order.removeAll { $0 == workshopID }
        order.append(workshopID)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            posters[evicted] = nil
        }
    }

    static func rememberedCountForTesting() -> Int {
        posters.count
    }

    static func forgetAllForTesting() {
        posters.removeAll()
        order.removeAll()
    }
}

@MainActor
struct SceneDetailView: View {
    private let stackSpacing: CGFloat = 16

    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?
    /// The wallpaper is rendering (not paused or policy-suspended); a poster can only be captured from a frame it presents.
    let isPlaying: Bool
    @Binding var fitMode: VideoFitMode
    let playbackControls: AnyView

    init(
        origin: WPEOrigin,
        descriptor: SceneDescriptor,
        session: SceneWallpaperSession?,
        isPlaying: Bool = true,
        fitMode: Binding<VideoFitMode>,
        playbackControls: AnyView
    ) {
        self.origin = origin
        self.descriptor = descriptor
        self.session = session
        self.isPlaying = isPlaying
        _fitMode = fitMode
        self.playbackControls = playbackControls
        // The session caches its last polled renderer state, so the first frame is the settled frame (no spinner over a running scene) whenever a previous visit polled it.
        _state = State(initialValue: Self.derivedState(session: session))
        if let remembered = ScenePosterMemory.poster(for: descriptor.workshopID) {
            _livePoster = State(initialValue: remembered)
            _previewLifecycle = State(initialValue: .seeded(workshopID: descriptor.workshopID))
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var state: SceneRenderState = .idle
    @State private var livePoster: NSImage?
    @State private var livePosterTask: Task<Void, Never>?
    @State private var showLogSheet = false
    @State private var recaptureHovering = false
    /// Generation-scoped preview lifecycle; invalidate on disappear so late polls can't re-suspend.
    @State private var previewLifecycle = ScenePreviewLifecycleState()
    /// Session owned by preview lifecycle — clear outgoing override on task-ID change before swap.
    @State private var previewSession: SceneWallpaperSession?

    private var previewTaskIdentity: ScenePreviewTaskIdentity {
        // Must be the same layering `stageScenePropertyPosterCommit` stages with:
        // keyed on the increment alone, a preset-carrying descriptor never matches.
        let overridesRevision = ScenePropertyOverridesRevision(
            descriptor.layeredPropertyValues()
        )
        return ScenePreviewTaskIdentity(
            workshopID: descriptor.workshopID,
            sessionID: session.map(ObjectIdentifier.init),
            propertyOverridesRevision: overridesRevision,
            propertyCommitSequence: session?
                .stagedScenePropertyPosterCommit(matching: overridesRevision)?
                .sequence
        )
    }

    var body: some View {
        WallpaperPreviewStage {
            HStack(spacing: DesignTokens.Spacing.sm) {
                WallpaperPreviewTitle(text: origin.title)
                Spacer(minLength: DesignTokens.Spacing.sm)
                SceneInformationOverlay(origin: origin, descriptor: descriptor)
            }
        } content: {
            previewCard
        } controls: {
            VStack(spacing: stackSpacing) {
                errorBanner
                infoBar
            }
        }
        .sheet(isPresented: $showLogSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                DiagnosticLogSheet(title: origin.title, log: fullDiagnosticText, tint: currentSeverityTint)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(origin.title). Scene wallpaper. \(stateAccessibilityText)", comment: "A11y label for a Wallpaper Engine scene detail card. Placeholders are scene title and state."))
        .task(id: previewTaskIdentity) {
            guard !Task.isCancelled else { return }
            let targetSession = session
            let posterCommit = targetSession?.stagedScenePropertyPosterCommit(
                matching: previewTaskIdentity.propertyOverridesRevision
            )
            let generation = restartPreviewLifecycle(for: targetSession)
            guard !Task.isCancelled else { return }
            await pollPreviewUntilSettled(
                session: targetSession,
                generation: generation,
                posterCommit: posterCommit
            )
        }
        .onChange(of: reduceMotion) { _, _ in
            livePosterTask?.cancel()
            livePosterTask = nil
            let targetSession = session
            let generation = previewLifecycle.generation
            Task { @MainActor in
                await refreshState(
                    session: targetSession,
                    generation: generation
                )
            }
        }
        // A capture attempted while the wallpaper was suspended returns nothing, and a wake from hibernation reloads the scene: the resume is the only later chance to replace the static poster, so poll again until the renderer settles.
        .onChange(of: isPlaying) { _, playing in
            guard playing, livePoster == nil || previewLifecycle.awaitsFreshPoster, livePosterTask == nil else { return }
            let targetSession = session
            let generation = previewLifecycle.generation
            Task { @MainActor in
                await pollPreviewUntilSettled(session: targetSession, generation: generation)
            }
        }
        .onDisappear {
            previewLifecycle.invalidate()
            livePosterTask?.cancel()
            livePosterTask = nil
            livePoster = nil
            previewSession?.clearPreviewPerformanceOverride()
            if previewSession !== session {
                session?.clearPreviewPerformanceOverride()
            }
            previewSession = nil
        }
    }

    // MARK: - Subviews

    private var previewCard: some View {
        ZStack { stateBackground }
            .screenPreviewChrome()
            .overlay(alignment: .topTrailing) {
                if session != nil, !reduceMotion {
                    recapturePosterButton
                        .padding(DesignTokens.Spacing.sm)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: stateKey)
    }

    /// A capture needs a presented frame, so the button waits for `.ready` and for any capture in flight.
    private var canRecapturePoster: Bool {
        guard case .ready = state else { return false }
        return livePosterTask == nil
    }

    private var recapturePosterButton: some View {
        Button(action: recaptureLivePoster) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Explicit 0.72 like the history row's bookmark glyph: the default backing disappears into bright stills.
        .floatingGlyphGlass(hovered: recaptureHovering, opacity: 0.72)
        .onHover { recaptureHovering = $0 }
        .disabled(!canRecapturePoster)
        .help(Text("Recapture preview"))
        .accessibilityLabel(Text("Recapture preview"))
    }

    /// A kept poster of the same scene stands in for the rebuild: no blur, dimming or spinner over it.
    private var showsLoadingChrome: Bool {
        (state == .idle || state.isLoading) && !(previewLifecycle.awaitsFreshPoster && livePoster != nil)
    }

    @ViewBuilder
    private var stateBackground: some View {
        switch state {
        case .idle:
            fallbackBackground
            if showsLoadingChrome {
                ArcSpinner()
            }
        case .notRendering:
            fallbackBackground
        case .loading(let progress):
            fallbackBackground
            if showsLoadingChrome {
                ArcSpinner(progressText: progress)
            }
        case .ready:
            fallbackBackground
        case .error(let fallbackReason):
            fallbackBackground
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                        .strokeBorder(fallbackReason.tint.opacity(0.45), lineWidth: 1.5)
                }
        }
    }

    // MARK: - Error banner

    /// `.degraded` means one layer was skipped and the wallpaper is still playing,
    /// so it gets the HUD chip instead of a banner.
    @ViewBuilder
    private var errorBanner: some View {
        if case let .error(reason) = state, reason.failureClass != .degraded {
            let presentation = reason.presentation(
                origin: origin,
                engineAssetsAuthorized: engineAssets.isAuthorized
            )
            InlineNoticeBanner(
                tint: presentation.tint,
                symbol: presentation.symbol,
                title: presentation.title,
                message: presentation.message,
                code: presentation.code,
                surface: .chrome
            ) {
                WallpaperFailureRecoveryActions(
                    recovery: presentation.recovery,
                    onRetry: { reloadScene() }
                )
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var degradedChip: some View {
        if case let .error(reason) = state, reason.failureClass == .degraded {
            let detail = reason.localizedMessage(
                originalType: origin.originalType,
                engineAssetsAuthorized: engineAssets.isAuthorized
            )
            Button {
                showLogSheet = true
            } label: {
                PreviewControlLabel(
                    systemImage: reason.symbol,
                    title: "Skipped",
                    tint: reason.tint
                )
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: detail))
            .accessibilityLabel(Text(verbatim: reason.localizedTitle(originalType: origin.originalType)))
            .accessibilityValue(Text(verbatim: detail))
            .accessibilityHint(Text("Open renderer diagnostics"))
        }
    }

    /// Keeps the current poster as the backdrop and swaps in the next frame the renderer presents.
    private func recaptureLivePoster() {
        guard canRecapturePoster else { return }
        previewLifecycle.requestFreshPoster()
        let targetSession = session
        let generation = previewLifecycle.generation
        Task { @MainActor in
            await pollPreviewUntilSettled(session: targetSession, generation: generation)
        }
    }

    private func reloadScene() {
        Task { @MainActor in
            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                state = .loading
            }
            livePoster = nil
            let targetSession = session
            let generation = previewLifecycle.generation
            await targetSession?.reload()
            await pollPreviewUntilSettled(session: targetSession, generation: generation)
        }
    }

    /// Everything below is collected in Release too, so a shader or GPU error has
    /// no other surface in a shipped build.
    private var hasDiagnosticFindings: Bool {
        if case .error = state { return true }
        guard let diagnostics = session?.rendererDiagnostics else { return false }
        return diagnostics.loadDiagnostics != nil
            || !diagnostics.resolution.missedRefs.isEmpty
            || diagnostics.shaderErrors.count > 0
            || diagnostics.gpuErrors.count > 0
    }

    private var fullDiagnosticText: String {
        let currentErrorCode: String? = if case let .error(reason) = state {
            reason.code
        } else {
            nil
        }
        return WPERenderDiagnosticReport.make(
            descriptor: descriptor,
            diagnostics: session?.rendererDiagnostics,
            errorCode: currentErrorCode
        )
    }

    private var currentSeverityTint: Color {
        if case .error(let reason) = state {
            return reason.tint
        }
        return .accentColor
    }

    @ViewBuilder
    private var fallbackBackground: some View {
        Group {
            if let livePoster {
                ZStack {
                    Color.black
                    Image(nsImage: livePoster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                WPEPreviewView(
                    imageURL: origin.sourcePreviewURL,
                    securityScopedBookmarkData: origin.sourceFolderBookmark,
                    playbackMode: .staticPoster,
                    aspectRatio: nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: showsLoadingChrome ? 6 : 0)
        .overlay(Color.black.opacity(showsLoadingChrome ? 0.35 : 0.0))
    }

    private var fitModeGroup: some View {
        GlassSegmentedPicker(
            selection: $fitMode,
            values: VideoFitMode.sceneModes,
            shell: .flat
        ) { mode, isSelected in
            PreviewControlLabel(
                systemImage: mode.iconName,
                title: mode.titleKey,
                isActive: isSelected
            )
            .accessibilityLabel(Text(mode.titleKey))
        }
        .help(Text("How the scene fills the display"))
    }

    private var infoBar: some View {
        WallpaperPreviewHUD {
            fitModeGroup
        } playback: {
            playbackControls
        } actions: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                degradedChip
                workshopLinkButton
                if hasDiagnosticFindings {
                    Button {
                        showLogSheet = true
                    } label: {
                        PreviewControlLabel(systemImage: "terminal", title: "Diagnostics")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Open renderer diagnostics"))
                    .accessibilityLabel(Text("Open renderer diagnostics"))
                }
            }
        }
        .contextMenu {
            Button {
                showLogSheet = true
            } label: {
                Label("Renderer Diagnostics", systemImage: "terminal")
            }
        }
    }

    @ViewBuilder
    private var workshopLinkButton: some View {
        if isSteamWorkshopID {
            Button {
                WorkshopDeepLink.requestSearch(origin.title)
                NotificationCenter.default.post(name: .openWorkshopPane, object: nil)
            } label: {
                PreviewControlLabel(systemImage: "cube.transparent.fill", title: "Workshop")
            }
            .buttonStyle(.borderless)
            .help(Text("Find this item in the Workshop"))
            .accessibilityLabel(Text("Workshop ID \(origin.workshopID). Find in Workshop.", comment: "A11y label for the Workshop button on the scene preview bar. The placeholder is the numeric Workshop ID."))
        }
    }

    private var isSteamWorkshopID: Bool {
        !origin.workshopID.isEmpty && origin.workshopID.allSatisfy(\.isNumber)
    }

    /// True when every sampled pixel is black; a 32×32 downsample is enough to tell a transition frame from content.
    static func isBlankPoster(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 1 || pixels[index + 1] > 1 || pixels[index + 2] > 1 {
            return false
        }
        return true
    }

    // MARK: - State derivation

    var initialRenderStateForTesting: SceneRenderState {
        _state.wrappedValue
    }

    private func restartPreviewLifecycle(
        for targetSession: SceneWallpaperSession?
    ) -> UInt64 {
        previewSession?.clearPreviewPerformanceOverride()
        livePosterTask?.cancel()
        livePosterTask = nil
        previewSession = targetSession
        // `onDisappear` drops the poster; the same scene coming back (window closed and reopened) repaints the remembered frame like a kept one.
        if livePoster == nil, previewLifecycle.workshopID == descriptor.workshopID {
            livePoster = ScenePosterMemory.poster(for: descriptor.workshopID)
        }
        return previewLifecycle.restart(
            workshopID: descriptor.workshopID,
            sessionID: targetSession.map(ObjectIdentifier.init),
            livePoster: &livePoster,
            state: &state
        )
    }

    private func pollPreviewUntilSettled(
        session targetSession: SceneWallpaperSession?,
        generation: UInt64,
        posterCommit: ScenePropertyPosterCommit? = nil
    ) async {
        while let next = await refreshState(
            session: targetSession,
            generation: generation,
            posterCommit: posterCommit
        ), next.needsPreviewPolling {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }
    }

    @discardableResult
    private func refreshState(
        session targetSession: SceneWallpaperSession?,
        generation: UInt64,
        posterCommit: ScenePropertyPosterCommit? = nil
    ) async -> SceneRenderState? {
        // Refresh the session's present/diagnostics caches from the render actor
        // before deriving state, so the sync reads below see fresh data.
        await targetSession?.pollRendererState()
        guard previewLifecycle.accepts(
            generation,
            sessionID: targetSession.map(ObjectIdentifier.init),
            isCancelled: Task.isCancelled
        ) else {
            return nil
        }
        let next = Self.derivedState(session: targetSession)
        if case .ready = next {
            targetSession?.applyPreviewPerformanceProfile(
                reduceMotion ? .suspended : .quality
            )
        }
        if next != state {
            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                state = next
            }
        }
        captureLivePosterIfNeeded(
            for: next,
            session: targetSession,
            generation: generation,
            posterCommit: posterCommit
        )
        return next
    }

    private func captureLivePosterIfNeeded(
        for next: SceneRenderState,
        session targetSession: SceneWallpaperSession?,
        generation: UInt64,
        posterCommit: ScenePropertyPosterCommit?
    ) {
        guard !reduceMotion,
              case .ready = next,
              livePoster == nil || previewLifecycle.awaitsFreshPoster,
              livePosterTask == nil,
              let targetSession else { return }
        let sessionID = ObjectIdentifier(targetSession)
        livePosterTask = Task { @MainActor in
            if let posterCommit {
                let didCommit = await targetSession.waitForScenePropertyPosterCommit(
                    posterCommit
                )
                guard previewLifecycle.accepts(
                    generation,
                    sessionID: sessionID,
                    isCancelled: Task.isCancelled
                ) else {
                    return
                }
                guard didCommit else {
                    livePosterTask = nil
                    return
                }
            }
            var image = await targetSession.captureLivePosterFromNextFrame()
            // Two one-frame artifacts get a single re-capture: a resume reaches the renderer through the
            // config channel, so a capture that overtook it saw the suspended profile (nil); and the first
            // present after a session swap is an all-black source. A scene that is genuinely black keeps it.
            let blank = image.map(Self.isBlankPoster) ?? false
            if (image == nil && isPlaying) || blank, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(blank ? 100 : 400))
                image = await targetSession.captureLivePosterFromNextFrame() ?? image
            }
            guard previewLifecycle.accepts(
                generation,
                sessionID: sessionID,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            if let image {
                livePoster = image
                previewLifecycle.acceptFreshPoster()
                ScenePosterMemory.remember(image, for: descriptor.workshopID)
            }
            livePosterTask = nil
        }
    }

    /// The state a page constructed right now starts in; reads only the session's cached fields.
    static func derivedState(
        session targetSession: SceneWallpaperSession?
    ) -> SceneRenderState {
        guard let targetSession else { return .notRendering }
        if let error = targetSession.loadError {
            return .error(mapToFallbackReason(error))
        }
        guard let presented = targetSession.hasPresentedFrame else { return .idle }
        if !presented {
            return .loading(progress: targetSession.loadProgress)
        }
        return .ready
    }

    private static func mapToFallbackReason(_ error: SceneRenderingError) -> FallbackReason {
        switch error {
        case .cacheRootMissing:
            return .sceneResourceMissing
        case .parseFailed(let detail):
            return .sceneParseFailed(detail)
        case .resourceFailed(let diagnostic):
            return Self.fallbackReason(for: diagnostic)
        case .metalRendererUnsupported(let reason):
            return .sceneParseFailed(reason)
        }
    }

    static func fallbackReason(for diagnostic: SceneLoadDiagnostic) -> FallbackReason {
        switch diagnostic {
        case .texture(_, let error):
            switch error {
            case .unsupportedContainer(let magic):
                return .texContainerUnsupported(magic: magic)
            case .unsupportedFormat(let code):
                return .texUnsupportedFormat(code: code)
            case .metalUnavailable:
                return .texUnsupportedFormat(code: -1)
            case .unsupportedAnimation:
                return .texDecodeFailed(detail: "animation/sequence frames")
            default:
                return .texDecodeFailed(detail: error.errorDescription ?? "decode failed")
            }
        case .legacyUnsupportedTexture:
            return .texDecodeFailed(detail: "legacy .tex stub")
        case .fileMissing, .crossPackageReference:
            return .sceneResourceMissing
        case .materialUnresolved(_, let reason):
            return .texDecodeFailed(detail: reason)
        case .other(_, let message):
            return .texDecodeFailed(detail: message)
        }
    }

    private var stateKey: Int {
        switch state {
        case .idle:         return 0
        case .loading:      return 1
        case .ready:        return 2
        case .error:        return 3
        case .notRendering: return 4
        }
    }

    private var stateAccessibilityText: String {
        switch state {
        case .idle:
            return String(localized: "Idle", defaultValue: "Idle", bundle: .appLanguage, comment: "Scene renderer accessibility state.")
        case .notRendering:
            return String(localized: "Wallpaper rendering is off", defaultValue: "Wallpaper rendering is off", bundle: .appLanguage, comment: "Scene renderer accessibility state shown when the menu-bar master switch is off.")
        case .loading:
            return String(localized: "Loading scene assets", defaultValue: "Loading scene assets", bundle: .appLanguage, comment: "Scene renderer accessibility state.")
        case .ready:
            return String(localized: "Scene preview", defaultValue: "Scene preview", bundle: .appLanguage, comment: "Scene renderer accessibility state.")
        case .error:
            return String(localized: "Scene cannot be played", defaultValue: "Scene cannot be played", bundle: .appLanguage, comment: "Scene renderer accessibility state.")
        }
    }
}

// MARK: - Diagnostic log window

@MainActor
private struct DiagnosticLogSheet: View {
    let title: String
    let log: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    @State private var rendered: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminal
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 380, idealHeight: 540)
        // Registered exception: content-layer wash on a system-presented sheet,
        // which AdaptiveGlass has no API for.
        .background(.ultraThinMaterial)
        // Keyed on the log: without the id the sheet keeps the first colourised
        // text forever, so a log that grows while the sheet is open stops updating.
        .task(id: log) { rendered = Self.colourise(log) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Diagnostic Log")
                    .font(.headline)
                Text(verbatim: title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .animation(.snappy, value: didCopy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(didCopy ? DesignTokens.Colors.Status.active : tint)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Spacing.cardInset)
        .background(tint.opacity(0.08))
    }

    private var terminal: some View {
        ScrollView(.vertical) {
            Text(rendered ?? AttributedString(log))
                .font(DesignTokens.Typography.codeCaption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.cardInset)
        }
        .background(Color.black.opacity(0.8))
    }

    /// Single AttributedString so copy/selection spans the whole log.
    private static func colourise(_ log: String) -> AttributedString {
        let lines = log.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.foregroundColor = colour(for: line)
            result += piece
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private static func colour(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("[err") || lower.contains("error") || lower.contains("fail") {
            return DesignTokens.Colors.Log.error
        }
        if lower.contains("[warn") || lower.contains("warning") || lower.contains("legacy") {
            return DesignTokens.Colors.Log.warning
        }
        // Tight match so "permission"/"dismiss"/"transmission" don't read as misses.
        if lower.contains("[miss") || lower.contains("miss:") || lower.contains("missing") || lower.contains("missed") {
            return DesignTokens.Colors.Log.miss
        }
        if lower.contains("resolved") || lower.contains("success") || lower.contains("cleanly") {
            return DesignTokens.Colors.Log.success
        }
        return DesignTokens.Colors.Log.neutral
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

// MARK: - State machine

enum SceneRenderState: Equatable {
    case idle
    /// No live session (menu-bar master tears sessions down, doesn't suspend).
    case notRendering
    case loading(progress: String?)
    case ready
    case error(FallbackReason)

    static var loading: SceneRenderState { .loading(progress: nil) }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var needsPreviewPolling: Bool {
        self == .idle || isLoading
    }
}

// MARK: - Information overlay

struct SceneInformationOverlay: View {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor

    /// Only what differs between scenes AND changes what the user should expect.
    /// Without this guard the padding and glass backing still draw an empty capsule.
    private var hasContent: Bool {
        requiresWindowsPlugin
            || descriptor.capabilityTier == .unsupported
            || storageLabel != nil
            || !descriptor.dependencyWorkshopIDs.isEmpty
    }

    var body: some View {
        if hasContent {
            badges
        }
    }

    private var badges: some View {
        HStack(spacing: 10) {
            if requiresWindowsPlugin {
                Text("Win plugin").informationOverlayTag(background: DesignTokens.Colors.Status.danger.opacity(0.55))
            }
            if descriptor.capabilityTier == .unsupported {
                Text(verbatim: descriptor.capabilityTier.localizedLabel)
                    .informationOverlayTag(background: DesignTokens.Colors.Status.danger.opacity(0.55))
            }
            if let storageLabel {
                Text(storageLabel).informationOverlayTag()
            }
            if !descriptor.dependencyWorkshopIDs.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "shippingbox")
                    Text(verbatim: "\(descriptor.dependencyWorkshopIDs.count)")
                }
            }
        }
        .font(DesignTokens.Typography.code)
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 8)
        .adaptiveGlassOverMedia(.capsule)
        .accessibilityElement(children: .combine)
    }

    private var requiresWindowsPlugin: Bool {
        origin.requiresWindowsPlugin || descriptor.preflightFeatureFlags.contains(.windowsPlugin)
    }

    private var storageLabel: LocalizedStringKey? {
        switch descriptor.assetStorage {
        case .sourceDirectory: "Folder"
        case .cache, .packageSource: nil
        }
    }
}

#endif
