import AppKit
import LiveWallpaperCore

@MainActor
final class AmbientWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable, HTMLWallpaperConfigApplying {
    private var window: NSWindow?
    private weak var performanceTarget: (any WallpaperPerformanceConfigurable)?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// Durable user play intent; effective = `userIntendsToPlay && profile == .quality`.
    private(set) var userIntendsToPlay = true
    private var isVisible = true
    let wallpaperType: WallpaperType
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?

    init(
        window: NSWindow,
        wallpaperType: WallpaperType,
        performanceTarget: (any WallpaperPerformanceConfigurable)?
    ) {
        precondition(wallpaperType != .video, "AmbientWallpaperSession only supports non-video wallpapers")
        // Avoid NSWindow default isReleasedWhenClosed over-release on cleanup close.
        window.isReleasedWhenClosed = false
        self.window = window
        self.wallpaperType = wallpaperType
        self.performanceTarget = performanceTarget
    }

    var summary: WallpaperSessionSummary {
        let activity: WallpaperSessionActivity
        if runtimeError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if currentProfile == .suspended || !userIntendsToPlay {
            activity = .paused
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
        isVisible = true
        window?.orderBack(nil)
        // Honour userIntendsToPlay — a manual pause must not resume on visibility alone.
        applyPerformanceProfile(currentProfile)
    }

    var isPlaying: Bool {
        isVisible && userIntendsToPlay && currentProfile == .quality
    }

    func play() {
        userIntendsToPlay = true
        applyPerformanceProfile(currentProfile)
    }

    func pause() {
        userIntendsToPlay = false
        applyPerformanceProfile(currentProfile)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        // Run only when policy, user intent, and visibility all allow.
        let effective: WallpaperPerformanceProfile =
            (isVisible && userIntendsToPlay && profile == .quality) ? .quality : .suspended
        performanceTarget?.applyPerformanceProfile(effective)
    }

    /// Absence-dwell teardown for HTML wallpapers; the view owns the countdown,
    /// the snapshot cover, and the `about:blank` swap.
    func setHibernationEligible(_ eligible: Bool) {
        (performanceTarget as? HTMLWallpaperView)?.setHibernationEligible(eligible)
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
