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
    var sceneClickCaptureEnabled: Bool
    var hasPreviewSource: Bool
    /// Live scene mirror for inspector property overrides, not the persisted copy.
    var sceneDescriptor: SceneDescriptor?
    /// When the daily schedule takes this display back; nil while the display follows it.
    var schedulePausedUntil: Date?

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
        selectedFrameRateLimit: .matchDisplay,
        sceneMouseInteractionEnabled: true,
        sceneClickCaptureEnabled: false,
        hasPreviewSource: false,
        sceneDescriptor: nil
    )

    /// The weather fields (`selectedParticleEffect`, `particleDensity`, the weather flags in `effectConfig`) mirror `weather`.
    static func from(
        config: ScreenConfiguration?,
        weather: WeatherOverlayConfiguration = .default,
        fallbackHasPreviewSource: Bool
    ) -> DraftState {
        var state = wallpaperDraft(config: config, fallbackHasPreviewSource: fallbackHasPreviewSource)
        state.selectedParticleEffect = weather.particleEffect
        state.particleDensity = weather.particleDensity
        state.effectConfig.weatherReactive = weather.weatherReactive
        state.effectConfig.weatherWind = weather.weatherWind
        state.effectConfig.weatherIntensity = weather.weatherIntensity
        state.effectConfig.particleDensity = weather.particleDensity
        return state
    }

    private static func wallpaperDraft(
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
            selectedParticleEffect: .none,
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
            particleDensity: 1.0,
            selectedFrameRateLimit: config.frameRateLimit,
            sceneMouseInteractionEnabled: config.sceneMouseInteractionEnabled,
            sceneClickCaptureEnabled: config.sceneClickCaptureEnabled,
            hasPreviewSource: config.wallpaperType == .video && config.hasConfiguredVideoSource,
            sceneDescriptor: config.activeWallpaper.sceneDescriptor,
            schedulePausedUntil: SchedulePolicy.pausedUntil(for: config, now: Date(), calendar: .current)
        )
    }
}
