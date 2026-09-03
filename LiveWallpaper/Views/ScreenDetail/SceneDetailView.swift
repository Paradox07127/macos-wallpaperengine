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

/// Scene detail card for Wallpaper Engine projects.
@MainActor
struct SceneDetailView: View {
    private let stackSpacing: CGFloat = 16

    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?
    /// Whether the display reports a *scene rendering* failure above this card.
    /// Session-derived state misses failures that never produced a scene session
    /// (`ScreenManager.transientRuntimeErrors`). Narrower than "any runtime error" on purpose: a revoked bookmark or unplayable file isn't something an engine-assets install fixes.
    let hasSceneRenderingError: Bool
    /// Scale: a preview-view control, the same role video's overlay has always had.
    @Binding var fitMode: VideoFitMode
    let playbackControls: AnyView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed for `isAuthorized` only — the cheap published flag, not a
    /// bookmark resolve on every layout pass.
    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var state: SceneRenderState = .idle
    /// Live renderer frame reused as hero poster once presenting.
    @State private var livePoster: NSImage?
    @State private var livePosterTask: Task<Void, Never>?
    /// Full renderer log opens in a sheet (keeps layout stable on error).
    @State private var showLogSheet = false
    /// Generation-scoped preview lifecycle; invalidate on disappear so late polls can't re-suspend.
    @State private var previewLifecycle = ScenePreviewLifecycleState()
    /// Session owned by preview lifecycle — clear outgoing override on task-ID change before swap.
    @State private var previewSession: SceneWallpaperSession?

    private var previewTaskIdentity: ScenePreviewTaskIdentity {
        // Must be the same layering `stageScenePropertyPosterCommit` stages with
        // (`ScreenManager+SceneMutation`): keyed on the increment alone, a
        // preset-carrying descriptor never matches its own staged commit.
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
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: stateKey)
    }

    @ViewBuilder
    private var stateBackground: some View {
        switch state {
        case .idle:
            fallbackBackground
            LiquidGlassSpinner()
        case .notRendering:
            fallbackBackground
        case .loading(let progress):
            fallbackBackground
            LiquidGlassSpinner(progressText: progress)
        case .ready:
            fallbackBackground
        case .error(let fallbackReason):
            fallbackBackground
                .overlay(alignment: .bottom) { previewErrorStrip(reason: fallbackReason) }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                        .strokeBorder(severityColor(for: fallbackReason).opacity(0.45), lineWidth: 1.5)
                }
        }
    }

    /// Glanceable error code over artwork; summary in `errorBanner`, full log in sheet.
    private func previewErrorStrip(reason: FallbackReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: severityIcon(for: reason))
                .font(.caption.weight(.semibold))
                .foregroundStyle(severityColor(for: reason))
            Text(verbatim: errorCode(for: reason))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func errorTitle(for reason: FallbackReason) -> Text {
        switch reason {
        case .unsupportedType:        return Text("Scene format not supported")
        case .sceneParseFailed:       return Text("Couldn't read scene.json")
        case .sceneShaderUnsupported: return Text("Scene uses unsupported shaders")
        case .sceneResourceMissing:   return Text("Some scene assets are missing")
        case .missingDependency(let ids):
            if ids.count == 1 {
                return Text("Missing 1 Workshop dependency")
            }
            return Text("Missing \(ids.count) Workshop dependencies", comment: "Scene error title. The placeholder is the number of missing Workshop dependencies.")
        case .requiresWindowsPlugin:  return Text("Windows plugin required")
        case .texContainerUnsupported: return Text("Unknown texture container")
        case .texUnsupportedFormat:    return Text("Texture format not supported")
        case .texDecodeFailed:         return Text("Texture decode failed")
        }
    }

    private func errorBody(for reason: FallbackReason) -> Text {
        switch reason {
        case .unsupportedType:
            return Text("We can't render this scene's feature set yet.")
        case .sceneParseFailed(let detail):
            return Text(verbatim: LogPrivacyRedactor.scrub(detail))
        case .sceneShaderUnsupported:
            return Text("A custom shader couldn't be translated. Try re-downloading the project.")
        case .sceneResourceMissing:
            // Names where the files were looked for, not what to do about it —
            // `EngineAssetsBanner` at the top of the Scene page owns the recovery.
            if engineAssets.isAuthorized {
                return Text("Image layers couldn't be found in this project or in your Wallpaper Engine assets.")
            }
            return Text("Image layers couldn't be found in this project. Wallpaper Engine's shared assets normally supply them.")
        case .missingDependency(let ids):
            if ids.count <= 2 {
                return Text("Subscribe to \(ids.joined(separator: ", ")) in Steam, then re-import.", comment: "Scene dependency recovery hint. The placeholder is one or two Workshop IDs.")
            }
            let head = ids.prefix(2).joined(separator: ", ")
            return Text("Subscribe to \(head) and \(ids.count - 2) more in Steam, then re-import.", comment: "Scene dependency recovery hint. Placeholders are Workshop IDs and the remaining count.")
        case .requiresWindowsPlugin:
            return Text("macOS can't load Windows native plugins.")
        case .texContainerUnsupported(let magic):
            return Text("Container \(magic) is unsupported.", comment: "Texture error detail. The placeholder is a texture container magic value.")
        case .texUnsupportedFormat(let code):
            return Text("Format \(code) — not yet decoded.", comment: "Texture error detail. The placeholder is a texture format code.")
        case .texDecodeFailed(let detail):
            return Text(verbatim: LogPrivacyRedactor.scrub(detail))
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let reason) = state {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: severityIcon(for: reason))
                    .font(.title3)
                    .foregroundStyle(severityColor(for: reason))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    errorTitle(for: reason)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    errorBody(for: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if reason.isActionable {
                    Button {
                        Task { @MainActor in
                            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                                state = .loading
                            }
                            livePoster = nil
                            let targetSession = session
                            let generation = previewLifecycle.generation
                            await targetSession?.reload()
                            await pollPreviewUntilSettled(
                                session: targetSession,
                                generation: generation
                            )
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint(Text("Re-decodes the scene with the current cache state"))
                }
                Button {
                    showLogSheet = true
                } label: {
                    Label("Log", systemImage: "terminal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Open the full diagnostic log"))
                .accessibilityLabel(Text("Open the full diagnostic log"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: severityColor(for: reason))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .strokeBorder(severityColor(for: reason).opacity(0.30), lineWidth: 1)
            }
            .transition(.opacity)
        }
    }

    /// Whether the log would say anything. Everything below is collected in
    /// Release too — only `WPESceneDebugArtifacts` (the on-disk dump) is
    /// Debug-only — so a shader compile failure or a post-return GPU error has
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
        let currentErrorCode: String?
        if case .error(let reason) = state {
            currentErrorCode = errorCode(for: reason)
        } else {
            currentErrorCode = nil
        }
        return WPERenderDiagnosticReport.make(
            descriptor: descriptor,
            diagnostics: session?.rendererDiagnostics,
            errorCode: currentErrorCode
        )
    }

    // MARK: - Severity derivation

    private func severityColor(for reason: FallbackReason) -> Color {
        switch reason {
        case .missingDependency, .requiresWindowsPlugin: return DesignTokens.Colors.Status.warning
        default:                                         return DesignTokens.Colors.Status.danger
        }
    }

    private func severityIcon(for reason: FallbackReason) -> String {
        switch reason {
        case .missingDependency:     return "exclamationmark.triangle.fill"
        case .requiresWindowsPlugin: return "puzzlepiece.extension.fill"
        default:                     return "exclamationmark.octagon.fill"
        }
    }

    private func errorCode(for reason: FallbackReason) -> String {
        switch reason {
        case .unsupportedType:         return "WPE_UNSUPPORTED_TYPE"
        case .sceneParseFailed:        return "WPE_SCENE_PARSE"
        case .sceneShaderUnsupported:  return "WPE_SHADER_UNSUPPORTED"
        case .sceneResourceMissing:    return "WPE_RESOURCE_MISS"
        case .missingDependency:       return "WPE_MISSING_DEPENDENCY"
        case .requiresWindowsPlugin:   return "WPE_WINDOWS_PLUGIN"
        case .texContainerUnsupported: return "WPE_TEX_CONTAINER"
        case .texUnsupportedFormat:    return "WPE_TEX_FORMAT"
        case .texDecodeFailed:         return "WPE_TEX_DECODE"
        }
    }

    private var currentSeverityTint: Color {
        if case .error(let reason) = state {
            return severityColor(for: reason)
        }
        return .accentColor
    }

    /// Live renderer frame as hero (no extra render).
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
        .blur(radius: state.isLoading ? 6 : 0)
        .overlay(Color.black.opacity(state.isLoading ? 0.35 : 0.0))
    }

    /// Floating glass info bar under the preview — the scene-type analog of the video command bar.
    /// Same control as the video overlay's, so "how does this fill the screen"
    /// is answered in the same place whatever the wallpaper is.
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
                workshopLinkButton
                // Only when the log has something in it. A scene that loaded
                // cleanly has nothing to show here, and the context menu keeps
                // the report reachable for a bug report either way.
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

    /// Jumps to the Workshop tab. One action, so a button rather than a menu with
    /// a single item in it. No capability-disabled fallback: this file compiles
    /// only into the Pro binary, whose sole capability set (`ProductCapabilities.pro`)
    /// carries `.scene` and `.wpeImport` together, so such a branch could not run.
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

    // MARK: - State derivation

    private func restartPreviewLifecycle(
        for targetSession: SceneWallpaperSession?
    ) -> UInt64 {
        previewSession?.clearPreviewPerformanceOverride()
        previewLifecycle.invalidate()
        livePosterTask?.cancel()
        livePosterTask = nil
        livePoster = nil
        state = .idle
        previewSession = targetSession
        return previewLifecycle.begin(
            sessionID: targetSession.map(ObjectIdentifier.init)
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
        // (M2c1b-3c) before deriving state, so the sync reads below see fresh data.
        await targetSession?.pollRendererState()
        guard previewLifecycle.accepts(
            generation,
            sessionID: targetSession.map(ObjectIdentifier.init),
            isCancelled: Task.isCancelled
        ) else {
            return nil
        }
        let next = derivedState(session: targetSession)
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

    /// Next presented frame as poster (no forced sync render).
    private func captureLivePosterIfNeeded(
        for next: SceneRenderState,
        session targetSession: SceneWallpaperSession?,
        generation: UInt64,
        posterCommit: ScenePropertyPosterCommit?
    ) {
        guard !reduceMotion,
              case .ready = next,
              livePoster == nil,
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
            let image = await targetSession.captureLivePosterFromNextFrame()
            guard previewLifecycle.accepts(
                generation,
                sessionID: sessionID,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            livePoster = image
            livePosterTask = nil
        }
    }

    private func derivedState(
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

    private func mapToFallbackReason(_ error: SceneRenderingError) -> FallbackReason {
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
    /// Cached colourised log; rebuild only when content changes (long logs).
    @State private var rendered: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminal
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 380, idealHeight: 540)
        // Registered exception (w1-contracts §4, W2-B7): content-layer wash on a
        // system-presented sheet — the HIG "standard material on the content
        // layer" case, which AdaptiveGlass has no API for. The system material
        // already goes opaque under Reduce Transparency.
        .background(.ultraThinMaterial)
        .task { if rendered == nil { rendered = Self.colourise(log) } }
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

/// Scene-type analog of `VideoInformationOverlay` / `HTMLInformationOverlay`.
struct SceneInformationOverlay: View {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor

    /// Only what differs between scenes AND changes what the user should expect.
    ///
    /// Not the `preflightFeatureFlags` set (Shader, Particle, Text, Audio, Anim,
    /// FX): those are genuinely computed per scene, but almost every non-trivial
    /// Wallpaper Engine scene uses all of them, so spelling them out reads the
    /// same on every wallpaper. The consequence of the flags is already
    /// summarized by `capabilityTier`, and the flags themselves are listed in the
    /// diagnostics report (`WPERenderDiagnosticReport`), which is where someone
    /// debugging goes.
    ///
    /// What is left says "something here is limited or unusual", so an empty row
    /// means "nothing to look at" and renders nothing. Without this guard the
    /// padding and the glass backing still drew, leaving a capsule with nothing
    /// in it on every scene that is simply fine.
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
            // Only the "nothing renders" verdict earns a badge.
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
        // Same treatment as the title capsule beside it: white badges over a
        // wallpaper need a scrim under the material, not a tint on it.
        .adaptiveGlassOverMedia(.capsule)
        .accessibilityElement(children: .combine)
    }

    /// "Packaged" is what a Workshop item always is, so it said nothing. A linked
    /// source folder is the unusual case, and it is the one that means edits on
    /// disk reach the wallpaper.
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
