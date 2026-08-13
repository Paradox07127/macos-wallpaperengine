import AppKit
import LiveWallpaperCore

@MainActor
final class VideoWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    typealias RetryPlayerFactory = @MainActor (
        URL,
        CGRect,
        VideoFitMode,
        String?
    ) -> WallpaperVideoPlayer
    typealias RetryPreparation = @MainActor (
        WallpaperVideoPlayer
    ) async -> WallpaperPreparationResult

    private var player: WallpaperVideoPlayer?
    private let retryPlayerFactory: RetryPlayerFactory
    private let retryPreparation: RetryPreparation
    /// Separate effects generation — a replacement build may still be in flight.
    private let effectsWorkRevisionProvider: @MainActor (
        WallpaperVideoPlayer
    ) -> UInt64?
    private let effectsWorkIsActiveProvider: @MainActor (
        WallpaperVideoPlayer
    ) -> Bool
    private let retireEffectsWork: @MainActor (WallpaperVideoPlayer) -> Void
    /// Session-durable user play intent (policy suspend never clears it).
    private(set) var userIntendsToPlay = true
    /// Last policy profile; manual play re-derives effective state from this + intent.
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Window visibility (master off orderOut); distinct from pause (last frame stays).
    private var isVisible = true
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?
    /// In-session retry rebinds playback-state observation to the replacement player.
    var onVideoPlayerReplacement: (@MainActor (
        WallpaperVideoPlayer,
        WallpaperVideoPlayer
    ) -> Void)?

    init(
        player: WallpaperVideoPlayer,
        effectsWorkRevisionProvider: @MainActor @escaping (
            WallpaperVideoPlayer
        ) -> UInt64? = { _ in nil },
        effectsWorkIsActiveProvider: @MainActor @escaping (
            WallpaperVideoPlayer
        ) -> Bool = { _ in false },
        retireEffectsWork: @MainActor @escaping (
            WallpaperVideoPlayer
        ) -> Void = { _ in },
        retryPlayerFactory: @escaping RetryPlayerFactory = {
            url,
            frame,
            fitMode,
            packageEntryName in
            WallpaperVideoPlayer(
                url: url,
                frame: frame,
                fitMode: fitMode,
                packageEntryName: packageEntryName,
                startsHidden: true
            )
        },
        retryPreparation: @escaping RetryPreparation = { replacement in
            await WallpaperPreparationWaiter.withHardDeadline(
                timeout: .seconds(5)
            ) {
                let base = await replacement.prepareForDisplay(timeout: .seconds(5))
                guard base == .ready else { return base }
                if replacement.requiresFrameRatePreparationForRetry {
                    let frameRatePrepared = await replacement.prepareFrameRateLimit(
                        replacement.requestedFrameRateLimit,
                        timeout: .seconds(5)
                    )
                    guard frameRatePrepared == .ready else {
                        return frameRatePrepared
                    }
                }
                return await replacement.prepareForCurrentComposition(
                    after: .ready,
                    timeout: .seconds(5)
                )
            }
        }
    ) {
        self.player = player
        self.effectsWorkRevisionProvider = effectsWorkRevisionProvider
        self.effectsWorkIsActiveProvider = effectsWorkIsActiveProvider
        self.retireEffectsWork = retireEffectsWork
        self.retryPlayerFactory = retryPlayerFactory
        self.retryPreparation = retryPreparation
        runtimeError = player.runtimeError
        attachErrorHandler(to: player)
    }

    var wallpaperType: WallpaperType {
        .video
    }

    var summary: WallpaperSessionSummary {
        guard let player else { return .notConfigured }
        let activity: WallpaperSessionActivity
        if runtimeError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if player.isPlaying {
            activity = .active
        } else {
            activity = .paused
        }
        return WallpaperSessionSummary(
            wallpaperType: .video,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: runtimeError.map { LogPrivacyRedactor.scrub($0.userMessage) }
        )
    }

    var videoPlayer: WallpaperVideoPlayer? {
        player
    }

    var wallpaperWindow: NSWindow? {
        nil
    }

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    func updateFrame(to frame: CGRect) {
        player?.updateWindowFrame(frame)
    }

    func play() {
        userIntendsToPlay = true
        applyPerformanceProfile(currentProfile)
    }

    func pause() {
        userIntendsToPlay = false
        applyPerformanceProfile(currentProfile)
    }

    func show() {
        isVisible = true
        player?.setWindowVisible(true)
        applyPerformanceProfile(currentProfile)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        let shouldPlayVideo = isVisible && userIntendsToPlay && profile == .quality
        // Manual-pause contract (AVPlayer only); resource fix is for system suspend.
        player?.setParticleEffectsSuspended(profile == .suspended || !isVisible)
        if shouldPlayVideo {
            player?.play()
        } else {
            player?.pause()
        }
    }

    func retry() async {
        guard let oldPlayer = player,
              let url = oldPlayer.videoURL,
              !effectsWorkIsActiveProvider(oldPlayer) else {
            return
        }
        // Composition/effects CAS on request+publication generation — not safe to refresh post-ready.
        let expectedEffectsWorkRevision = effectsWorkRevisionProvider(oldPlayer)
        let expectedCompositionRevision = oldPlayer.videoCompositionRevision
        let expectedFrameRateLimit = oldPlayer.requestedFrameRateLimit
        let expectedColorSpace = oldPlayer.currentColorSpacePreference

        let replacement = retryPlayerFactory(
            url,
            oldPlayer.currentWindowFrame,
            oldPlayer.currentFitMode,
            oldPlayer.packageEntryName
        )
        Self.applyCompositionState(from: oldPlayer, to: replacement)
        // Retry candidate stays silent while the visible player owns audio.
        replacement.setMuted(true)

        let preparation = await retryPreparation(replacement)
        guard preparation == .ready,
              !Task.isCancelled,
              player === oldPlayer,
              !effectsWorkIsActiveProvider(oldPlayer),
              effectsWorkRevisionProvider(oldPlayer) == expectedEffectsWorkRevision,
              oldPlayer.videoCompositionRevision == expectedCompositionRevision,
              oldPlayer.requestedFrameRateLimit == expectedFrameRateLimit,
              oldPlayer.currentColorSpacePreference == expectedColorSpace else {
            replacement.cleanup()
            return
        }

        // Re-read cheap state immediately before identity CAS (not a stale snapshot).
        let latestFrame = oldPlayer.currentWindowFrame
        let latestFitMode = oldPlayer.currentFitMode
        let latestMuted = oldPlayer.isMuted
        let latestVolume = oldPlayer.audioVolume
        let latestSpeed = oldPlayer.currentPlaybackSpeed
        let latestParticle = oldPlayer.currentParticleConfiguration
        let latestSpan = oldPlayer.currentSpanRenderConfiguration
        replacement.updateWindowFrame(latestFrame)
        replacement.setVideoFitMode(latestFitMode)
        replacement.setVolume(latestVolume)
        replacement.setPlaybackSpeed(latestSpeed)
        replacement.setSpanRenderConfiguration(latestSpan)
        replacement.setParticleEffect(
            latestParticle.effect,
            density: latestParticle.density
        )

        guard installPreparedRetryPlayer(replacement, replacing: oldPlayer) else {
            replacement.cleanup()
            return
        }
        replacement.setMuted(latestMuted)
        // Intent/policy/visibility are never snapshotted — apply latest after replace.
        replacement.setWindowVisible(isVisible)
        runtimeError = replacement.runtimeError
        applyPerformanceProfile(currentProfile)
        retireEffectsWork(oldPlayer)
        oldPlayer.cleanup()
    }

    /// Copy composition state: FPS request first, then prepared composition (order matters).
    static func applyCompositionState(
        from source: WallpaperVideoPlayer,
        to replacement: WallpaperVideoPlayer
    ) {
        let colorSpace = source.currentColorSpacePreference
        replacement.setVideoColorSpace(colorSpace)
        let frameRateLimit = source.requestedFrameRateLimit
        if frameRateLimit > 0 {
            replacement.setFrameRateLimit(frameRateLimit)
        }
        if colorSpace != .forceSDR,
           let composition = source.currentVideoComposition {
            replacement.setVideoComposition(
                composition,
                owner: source.videoCompositionOwner
            )
        }
    }

    /// Install prepared retry player and rebind Screen observer in the same MainActor turn.
    @discardableResult
    func installPreparedRetryPlayer(
        _ replacement: WallpaperVideoPlayer,
        replacing oldPlayer: WallpaperVideoPlayer
    ) -> Bool {
        guard player === oldPlayer else { return false }
        oldPlayer.onError = nil
        player = replacement
        onVideoPlayerReplacement?(oldPlayer, replacement)
        attachErrorHandler(to: replacement)
        return true
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        guard let player else { return .failed }
        return await player.prepareForDisplay(timeout: timeout)
    }

    func cleanup() {
        guard let currentPlayer = player else { return }
        // Clear ownership before retirement callback so a
        // re-entrant cleanup remains idempotent. Effects work must be retired
        // before the player tears down its composition/item state.
        player = nil
        currentPlayer.onError = nil
        retireEffectsWork(currentPlayer)
        currentPlayer.cleanup()
    }

    deinit {
        let p = player
        if let p {
            Task { @MainActor in
                p.cleanup()
            }
        }
    }

    private func attachErrorHandler(to player: WallpaperVideoPlayer) {
        player.onError = { [weak self, weak player] error in
            guard let self, let player, self.player === player else { return }
            self.runtimeError = error
        }
    }
}
