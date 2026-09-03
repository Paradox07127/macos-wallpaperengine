import LiveWallpaperCore
import SwiftUI

struct PreviewArea: View {

    let screen: Screen
    @Binding var draft: DraftState
    let featureCatalog: FeatureCatalog
    let screenManager: ScreenManager
    let previewController: InspectorPreviewController
    let isLoading: Bool
    let isDraggingOver: Bool
    let reduceMotion: Bool
    let showsGuideEmptyState: Bool
    let onChooseVideo: () -> Void
    let onChooseHTML: () -> Void
    let onChooseScene: () -> Void
    let onSelectVideoFile: () -> Void
    let onStartPreview: () -> Void
    let onPlaybackSpeedChange: (Double) -> Void
    let onResetPlayback: () -> Void

    @State private var showingWebTransform = false
    /// Off by default: the preview is a picture you look at, and a stray drag
    /// across it should not move the wallpaper. Armed from the transform popover.
    @State private var webTransformArmed = false
    @State private var webRefreshToken = 0
    /// The preview is showing a capture of the running wallpaper, which already
    /// has the CSS transform applied — so the canvas must not draw it again.
    @State private var webPreviewIsLive = false
    let onFitModeChange: (VideoFitMode) -> Void

    var body: some View {
        ZStack {
            DesignTokens.Colors.pageBackground

            if showsGuideEmptyState {
                EmptyStateGuideView(
                    onChooseVideo: onChooseVideo,
                    onChooseHTML: onChooseHTML,
                    onChooseScene: onChooseScene
                )
            } else if draft.selectedWallpaperType == .video {
                videoContent
            } else if draft.selectedWallpaperType == .html {
                htmlContent
            } else if draft.selectedWallpaperType == .scene,
                      featureCatalog.isEnabled(.scene) {
                #if !LITE_BUILD
                SceneSection(
                    screen: screen,
                    fitMode: Binding(
                        get: { draft.selectedFitMode },
                        set: { mode in
                            guard draft.selectedFitMode != mode else { return }
                            draft.selectedFitMode = mode
                            // Not `onFitModeChange`: that is the video path
                            // (`updateFitMode` only reaches `videoPlayer`), so a
                            // running scene kept its old scale until reload.
                            screenManager.updateSceneFitMode(mode, for: screen)
                        }
                    ),
                    playbackControls: AnyView(playbackControls)
                )
                #else
                EmptyView()
                #endif
            }
        }
        // Allow the preview to compress within the width assigned beside the inspector.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .overlay {
            dragHintOverlay
                .animation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2)), value: isDraggingOver)
        }
        // The view is not rebuilt per screen (no `.id(screen.id)` in the parent),
        // so armed state from a previous screen would otherwise carry over and
        // let the first drag on the new screen move its wallpaper unasked.
        .onChange(of: screen.id) {
            webTransformArmed = false
            showingWebTransform = false
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if isLoading {
            DetailLoadingView()
        } else if draft.hasPreviewSource || previewController.hasPreviewContent {
            if featureCatalog.isEnabled(.inspectorPreview) {
                WallpaperPreviewStage {
                    if let name = screenManager.currentVideoDisplayName(for: screen), !name.isEmpty {
                        WallpaperPreviewTitle(text: name)
                    }
                } content: {
                    VideoPreviewSection(
                        previewController: previewController,
                        hasPreviewSource: draft.hasPreviewSource,
                        selectedFitMode: draft.selectedFitMode,
                        startPreview: onStartPreview
                    )
                    .shadow(
                        color: Color.black.opacity(DesignTokens.Card.shadowOpacity),
                        radius: DesignTokens.Card.shadowRadius,
                        x: 0,
                        y: DesignTokens.Card.shadowYOffset
                    )
                } controls: {
                    videoCommandBar
                }
            } else {
                // No preview to float over — the bar is the only content here.
                videoCommandBar
                    .padding(DesignTokens.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            IllustratedEmptyState(
                symbol: "film",
                title: "No Video Selected",
                message: "Video file (.mp4, .mov, …)",
                symbolColor: .accentColor,
                primary: .init("Select Video File", action: onSelectVideoFile),
                variant: .dropTarget
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private var htmlContent: some View {
        if featureCatalog.isEnabled(.inspectorPreview), draft.htmlSource != nil {
            WallpaperPreviewStage {
                webTitleRow
            } content: {
                WebTransformCanvas(
                    screen: screen,
                    config: $draft.htmlConfig,
                    isArmed: webTransformArmed,
                    baseIncludesTransform: webPreviewIsLive
                ) {
                    HTMLPreviewSection(
                        screen: screen,
                        source: draft.htmlSource,
                        config: draft.htmlConfig,
                        refreshToken: webRefreshToken,
                        isShowingLiveCapture: $webPreviewIsLive,
                        wpePreviewURL: wpeWebPreviewURL,
                        wpePreviewBookmark: draft.wpeOrigin?.sourceFolderBookmark
                    )
                }
            } controls: {
                WallpaperPreviewHUD {
                    webTransformControl
                } playback: {
                    playbackControls
                } actions: {
                    EmptyView()
                }
            }
        } else {
            // Nothing picked yet: the picker is the page, not an overlay.
            HTMLSourceSection(
                screen: screen,
                source: $draft.htmlSource,
                config: $draft.htmlConfig
            )
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    /// A Wallpaper Engine web project's shipped preview asset, when the selected HTML wallpaper came from one.
    private var wpeWebPreviewURL: URL? {
        #if !LITE_BUILD
        return draft.wpeOrigin?.sourcePreviewURL
        #else
        return nil
        #endif
    }

    /// One row, one layer: picker, badges, diagnostics and refresh together, so
    /// nothing above the picture overlaps anything inside it. The picker already
    /// names the source, so the badge strip does not repeat it.
    private var webTitleRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            HTMLSourceSection(
                screen: screen,
                source: $draft.htmlSource,
                config: $draft.htmlConfig,
                floating: true
            )

            HTMLInformationOverlay(source: draft.htmlSource, config: draft.htmlConfig)

            HTMLRenderingDiagnosticsOverlay(
                screen: screen,
                source: draft.htmlSource,
                config: draft.htmlConfig
            )

            Button {
                webRefreshToken &+= 1
            } label: {
                PreviewCornerGlyph("arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(Text("Refresh web snapshot"))
            .accessibilityLabel(Text("Refresh web preview"))
        }
    }

    /// Web's viewport control. Video and scene fill this zone with a fit-mode
    /// picker; a web wallpaper has no fit mode, but it does have scale, translate
    /// and rotation, which are the same question about the same thing.
    private var webTransformControl: some View {
        Button {
            showingWebTransform = true
        } label: {
            PreviewControlLabel(
                systemImage: "move.3d",
                title: "Transform",
                isActive: webTransformArmed || draft.htmlConfig.hasActiveTransform
            )
        }
        .buttonStyle(.borderless)
        .help(Text("Scale, move, and rotate the page inside the display"))
        .accessibilityLabel(Text("Transform"))
        .popover(isPresented: $showingWebTransform, arrowEdge: .bottom) {
            HTMLTransformControls(
                screen: screen,
                config: $draft.htmlConfig,
                isDragEnabled: $webTransformArmed
            )
        }
    }

    /// Every playback control for this display, as glyphs. Shared by all three
    /// wallpaper types' overlays so the same setting is always in the same place.
    private var playbackControls: some View {
        PlaybackControls(
            screen: screen,
            wallpaperType: draft.selectedWallpaperType,
            muted: $draft.videoMuted,
            videoVolume: $draft.videoVolume,
            frameRateLimit: $draft.selectedFrameRateLimit,
            syncToLockScreen: $draft.setAsLockScreen,
            sceneMouseInteractionEnabled: $draft.sceneMouseInteractionEnabled,
            sceneClickCaptureEnabled: $draft.sceneClickCaptureEnabled,
            htmlConfig: draft.selectedWallpaperType == .html ? $draft.htmlConfig : nil,
            playbackSpeed: draft.selectedWallpaperType == .video ? speedBinding : nil,
            videoColorSpace: draft.videoColorSpace,
            showsResetPlayback: screenManager.displayPlaybackDiffersFromDefaults(for: screen),
            onResetPlayback: onResetPlayback
        )
    }

    private var videoCommandBar: some View {
        AdaptiveGlassContainer(spacing: 14) {
            WallpaperPreviewHUD {
                fitModeGroup
            } playback: {
                playbackControls
            } actions: {
                EmptyView()
            }
        }
    }

    private var fitModeGroup: some View {
        GlassSegmentedPicker(
            selection: Binding(
                get: { draft.selectedFitMode },
                set: { mode in
                    guard draft.selectedFitMode != mode else { return }
                    draft.selectedFitMode = mode
                    onFitModeChange(mode)
                }
            ),
            values: VideoFitMode.videoModes,
            shell: .flat
        ) { mode, isSelected in
            PreviewControlLabel(
                systemImage: mode.iconName,
                title: mode.titleKey,
                isActive: isSelected
            )
            .help(Text(mode.tooltipKey))
            .accessibilityLabel(Text(mode.titleKey))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Video fit mode"))
    }


    private var speedBinding: Binding<Double> {
        Binding(
            get: { draft.playbackSpeed },
            set: { newValue in
                guard abs(draft.playbackSpeed - newValue) > 0.001 else { return }
                draft.playbackSpeed = newValue
                onPlaybackSpeedChange(newValue)
            }
        )
    }



    @ViewBuilder
    private var dragHintOverlay: some View {
        if isDraggingOver {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                VStack(spacing: 10) {
                    Group {
                        if reduceMotion {
                            Image(systemName: "arrow.down.doc.fill")
                        } else if #available(macOS 15.0, *) {
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.bounce, options: .repeat(.continuous))
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.pulse, options: .continuouslyRepeating)
                        }
                    }
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    Text("Drop to use as wallpaper")
                        .font(DesignTokens.Typography.sectionTitle)
                        .foregroundStyle(.primary)
                    Text(dragHintSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // `stroked: false`: the accent strokeBorder above already draws
            // this shape's edge, and it doubles as the drop affordance.
            .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.preview), stroked: false)
            .padding(20)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private var dragHintSubtitle: LocalizedStringKey {
        switch draft.selectedWallpaperType {
        case .video:        return "Video file (.mp4, .mov, …)"
        case .html:         return "Web file or folder"
        case .scene:        return "Switch to Video or Web to drop"
        }
    }
}

struct DetailLoadingView: View {
    var body: some View {
        // No visible label on the spinner (HIG); the copy survives as its
        // accessibility label.
        ProgressView()
            .scaleEffect(1.5)
            .accessibilityLabel(Text("Loading video..."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.preview))
    }
}
