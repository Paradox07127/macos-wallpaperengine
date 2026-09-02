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
    }

    @ViewBuilder
    private var videoContent: some View {
        if isLoading {
            DetailLoadingView()
        } else if draft.hasPreviewSource || previewController.hasPreviewContent {
            if featureCatalog.isEnabled(.inspectorPreview) {
                WallpaperPreviewStage {
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
                HTMLPreviewSection(
                    screen: screen,
                    source: draft.htmlSource,
                    config: draft.htmlConfig,
                    wpePreviewURL: wpeWebPreviewURL,
                    wpePreviewBookmark: draft.wpeOrigin?.sourceFolderBookmark
                )
            } controls: {
                HStack(spacing: DesignTokens.Spacing.md) {
                    HTMLSourceSection(
                        screen: screen,
                        source: $draft.htmlSource,
                        config: $draft.htmlConfig,
                        floating: true
                    )
                    playbackControls
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, 6)
                        .adaptiveGlassSurface(.capsule)
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

    /// One shape for all three wallpaper types' preview overlays: what this is on
    /// the left, controls that change what the preview shows on the right. The
    /// scene's bar carries its title, link and diagnostics; the web preview's
    /// carries its source picker; this one names the file.
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
            videoColorSpace: draft.videoColorSpace,
            showsResetPlayback: screenManager.displayPlaybackDiffersFromDefaults(for: screen),
            onResetPlayback: onResetPlayback
        )
    }

    private var videoCommandBar: some View {
        AdaptiveGlassContainer(spacing: 14) {
            HStack(spacing: 14) {
                if let name = screenManager.currentVideoDisplayName(for: screen), !name.isEmpty {
                    Text(verbatim: name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: name))
                }
                Spacer(minLength: 8)
                fitModeGroup
                Divider().frame(height: 30)
                speedSlider
                Divider().frame(height: 30)
                playbackControls
            }
            .padding(.horizontal, DesignTokens.Spacing.cardInset)
            .padding(.vertical, 6)
            .adaptiveGlassSurface(.capsule)
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
            VStack(spacing: 2) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 18)
                Text(mode.titleKey)
                    .font(isSelected ? DesignTokens.Typography.captionEmphasized : DesignTokens.Typography.caption)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .help(Text(mode.tooltipKey))
            .accessibilityLabel(Text(mode.titleKey))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Video fit mode"))
    }

    private var speedSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: speedBinding, in: 0.5...2.0, step: 0.25)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel(Text("Playback speed"))
                .accessibilityValue(Text(speedAccessibilityValue))
            Image(systemName: "hare.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(speedDisplayLabel)
                .font(DesignTokens.Typography.metric)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help(Text("Playback speed"))
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

    private var speedDisplayLabel: String {
        let speed = draft.playbackSpeed
        if abs(speed - speed.rounded()) < 0.001 {
            return "\(Int(speed))×"
        }
        return String(format: "%.2g×", speed)
    }

    private var speedAccessibilityValue: String {
        String(format: "%.2g×", draft.playbackSpeed)
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
