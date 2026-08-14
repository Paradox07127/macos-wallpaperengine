import LiveWallpaperCore
import SwiftUI

struct PreviewArea: View {
    private let previewAspectRatio: CGFloat = 16 / 9
    private let videoPreviewReservedHeight: CGFloat = 56
    private let htmlSourceReservedHeight: CGFloat = 88

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
                SceneSection(screen: screen)
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
            GeometryReader { geo in
                let previewHeight = cappedPreviewHeight(
                    in: geo.size.height,
                    verticalPadding: 18,
                    reservedHeight: videoPreviewReservedHeight
                )
                VStack(spacing: 16) {
                    if featureCatalog.isEnabled(.inspectorPreview) {
                        VideoPreviewSection(
                            previewController: previewController,
                            hasPreviewSource: draft.hasPreviewSource,
                            selectedFitMode: draft.selectedFitMode,
                            startPreview: onStartPreview
                        )
                        .aspectRatio(previewAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: previewHeight)
                        .shadow(
                            color: Color.black.opacity(DesignTokens.Card.shadowOpacity),
                            radius: DesignTokens.Card.shadowRadius,
                            x: 0,
                            y: DesignTokens.Card.shadowYOffset
                        )
                    }

                    videoCommandBar
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var htmlContent: some View {
        GeometryReader { geo in
            let previewHeight = cappedPreviewHeight(
                in: geo.size.height,
                verticalPadding: 24,
                reservedHeight: htmlSourceReservedHeight,
                interItemSpacing: 8
            )
            VStack(spacing: 8) {
                if featureCatalog.isEnabled(.inspectorPreview), draft.htmlSource != nil {
                    HTMLPreviewSection(
                        screen: screen,
                        source: draft.htmlSource,
                        config: draft.htmlConfig,
                        wpePreviewURL: wpeWebPreviewURL,
                        wpePreviewBookmark: draft.wpeOrigin?.sourceFolderBookmark
                    )
                    .frame(maxWidth: .infinity, maxHeight: previewHeight)
                    .layoutPriority(1)
                }
                HTMLSourceSection(
                    screen: screen,
                    source: $draft.htmlSource,
                    config: $draft.htmlConfig
                )
            }
            .padding(24)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private func cappedPreviewHeight(
        in containerHeight: CGFloat,
        verticalPadding: CGFloat,
        reservedHeight: CGFloat,
        interItemSpacing: CGFloat = 16
    ) -> CGFloat {
        let available = containerHeight - (verticalPadding * 2) - reservedHeight - interItemSpacing
        return max(0, available)
    }

    /// A Wallpaper Engine web project's shipped preview asset, when the selected HTML wallpaper came from one.
    private var wpeWebPreviewURL: URL? {
        #if !LITE_BUILD
        return draft.wpeOrigin?.sourcePreviewURL
        #else
        return nil
        #endif
    }

    private var videoCommandBar: some View {
        AdaptiveGlassContainer(spacing: 14) {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                fitModeGroup
                Divider().frame(height: 30)
                speedSlider
                Spacer(minLength: 0)
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
                    .fill(.ultraThinMaterial)
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

// Merged from ScreenDetailPlaceholderViews.swift: single consumer, no independent test surface.
struct DetailLoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            Text("Loading video...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.preview))
    }
}
