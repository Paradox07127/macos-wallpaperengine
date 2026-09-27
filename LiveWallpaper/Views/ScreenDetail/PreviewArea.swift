import LiveWallpaperCore
import SwiftUI

struct WallpaperFitModePicker: View {
    @Binding var selection: VideoFitMode
    /// Scenes offer one mode video does not, so the list cannot be baked into the control.
    var modes: [VideoFitMode] = VideoFitMode.videoModes
    let onChange: (VideoFitMode) -> Void

    var body: some View {
        GlassSegmentedPicker(
            selection: Binding(
                get: { selection },
                set: { mode in
                    guard selection != mode else { return }
                    selection = mode
                    onChange(mode)
                }
            ),
            values: modes,
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
}

struct WebTransformControl: View {
    let screen: Screen
    @Binding var config: HTMLConfig
    @Binding var isArmed: Bool
    @State private var showsControls = false

    var body: some View {
        Button {
            showsControls = true
        } label: {
            PreviewControlLabel(
                systemImage: "move.3d",
                title: "Transform",
                isActive: isArmed || config.hasActiveTransform
            )
        }
        .buttonStyle(.borderless)
        .help(Text("Scale, move, and rotate the page inside the display"))
        .accessibilityLabel(Text("Transform"))
        .appLanguagePopover(isPresented: $showsControls, arrowEdge: .bottom) {
            HTMLTransformControls(screen: screen, config: $config, isDragEnabled: $isArmed)
        }
    }
}

struct WallpaperPlaybackControls: View {
    let screen: Screen
    @Binding var draft: DraftState
    let screenManager: ScreenManager
    let onPlaybackSpeedChange: (Double) -> Void
    let onResetPlayback: () -> Void

    var body: some View {
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
}
