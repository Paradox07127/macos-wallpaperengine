import LiveWallpaperCore

@MainActor
protocol WallpaperPerformanceConfigurable: AnyObject, Sendable {
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
}

/// Renderers that own a display-link-equivalent and can retarget tempo at runtime.
@MainActor
protocol WallpaperFrameRateConfigurable: AnyObject {
    func setFrameRateLimit(_ limit: FrameRateLimit)
    /// System background throttle layered on the user ceiling without overwriting it.
    func setAdaptiveFrameRateThrottle(_ active: Bool)
}

/// Non-video audio owner (e.g. scene `WPESoundRuntime`); inspector mute/volume routes here.
@MainActor
protocol WallpaperAudioConfigurable: AnyObject {
    func setAudioMuted(_ muted: Bool)
    func setAudioVolume(_ volume: Double)
}

/// Runtimes that own a deep-hibernate teardown behind their own dwell, so the
/// session can drive eligibility without casting to a concrete view type.
@MainActor
protocol WallpaperHibernationEligible: AnyObject {
    func setHibernationEligible(_ eligible: Bool)
}

@MainActor
protocol WallpaperResourceCleanable: AnyObject {
    func cleanup()
}

@MainActor
protocol HTMLWallpaperConfigApplying: AnyObject {
    /// Reconfigures a live HTML renderer without replacing the window.
    func applyHTMLConfig(_ config: HTMLConfig) -> Bool
}

@MainActor
protocol HTMLWallpaperRetrying: AnyObject {
    /// User reload with a fresh retry budget; waits for display readiness.
    func retryCurrentSource(timeout: Duration) async -> WallpaperPreparationResult
}

/// Sessions that can swap their self-built intent machine for the screen's
/// shared one at install time. Adoption syncs the incoming machine to the
/// session's current intent before the reference swap, so an install/replace
/// never rewrites user intent.
@MainActor
protocol WallpaperIntentMachineAdopting: AnyObject {
    func adoptPlaybackStateMachine(_ machine: WallpaperPlaybackStateMachine)
}

@MainActor
protocol WallpaperPlaybackControllable: WallpaperRuntimeSession {
    var isPlaying: Bool { get }
    /// User play intent independent of performance-policy suppression (manual controls read this).
    var userIntendsToPlay: Bool { get }

    func play()
    func pause()
}
