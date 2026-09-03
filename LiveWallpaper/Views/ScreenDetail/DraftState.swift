import Foundation
import LiveWallpaperCore

struct DraftState: Sendable, Equatable {
    var playbackSpeed: Double
    var selectedFitMode: VideoFitMode
    var selectedVideoDisplayMode: VideoDisplayMode
    var selectedWallpaperType: WallpaperType
    var selectedWallpaperMode: WallpaperMode
    var selectedParticleEffect: ParticleEffect
    var effectConfig: VideoEffectConfig
    var htmlSource: HTMLSource?
    var htmlConfig: HTMLConfig
    var wpeOrigin: WPEOrigin?
    var setAsLockScreen: Bool
    var playlistBookmarks: [Data]
    var shufflePlaylist: Bool
    var playlistRotationMinutes: Int?
    var scheduleSlots: [ScheduleSlot]
    var videoMuted: Bool
    var videoVolume: Double
    var videoColorSpace: VideoColorSpace
    var particleDensity: Double
    var selectedFrameRateLimit: FrameRateLimit
    /// Scene Follow Cursor (parallax / pointer).
    var sceneMouseInteractionEnabled: Bool
    /// Scene Interaction (click capture).
    var sceneClickCaptureEnabled: Bool
    var hasPreviewSource: Bool
    /// Live scene mirror for inspector property overrides (avoids persist round-trips per keystroke).
    var sceneDescriptor: SceneDescriptor?

    static let `default` = DraftState(
        playbackSpeed: 1.0,
        selectedFitMode: .aspectFill,
        selectedVideoDisplayMode: .perDisplay,
        selectedWallpaperType: .video,
        selectedWallpaperMode: .playlist,
        selectedParticleEffect: .none,
        effectConfig: .default,
        htmlSource: nil,
        htmlConfig: .default,
        wpeOrigin: nil,
        setAsLockScreen: false,
        playlistBookmarks: [],
        shufflePlaylist: false,
        playlistRotationMinutes: nil,
        scheduleSlots: [],
        videoMuted: true,
        videoVolume: 1.0,
        videoColorSpace: .auto,
        particleDensity: 1.0,
        selectedFrameRateLimit: .full,
        sceneMouseInteractionEnabled: true,
        sceneClickCaptureEnabled: false,
        hasPreviewSource: false,
        sceneDescriptor: nil
    )

    static func from(
        config: ScreenConfiguration?,
        fallbackHasPreviewSource: Bool
    ) -> DraftState {
        guard let config else {
            var state = Self.default
            state.hasPreviewSource = fallbackHasPreviewSource
            return state
        }

        return DraftState(
            playbackSpeed: config.playbackSpeed,
            selectedFitMode: config.fitMode,
            selectedVideoDisplayMode: config.videoDisplayMode,
            selectedWallpaperType: config.wallpaperType,
            selectedWallpaperMode: config.wallpaperMode,
            selectedParticleEffect: config.particleEffect,
            effectConfig: config.effectConfig,
            htmlSource: config.htmlSource,
            htmlConfig: config.htmlConfig ?? .default,
            wpeOrigin: config.wpeOrigin,
            setAsLockScreen: config.setAsLockScreen,
            playlistBookmarks: config.playlistBookmarks ?? [],
            shufflePlaylist: config.shufflePlaylist,
            playlistRotationMinutes: config.playlistRotationMinutes,
            scheduleSlots: config.scheduleSlots ?? [],
            videoMuted: config.muted,
            videoVolume: config.videoVolume,
            videoColorSpace: config.videoColorSpace,
            particleDensity: config.effectConfig.particleDensity,
            selectedFrameRateLimit: config.frameRateLimit,
            sceneMouseInteractionEnabled: config.sceneMouseInteractionEnabled,
            sceneClickCaptureEnabled: config.sceneClickCaptureEnabled,
            hasPreviewSource: config.wallpaperType == .video && config.hasConfiguredVideoSource,
            sceneDescriptor: config.activeWallpaper.sceneDescriptor
        )
    }
}
