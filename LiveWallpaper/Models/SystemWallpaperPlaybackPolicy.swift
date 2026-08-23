import Foundation

/// Playback tiers for the system-wallpaper extension, decided from ambient
/// signals the appex can observe on its own. Pure function so the truth
/// table is unit-testable.
enum PlaybackTier: String, Equatable {
    case full       // normal playback
    case reduced    // lower rate, e.g. on battery
    case minimal    // near-still, thermal pressure
    case paused     // fully stopped (system asked, or screen asleep)
}

struct PlaybackPolicyInput: Equatable {
    var thermalState: ProcessInfo.ThermalState
    var onBattery: Bool
    var lowPowerMode: Bool
    var systemRequestedPause: Bool
    /// The system's own presentation mode for this surface: the lock screen and
    /// the login window report "locked", the desktop reports "default".
    var isLockScreen: Bool = false
    var playbackMode: SystemWallpaperPlaybackMode = .always
}

enum PlaybackPolicy {
    static func tier(for input: PlaybackPolicyInput) -> PlaybackTier {
        if input.systemRequestedPause { return .paused }
        // Apple's video wallpapers play on the lock screen and settle into a
        // still once you are at the desktop; this is that behaviour, opt-in.
        if input.playbackMode == .stillOnDesktop, !input.isLockScreen { return .minimal }
        switch input.thermalState {
        case .critical: return .paused
        case .serious: return .minimal
        case .fair: return input.onBattery ? .minimal : .reduced
        case .nominal: break
        @unknown default: return .minimal
        }
        if input.lowPowerMode { return .minimal }
        if input.onBattery { return .reduced }
        return .full
    }

    /// CMTimebase rate for a tier. `reduced` keeps motion visible but cheaper;
    /// `minimal` is the "gradually freeze" target the ramp eases toward.
    static func rate(for tier: PlaybackTier) -> Double {
        switch tier {
        case .full: return 1.0
        case .reduced: return 0.5
        case .minimal: return 0.0
        case .paused: return 0.0
        }
    }
}
