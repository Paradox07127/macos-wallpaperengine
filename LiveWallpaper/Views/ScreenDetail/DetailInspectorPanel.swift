import AppKit
import LiveWallpaperCore
import SwiftUI

struct DetailInspectorPanel: View {
    let screen: Screen
    @Binding var draft: DraftState
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog
    let reduceMotion: Bool
    let inspectorPanelWidth: CGFloat
    @Binding var isColorExpanded: Bool
    let onWallpaperModeChange: (WallpaperMode) -> Void
    let showsResetPlayback: Bool
    let onResetPlaybackSettings: () -> Void
    let showsResetDisplaySettings: Bool
    let onResetDisplaySettings: () -> Void
    #if !LITE_BUILD
    @State private var wpeProjectCustomSettingsSchema: WallpaperEngineProjectPropertySchema?
    @State private var wpeSceneCustomSettingsSchema: WallpaperEngineProjectPropertySchema?
    #endif

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 12) {
                VStack(spacing: 12) {
                    if draft.selectedWallpaperType == .video,
                       featureCatalog.capabilities.selectableWallpaperModes.count > 1 {
                        wallpaperModeCard
                    }

                    CommonPlaybackInspector(
                        screen: screen,
                        wallpaperType: draft.selectedWallpaperType,
                        muted: $draft.videoMuted,
                        videoVolume: $draft.videoVolume,
                        videoDisplayMode: $draft.selectedVideoDisplayMode,
                        frameRateLimit: $draft.selectedFrameRateLimit,
                        syncToLockScreen: $draft.setAsLockScreen,
                        sceneMouseInteractionEnabled: $draft.sceneMouseInteractionEnabled,
                        sceneClickCaptureEnabled: $draft.sceneClickCaptureEnabled,
                        sceneFitMode: $draft.selectedFitMode,
                        htmlConfig: draft.selectedWallpaperType == .html ? $draft.htmlConfig : nil,
                        videoColorSpace: draft.videoColorSpace,
                        showsResetPlayback: showsResetPlayback,
                        onResetPlayback: onResetPlaybackSettings
                    )

                    if draft.selectedWallpaperType == .html {
                        ContentSecurityInspector(
                            screen: screen,
                            source: draft.htmlSource,
                            htmlConfig: $draft.htmlConfig
                        )

                        HTMLOptionsInspector(
                            screen: screen,
                            config: $draft.htmlConfig
                        )

                        #if !LITE_BUILD
                        if let wpeProjectCustomSettingsSchema,
                           wpeProjectCustomSettingsSchema.hasMeaningfulSettings {
                            WPEProjectCustomSettingsCard(
                                screen: screen,
                                schema: wpeProjectCustomSettingsSchema,
                                projectKey: wpeProjectCustomSettingsProjectKey,
                                config: $draft.htmlConfig
                            )
                        }
                        #endif

                        HTMLTransformInspector(
                            screen: screen,
                            config: $draft.htmlConfig
                        )
                    }

                    if draft.selectedWallpaperType == .video,
                       featureCatalog.isEnabled(.videoEffects) {
                        colorGroup
                    }

                    #if !LITE_BUILD
                    if draft.selectedWallpaperType == .scene,
                       let schema = wpeSceneCustomSettingsSchema,
                       schema.properties.contains(where: WPESceneCustomSettingsCard.isSceneSettingCandidate),
                       draft.sceneDescriptor != nil {
                        WPESceneCustomSettingsCard(
                            screen: screen,
                            schema: schema,
                            descriptor: sceneDescriptorBinding
                        )
                    }
                    #endif

                    if showsResetDisplaySettings {
                        resetDisplayButton
                    }
                }
                .padding(.horizontal, DesignTokens.Inspector.horizontalPadding(for: inspectorPanelWidth))
                .padding(.vertical, 12)
            }
        }
        .frame(width: inspectorPanelWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(NSColor.windowBackgroundColor))
        .clipped()
        .accessibilityLabel(Text("Wallpaper Properties"))
        #if !LITE_BUILD
        .task(id: wpeProjectCustomSettingsLoadKey) {
            await loadWPEProjectCustomSettingsSchema()
        }
        .task(id: wpeSceneCustomSettingsLoadKey) {
            await loadWPESceneCustomSettingsSchema()
        }
        #endif
    }

    #if !LITE_BUILD
    private var sceneDescriptorBinding: Binding<SceneDescriptor> {
        Binding(
            get: {
                draft.sceneDescriptor ?? SceneDescriptor(
                    workshopID: "",
                    cacheRelativePath: "",
                    entryFile: "scene.json",
                    capabilityTier: .unsupported
                )
            },
            set: { newValue in
                draft.sceneDescriptor = newValue
            }
        )
    }

    private var wpeSceneCustomSettingsLoadKey: String {
        guard draft.selectedWallpaperType == .scene,
              let descriptor = draft.sceneDescriptor else {
            return "hidden"
        }
        let originFingerprint = draft.wpeOrigin?.sourceFolderBookmark.count.description ?? "-"
        return "\(screen.id):scene:\(descriptor.workshopID):\(originFingerprint)"
    }

    @MainActor
    private func loadWPESceneCustomSettingsSchema() async {
        guard draft.selectedWallpaperType == .scene,
              let descriptor = draft.sceneDescriptor else {
            wpeSceneCustomSettingsSchema = nil
            return
        }
        wpeSceneCustomSettingsSchema = nil
        let outcome = await WPESceneProjectSchemaLoader.load(
            descriptor: descriptor,
            wpeOrigin: draft.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        if outcome.schema != nil || outcome.isExpectedAbsence {
            Logger.info("WPESceneCustomSettings: \(outcome.log)", category: .screenManager)
        } else {
            Logger.warning("WPESceneCustomSettings: \(outcome.log)", category: .screenManager)
        }
        wpeSceneCustomSettingsSchema = outcome.schema
    }

    /// Drives schema reloads from the panel rather than the card: the panel is always mounted while HTML properties are visible, so the async read can't deadlock behind an initially empty card body.
    private var wpeProjectCustomSettingsLoadKey: String {
        guard let projectKey = wpeProjectCustomSettingsProjectKey else {
            return "hidden"
        }
        return "\(screen.id):\(projectKey)"
    }

    private var wpeProjectCustomSettingsProjectKey: String? {
        guard draft.selectedWallpaperType == .html,
              case .folder = draft.htmlSource else {
            return nil
        }
        if let originalType = draft.wpeOrigin?.originalType,
           originalType != .web {
            return nil
        }
        return WallpaperEngineProjectIdentity.key(source: draft.htmlSource, origin: draft.wpeOrigin)
    }

    @MainActor
    private func loadWPEProjectCustomSettingsSchema() async {
        guard draft.selectedWallpaperType == .html else {
            wpeProjectCustomSettingsSchema = nil
            return
        }

        let outcome = await WPEProjectCustomSettingsSchemaLoader.load(
            source: draft.htmlSource,
            wpeOrigin: draft.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        if outcome.schema != nil || outcome.isExpectedAbsence {
            Logger.info("WPECustomSettings: \(outcome.log)", category: .screenManager)
        } else {
            Logger.warning("WPECustomSettings: \(outcome.log)", category: .screenManager)
        }
        wpeProjectCustomSettingsSchema = outcome.schema
    }
    #endif

    private var colorGroup: some View {
        GroupBox {
            CollapsibleSection(
                title: "Color & Filters",
                systemImage: "slider.horizontal.3",
                isExpanded: $isColorExpanded
            ) {
                ColorAdjustmentsView(
                    effectConfig: $draft.effectConfig,
                    videoColorSpace: $draft.videoColorSpace,
                    screen: screen,
                    screenManager: screenManager
                )
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var resetDisplayButton: some View {
        HStack {
            Spacer()
            Button(action: onResetDisplaySettings) {
                Label("Reset Current Display", systemImage: "arrow.counterclockwise.circle")
            }
            .adaptiveGlassButton(.regular, size: .small)
            .tint(DesignTokens.Colors.Status.danger)
            .help(Text("Reset all playback, color, particle, audio, and layout settings on this display — wallpaper, playlist, and bookmarks stay"))
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var wallpaperModeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                wallpaperModePill

                Group {
                    switch draft.selectedWallpaperMode {
                    case .playlist:
                        if featureCatalog.isEnabled(.playlists) {
                            Divider()
                            PlaylistSection(
                                playlistBookmarks: $draft.playlistBookmarks,
                                shufflePlaylist: $draft.shufflePlaylist,
                                rotationMinutes: $draft.playlistRotationMinutes,
                                screen: screen,
                                screenManager: screenManager
                            )
                        }
                    case .schedule:
                        if featureCatalog.isEnabled(.scheduleAutomation) {
                            Divider()
                            ScheduleSection(
                                scheduleSlots: $draft.scheduleSlots,
                                screen: screen,
                                screenManager: screenManager
                            )
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var wallpaperModePill: some View {
        GlassSegmentedPicker(
            selection: Binding(
                get: { draft.selectedWallpaperMode },
                set: { mode in
                    draft.selectedWallpaperMode = mode
                    onWallpaperModeChange(mode)
                }
            ),
            values: featureCatalog.capabilities.selectableWallpaperModes
        ) { mode, isSelected in
            Text(mode.labelKey)
                .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
                .accessibilityLabel(wallpaperModeAccessibilityLabel(mode))
        }
    }

    private func wallpaperModeAccessibilityLabel(_ mode: WallpaperMode) -> Text {
        switch mode {
        case .playlist:
            return Text("Playlist mode", comment: "A11y label for the playlist wallpaper mode tab.")
        case .schedule:
            return Text("Schedule mode", comment: "A11y label for the schedule wallpaper mode tab.")
        }
    }
}
