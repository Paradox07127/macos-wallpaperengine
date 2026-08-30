import AppKit
import LiveWallpaperCore

@MainActor
final class VideoWallpaperSession: WallpaperRuntimeSession,
    WallpaperPlaybackControllable,
    WallpaperIntentMachineAdopting,
    WallpaperCriticalMemoryPressureResponding {
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
    /// Single source of truth for session-durable user play intent (policy
    /// suspend never clears it). Self-built so an independently constructed
    /// session stands alone; `ScreenManager` swaps in the screen's shared
    /// machine via `adoptPlaybackStateMachine` on install.
    private var playbackMachine = WallpaperPlaybackStateMachine()
    var userIntendsToPlay: Bool { playbackMachine.userIntendsToPlay }
    /// Last policy profile; manual play re-derives effective state from this + intent.
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Manual pause is not an absence: the user may unpause any moment, so it
    /// keeps the player warm for its own much longer dwell instead of reusing the
    /// absence constant. Mirrors `SceneWallpaperSession.userPauseHibernationDelay`.
    private let userPauseHibernationDelay: Duration
    /// Own slot. The player has a single eligibility flag driven by the absence
    /// signal, and an absence-false push must not cancel this countdown.
    private let pauseDwell = AbsenceDwell()
    /// Last absence eligibility pushed by `ScreenManager`, kept so lifting the
    /// manual-pause override restores the real value instead of inventing one.
    private var absenceHibernationEligible = false
    /// True once the manual-pause dwell has handed the player to deep
    /// hibernation. Folded into suspend depth and eligibility so a policy
    /// refresh or an absence push cannot wake a wallpaper the user still paused.
    private var isManualPauseHibernating = false
    /// Latest critical-pressure state pushed by `ScreenManager`. Held as state,
    /// not consumed as a one-shot: every eligibility push re-derives from it, so
    /// a routine policy refresh cannot cancel a teardown the emergency started.
    private var criticalMemoryPressureActive = false
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
        userPauseHibernationDelay: Duration = ManualPauseHibernation.delay,
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
        self.userPauseHibernationDelay = userPauseHibernationDelay
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
        } else if player.isPlaying {
            activity = .active
        } else if player.isRestoringFromHibernation {
            activity = .restoring
        } else if userIntendsToPlay {
            // `isPlaying` mirrors AVPlayer, so "wants to play but isn't" means
            // policy is holding it — never report that as a user pause.
            activity = .policySuspended
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
        playbackMachine.userPlay()
        applyPerformanceProfile(currentProfile)
    }

    func pause() {
        playbackMachine.userPause()
        applyPerformanceProfile(currentProfile)
    }

    func adoptPlaybackStateMachine(_ machine: WallpaperPlaybackStateMachine) {
        if machine.userIntendsToPlay != playbackMachine.userIntendsToPlay {
            if playbackMachine.userIntendsToPlay {
                machine.userPlay()
            } else {
                machine.userPause()
            }
        }
        playbackMachine = machine
    }

    func show() {
        player?.orderWindowBack()
        applyPerformanceProfile(currentProfile)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        let shouldPlayVideo = userIntendsToPlay && profile == .quality
        // Manual play is the wake trigger, so the override has to go before the
        // suspend depth below is recomputed.
        if userIntendsToPlay {
            isManualPauseHibernating = false
        } else if player?.isHibernated == true {
            // An absence hibernate that completed while the user had this
            // paused stays down on wake: rebuilding a paused pipeline only for
            // the manual-pause dwell to tear it down again is wasted decode.
            isManualPauseHibernating = true
        }
        // Particles ride the policy profile only; a manual pause leaves them running.
        player?.setParticleEffectsSuspended(profile == .suspended)
        // Resource depth only — play/pause below stays the sole owner of intent.
        // A manual pause stays warm for `userPauseHibernationDelay`, after which
        // `pauseDwell` sets `isManualPauseHibernating` and folds in here.
        player?.setSuspended(profile == .suspended || isManualPauseHibernating)
        // After the suspend: the player only arms its own dwell while suspended.
        player?.setHibernationEligible(hibernationTriggersArmed)
        if shouldPlayVideo {
            player?.play()
        } else {
            player?.pause()
        }
        reconcileManualPauseHibernation()
    }

    /// Absence-dwell teardown; the player owns the countdown and the still frame.
    /// A manual-pause hibernation holds eligibility true through an absence-false
    /// push — the two triggers share the player's single dwell slot.
    func setHibernationEligible(_ eligible: Bool) {
        absenceHibernationEligible = eligible
        player?.setHibernationEligible(hibernationTriggersArmed)
    }

    /// The player owns a single eligibility flag, so every push site has to
    /// OR-fold all of the independent triggers into it. Pushing a bare absence
    /// value is how a manual-pause teardown used to get cancelled mid-flight;
    /// the pressure trigger has exactly the same shape.
    private var hibernationTriggersArmed: Bool {
        absenceHibernationEligible || isManualPauseHibernating || criticalMemoryPressureActive
    }

    /// Releases the player, looper items, decode pool and `lwmem://` mapping now rather than
    /// behind a dwell, by reusing the manual-pause handover instead of a second teardown path.
    /// That path also carries the fall-back guard: `hibernateNow` re-validates eligibility,
    /// suspension and `lifecycleGeneration` *after* its still-frame await, so a clear landing
    /// mid-teardown wins.
    func setCriticalMemoryPressureActive(_ active: Bool) {
        criticalMemoryPressureActive = active
        guard active else {
            // Falling back must not invent an eligibility value: re-fold from
            // live state so absence / manual pause decide again, and so a
            // countdown this signal armed is cancelled in the same turn.
            player?.setHibernationEligible(hibernationTriggersArmed)
            return
        }
        applyImmediateCriticalHibernation()
    }

    /// Shared by `setCriticalMemoryPressureActive(true)` and `retry()`: pushes the immediate
    /// teardown rather than `applyPerformanceProfile`'s normal dwelled push. `retry()` calls
    /// this after installing its replacement player, so a player swapped in mid-critical-pressure
    /// goes down right away instead of riding out a full `hibernationDelay` in an emergency.
    private func applyImmediateCriticalHibernation() {
        guard criticalMemoryPressureActive, currentProfile == .suspended, let player else { return }
        player.setSuspended(true)
        player.setHibernationEligible(true, immediately: true)
    }

    /// Second hibernatable class, mirroring `SceneWallpaperSession`: a paused
    /// wallpaper is not an absence, so it counts down in its own slot and never
    /// touches the absence one. Called from every profile fold; the dwell's slot
    /// guard makes repeats idempotent instead of restarting the countdown.
    private func reconcileManualPauseHibernation() {
        guard !userIntendsToPlay, player != nil, !isManualPauseHibernating else {
            pauseDwell.cancel()
            return
        }
        pauseDwell.arm(
            initial: userPauseHibernationDelay,
            retry: userPauseHibernationDelay
        ) { [weak self] in
            guard let self else { return true }
            return hibernateForManualPause()
        }
    }

    /// Hands the paused player into the deep-hibernation path it already owns.
    /// Immediate, not dwelled: `userPauseHibernationDelay` is the whole wait,
    /// and letting the player's absence dwell run again on top of it released a
    /// paused video that much later than a paused scene.
    private func hibernateForManualPause() -> Bool {
        guard !userIntendsToPlay, let player else { return true }
        isManualPauseHibernating = true
        player.setSuspended(true)
        player.setHibernationEligible(true, immediately: true)
        return true
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
        // Intent and policy are never snapshotted — apply latest after replace.
        // The replacement is built `startsHidden`, so it must be ordered back here.
        replacement.orderWindowBack()
        runtimeError = replacement.runtimeError
        // Before the routine push below: `AbsenceDwell.arm` is a no-op once a
        // dwell already occupies the slot, so a dwelled push landing first
        // would claim it at the full delay and make the immediate arm here
        // silently do nothing.
        applyImmediateCriticalHibernation()
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
        pauseDwell.cancel()
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
