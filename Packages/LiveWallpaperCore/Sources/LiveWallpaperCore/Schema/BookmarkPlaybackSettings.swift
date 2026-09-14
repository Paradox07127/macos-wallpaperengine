import Foundation

/// Dead by design: nothing writes or reads it, but dropping the field would rewrite
/// every existing user's bookmarks. Whole-screen state now lives in `ScreenScheme`.
public struct BookmarkPlaybackSettings: Codable, Equatable, Sendable {
    public var playbackSpeed: Double?
    public var fitMode: VideoFitMode?
    public var frameRateLimit: FrameRateLimit?
    public var particleEffect: ParticleEffect?
    public var effectConfig: VideoEffectConfig?
    public var muted: Bool?
    public var videoVolume: Double?
    public var setAsLockScreen: Bool?
    /// Whether the Monitor overlay was showing, and on which layer. The board's layout is
    /// deliberately NOT captured — restoring it would overwrite arrangement work done later.
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
