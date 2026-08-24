import AppKit
import LiveWallpaperCore

@MainActor
final class AmbientWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable, HTMLWallpaperConfigApplying, WallpaperIntentMachineAdopting, WallpaperCriticalMemoryPressureResponding {
    private var window: NSWindow?
    private weak var performanceTarget: (any WallpaperPerformanceConfigurable)?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Single source of truth for durable user play intent; effective =
    /// `userIntendsToPlay && profile == .quality`. Self-built so an
    /// independently constructed session stands alone; `ScreenManager` swaps in
    /// the screen's shared machine via `adoptPlaybackStateMachine` on install.
    private var playbackMachine = WallpaperPlaybackStateMachine()
    var userIntendsToPlay: Bool { playbackMachine.userIntendsToPlay }
    let wallpaperType: WallpaperType
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?
    /// Manual pause is not an absence: the user may unpause any moment, so it
    /// gets its own much longer dwell instead of reusing the view's absence
    /// constant. Matches `SceneWallpaperSession.userPauseHibernationDelay`.
    private let userPauseHibernationDelay: Duration
    /// Own slot: the view has a single dwell slot fed by absence pushes, so the
    /// manual-pause countdown has to live where `userIntendsToPlay` is known.
    private let pauseDwell = AbsenceDwell()
    /// The two eligibility inputs are folded before reaching the view, so an
    /// absence `false` push cannot cancel a manual-pause hibernation.
    private var absenceHibernationEligible = false
    private var manualPauseHibernationRequested = false
    /// Third trigger folded into the same single eligibility slot.
    private var criticalMemoryPressureActive = false

    init(
        window: NSWindow,
        wallpaperType: WallpaperType,
        performanceTarget: (any WallpaperPerformanceConfigurable)?,
        userPauseHibernationDelay: Duration = ManualPauseHibernation.delay
    ) {
        precondition(wallpaperType != .video, "AmbientWallpaperSession only supports non-video wallpapers")
        // Avoid NSWindow default isReleasedWhenClosed over-release on cleanup close.
        window.isReleasedWhenClosed = false
        self.window = window
        self.wallpaperType = wallpaperType
        self.performanceTarget = performanceTarget
        self.userPauseHibernationDelay = userPauseHibernationDelay
    }

    var summary: WallpaperSessionSummary {
        let activity: WallpaperSessionActivity
        if runtimeError != nil {
            activity = .error
        } else if !userIntendsToPlay {
            activity = .paused
        } else if currentProfile == .suspended {
            activity = .policySuspended
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: runtimeError.map { LogPrivacyRedactor.scrub($0.userMessage) }
        )
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        window
    }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
    }

    func show() {
        window?.orderBack(nil)
        // Honour userIntendsToPlay — a manual pause must not resume on visibility alone.
        applyPerformanceProfile(currentProfile)
    }

    var isPlaying: Bool {
        userIntendsToPlay && currentProfile == .quality
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

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        // Run only when policy and user intent both allow.
        let effective: WallpaperPerformanceProfile =
            (userIntendsToPlay && profile == .quality) ? .quality : .suspended
        performanceTarget?.applyPerformanceProfile(effective)
        reconcileManualPauseHibernation()
    }

    /// Absence-dwell teardown for HTML wallpapers; the view owns the countdown,
    /// the snapshot cover, and the `about:blank` swap.
    func setHibernationEligible(_ eligible: Bool) {
        absenceHibernationEligible = eligible
        pushHibernationEligibility()
    }

    private func pushHibernationEligibility(immediate: Bool = false) {
        (performanceTarget as? any WallpaperHibernationEligible)?
            .setHibernationEligible(
                absenceHibernationEligible
                    || manualPauseHibernationRequested
                    || criticalMemoryPressureActive,
                immediately: immediate
            )
    }

    /// Hands the already-suspended HTML view into the deep-hibernation path it
    /// owns (snapshot cover → `about:blank`) without waiting out its absence
    /// dwell. A session still at `.quality` is one the profile has not reached
    /// yet: tearing that one down would override the profile rather than layer
    /// on it.
    func setCriticalMemoryPressureActive(_ active: Bool) {
        criticalMemoryPressureActive = active
        guard active else {
            // Falling back must not invent an eligibility value: re-fold from
            // live state so absence / manual pause decide again, and so an arm
            // this signal made in the same turn is revoked before it runs.
            pushHibernationEligibility()
            return
        }
        guard currentProfile == .suspended else { return }
        pushHibernationEligibility(immediate: true)
    }

    /// User frame-rate ceiling for the HTML runtime. Separate from the profile:
    /// `.suspended` stops the page, this only slows it down.
    func setFrameRateLimit(_ limit: FrameRateLimit) {
        (performanceTarget as? any HTMLWallpaperFrameRateTargeting)?
            .setTargetFrameRate(limit)
    }

    /// Second hibernatable class: the view only ever sees the folded
    /// `.suspended` profile and cannot tell a manual pause from a policy
    /// suspend, so the countdown belongs here, next to `userIntendsToPlay`.
    private func reconcileManualPauseHibernation() {
        guard !userIntendsToPlay else {
            pauseDwell.cancel()
            guard manualPauseHibernationRequested else { return }
            manualPauseHibernationRequested = false
            pushHibernationEligibility()
            return
        }
        // Called from every profile fold; the dwell's single slot makes the
        // repeats idempotent instead of restarting the countdown.
        pauseDwell.arm(
            initial: userPauseHibernationDelay,
            retry: userPauseHibernationDelay
        ) { [weak self] in
            guard let self, !userIntendsToPlay else { return true }
            manualPauseHibernationRequested = true
            // The 300s wait happened here; the view must not dwell again on top.
            pushHibernationEligibility(immediate: true)
            return true
        }
    }

    func retry() async {
        guard let retryTarget = performanceTarget as? any HTMLWallpaperRetrying else { return }
        let result = await retryTarget.retryCurrentSource(timeout: .seconds(5))
        guard result == .ready else { return }
        runtimeError = nil
    }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        guard wallpaperType == .html else { return false }
        guard let target = performanceTarget as? any HTMLWallpaperConfigApplying else { return false }
        return target.applyHTMLConfig(config)
    }

    func captureLiveHTMLSnapshot(
        matching source: HTMLSource,
        config: HTMLConfig
    ) async -> NSImage? {
        guard wallpaperType == .html,
              let target = performanceTarget as? HTMLWallpaperView else { return nil }
        guard target.livePreviewCaptureState.canReuse(
            requestedSource: source,
            requestedConfig: config
        ) else { return nil }
        return await target.captureLivePreviewSnapshot()
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        // Type-specific readiness (native chrome is sync; HTML waits below).
        switch performanceTarget {
        case let html as HTMLWallpaperView:
            return await html.prepareForDisplay(timeout: timeout)
        default:
            return .failed
        }
    }

    /// Bridged from `HTMLWallpaperView.onError` so the session keeps the user-visible error.
    func recordRuntimeError(_ error: WallpaperRuntimeError) {
        runtimeError = error
    }

    func cleanup() {
        pauseDwell.cancel()
        performanceTarget?.applyPerformanceProfile(.suspended)
        (performanceTarget as? any WallpaperResourceCleanable)?.cleanup()
        window?.close()
        window = nil
        performanceTarget = nil
    }

    deinit {
        let w = window
        let target = performanceTarget
        if w != nil || target != nil {
            Task { @MainActor in
                target?.applyPerformanceProfile(.suspended)
                (target as? any WallpaperResourceCleanable)?.cleanup()
                w?.close()
            }
        }
    }
}
