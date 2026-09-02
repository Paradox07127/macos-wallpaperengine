import Foundation

/// Playback/effect snapshot older bookmarks carried. Retained for archives written before the bookmark/scheme split
/// (2026-08-31): nothing writes it and nothing reads it, but dropping the field
/// would rewrite every existing user's bookmarks. Whole-screen state now lives
/// in `ScreenScheme`. See `.notes/plan/screen-schemes.md` D1.
public struct BookmarkPlaybackSettings: Codable, Equatable, Sendable {
    public var playbackSpeed: Double?
    public var fitMode: VideoFitMode?
    public var frameRateLimit: FrameRateLimit?
    public var particleEffect: ParticleEffect?
    public var effectConfig: VideoEffectConfig?
    public var muted: Bool?
    public var videoVolume: Double?
    public var setAsLockScreen: Bool?
    /// Whether the Monitor overlay was showing, and on which layer. The board's own layout is
    /// deliberately NOT captured: it is arranged against one display's geometry and shared by every
    /// wallpaper on it, so restoring a bookmark's copy would silently overwrite arrangement work the
    /// user did later. Bookmarks restore whether the overlay shows, not how it is built.
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
}
