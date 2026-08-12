import Foundation

/// Optional playback/effect snapshot on a bookmark. Nil fields = leave target
/// unchanged (legacy). Playlist/schedule/mode stay screen-level, not here.
public struct BookmarkPlaybackSettings: Codable, Equatable, Sendable {
    public var playbackSpeed: Double?
    public var fitMode: VideoFitMode?
    public var frameRateLimit: FrameRateLimit?
    public var particleEffect: ParticleEffect?
    public var effectConfig: VideoEffectConfig?
    public var muted: Bool?
    public var videoVolume: Double?
    public var setAsLockScreen: Bool?
    /// Whether the Monitor overlay was showing, and on which layer. The board's
    /// own layout is deliberately NOT captured: it is arranged against one
    /// display's geometry and shared by every wallpaper on it, so restoring a
    /// bookmark's copy would silently overwrite arrangement work the user did
    /// later. Bookmarks restore whether the overlay shows, not how it is built.
    public var monitorOverlayEnabled: Bool?
    public var monitorOverlayLevel: MonitorOverlayLevel?

    public init(
        playbackSpeed: Double? = nil,
        fitMode: VideoFitMode? = nil,
        frameRateLimit: FrameRateLimit? = nil,
        particleEffect: ParticleEffect? = nil,
        effectConfig: VideoEffectConfig? = nil,
        muted: Bool? = nil,
        videoVolume: Double? = nil,
        setAsLockScreen: Bool? = nil,
        monitorOverlayEnabled: Bool? = nil,
        monitorOverlayLevel: MonitorOverlayLevel? = nil
    ) {
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.frameRateLimit = frameRateLimit
        self.particleEffect = particleEffect
        self.effectConfig = effectConfig
        self.muted = muted
        self.videoVolume = videoVolume
        self.setAsLockScreen = setAsLockScreen
        self.monitorOverlayEnabled = monitorOverlayEnabled
        self.monitorOverlayLevel = monitorOverlayLevel
    }

    /// `monitorOverlay` is passed in rather than read from `config` because the
    /// overlay lives outside `ScreenConfiguration`, keyed by display fingerprint.
    public static func snapshot(
        of config: ScreenConfiguration,
        monitorOverlay: MonitorOverlayConfiguration? = nil
    ) -> BookmarkPlaybackSettings {
        BookmarkPlaybackSettings(
            playbackSpeed: config.playbackSpeed,
            fitMode: config.fitMode,
            frameRateLimit: config.frameRateLimit,
            particleEffect: config.particleEffect,
            effectConfig: config.effectConfig,
            muted: config.muted,
            videoVolume: config.videoVolume,
            setAsLockScreen: config.setAsLockScreen,
            monitorOverlayEnabled: monitorOverlay?.enabled,
            monitorOverlayLevel: monitorOverlay?.level
        )
    }
}
