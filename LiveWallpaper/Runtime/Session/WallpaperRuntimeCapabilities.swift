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
///
/// `immediately` skips that dwell for a caller that has already served an
/// equivalent (or longer) wait of its own — today only the manual-pause
/// countdown, which must release at the same wall-clock mark for every
/// wallpaper kind instead of stacking the two delays.
@MainActor
protocol WallpaperHibernationEligible: AnyObject {
    func setHibernationEligible(_ eligible: Bool, immediately: Bool)
}

extension WallpaperHibernationEligible {
    func setHibernationEligible(_ eligible: Bool) {
        setHibernationEligible(eligible, immediately: false)
    }
}

/// Runtimes that can shed resident resources on *critical* system memory
/// pressure, ahead of the dwell countdowns they normally release behind.
///
/// Taken as state, not as a one-shot trigger: the level is pushed on every
/// change so a runtime can revoke whatever it armed once the emergency clears.
///
/// Orthogonal to `applyPerformanceProfile`, never a substitute for it. The
/// profile decides *whether* a wallpaper runs and owns play intent; this only
/// decides *how deep* an already-suspended one goes, and implementations must
/// not write the profile or intent back from here — otherwise the two signals
/// start overwriting each other.
@MainActor
protocol WallpaperCriticalMemoryPressureResponding: AnyObject {
    func setCriticalMemoryPressureActive(_ active: Bool)
}

#if !LITE_BUILD
/// Conformance only — the scene session already had this method and its body is
/// unchanged. Declared here so `SceneWallpaperSession.swift` stays untouched.
extension SceneWallpaperSession: WallpaperCriticalMemoryPressureResponding {}
#endif

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
