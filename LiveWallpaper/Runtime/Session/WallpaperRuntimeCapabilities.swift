import LiveWallpaperCore

@MainActor
protocol WallpaperPerformanceConfigurable: AnyObject, Sendable {
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
}

@MainActor
protocol WallpaperFrameRateConfigurable: AnyObject {
    /// Already resolved against the display this session runs on: `FrameRateLimit`
    /// is a divisor, and only the caller knows which panel it divides.
    func setFrameRateCeiling(_ framesPerSecond: Int)
    /// System background throttle layered on the user ceiling without overwriting it.
    func setAdaptiveFrameRateThrottle(_ active: Bool)
}

@MainActor
protocol WallpaperAudioConfigurable: AnyObject {
    func setAudioMuted(_ muted: Bool)
    func setAudioVolume(_ volume: Double)
}

/// immediately skips the runtime's dwell when the caller already waited as long or longer.
@MainActor
protocol WallpaperHibernationEligible: AnyObject {
    func setHibernationEligible(_ eligible: Bool, immediately: Bool)
}

extension WallpaperHibernationEligible {
    func setHibernationEligible(_ eligible: Bool) {
        setHibernationEligible(eligible, immediately: false)
    }
}

/// State, not a one-shot: push every change. Must not write profile or play intent back.
@MainActor
protocol WallpaperCriticalMemoryPressureResponding: AnyObject {
    func setCriticalMemoryPressureActive(_ active: Bool)
}

#if !LITE_BUILD
/// Conformance only — SceneWallpaperSession already implements the method.
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

@MainActor
protocol WallpaperIntentMachineAdopting: AnyObject {
    var playbackMachine: WallpaperPlaybackStateMachine { get set }
    func adoptPlaybackStateMachine(_ machine: WallpaperPlaybackStateMachine)
}

extension WallpaperIntentMachineAdopting {
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
}

@MainActor
protocol WallpaperPlaybackControllable: WallpaperRuntimeSession {
    var isPlaying: Bool { get }
    /// User play intent independent of performance-policy suppression (manual controls read this).
    var userIntendsToPlay: Bool { get }

    func play()
    func pause()
}
