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
    let showsResetDisplaySettings: Bool
    let onResetDisplaySettings: () -> Void
    #if !LITE_BUILD
    @State private var wpeProjectCustomSettingsSchema: WallpaperEngineProjectPropertySchema?
    @State private var wpeSceneCustomSettingsSchema: WallpaperEngineProjectPropertySchema?
    /// A nil schema means "loading" until the read finishes, and "this scene has
    /// none" after — the notice must only speak for the second.
    @State private var wpeSceneCustomSettingsResolved = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if draft.selectedWallpaperType == .video,
                   featureCatalog.capabilities.selectableWallpaperModes.count > 1 {
                    wallpaperModeCard
                }

                // Span-all-displays left the playback glyph row: its effect is on
                // a display other than the one the preview shows, so the preview
                // can never confirm it. A labelled row in this column can.
                if draft.selectedWallpaperType == .video {
                    displayGroup
                }

                // Nothing is loaded yet, so there is nothing for security, options
                // or transforms to be *about*: the picker in the preview is the
                // only step, and a column of settings beside it reads as a page
                // the user has already finished.
                if draft.selectedWallpaperType == .html, draft.htmlSource != nil {
                    SecurityInspector(
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

                }

                if draft.selectedWallpaperType == .video,
                   featureCatalog.isEnabled(.videoEffects) {
                    colorGroup
                }

                #if !LITE_BUILD
                if draft.selectedWallpaperType == .scene, draft.sceneDescriptor != nil {
                    if let schema = wpeSceneCustomSettingsSchema,
                       schema.properties.contains(where: WPESceneCustomSettingsCard.isSceneSettingCandidate) {
                        WPESceneCustomSettingsCard(
                            screen: screen,
                            schema: schema,
                            descriptor: sceneDescriptorBinding
                        )
                    } else if wpeSceneCustomSettingsResolved {
                        // Most scenes publish no properties at all, and the panel
                        // opens anyway (a scene is configured), so without this the
                        // column is a blank rectangle with no way to tell "nothing
                        // to adjust" from "still loading".
                        sceneWithoutOptionsNotice
                    }
                }
                #endif

                if showsResetDisplaySettings {
                    resetDisplayButton
                }
            }
            .padding(.horizontal, DesignTokens.Inspector.horizontalPadding(for: inspectorPanelWidth))
            .padding(.vertical, 12)
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
            set: { draft.sceneDescriptor = $0 }
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

    private var sceneWithoutOptionsNotice: some View {
        IllustratedEmptyState(
            symbol: "slider.horizontal.3",
            title: "No scene options",
            message: "This scene's author published no adjustable properties. Playback, sound and interaction stay on the preview controls.",
            variant: .compact
        )
    }

    @MainActor
    private func loadWPESceneCustomSettingsSchema() async {
        guard draft.selectedWallpaperType == .scene,
              let descriptor = draft.sceneDescriptor else {
            wpeSceneCustomSettingsSchema = nil
            wpeSceneCustomSettingsResolved = false
            return
        }
        wpeSceneCustomSettingsSchema = nil
        wpeSceneCustomSettingsResolved = false
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
        // A read that failed (unreadable project, denied bookmark) is not an
        // answer about the scene, so the notice must stay away.
        wpeSceneCustomSettingsResolved = outcome.schema != nil || outcome.isExpectedAbsence
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

    private var displayGroup: some View {
        GroupBox {
            SettingRow(
                icon: "rectangle.on.rectangle",
                title: "Span All Displays",
                info: "Stretches one video across every display as a single picture, instead of playing a copy on each."
            ) {
                // Disabled, never hidden: unplugging the second display must not
                // hide a persisted `.spanAllDisplays` — it would keep spanning
                // when that display came back, with no way to see or clear it.
                Toggle("", isOn: spanDisplaysBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(screenManager.screens.count <= 1)
                    .accessibilityLabel(Text("Span All Displays"))
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var spanDisplaysBinding: Binding<Bool> {
        Binding(
            get: { draft.selectedVideoDisplayMode == .spanAllDisplays },
            set: { newValue in
                let target: VideoDisplayMode = newValue ? .spanAllDisplays : .perDisplay
                guard draft.selectedVideoDisplayMode != target else { return }
                draft.selectedVideoDisplayMode = target
                screenManager.updateVideoDisplayMode(target, for: screen)
            }
        )
    }

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
            .buttonStyle(.bordered)
            .controlSize(.small)
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
            values: featureCatalog.capabilities.selectableWallpaperModes,
            shell: .flat
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
