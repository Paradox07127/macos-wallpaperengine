import Foundation

/// Why a wallpaper stopped or slowed down. Carried alongside the profile so the UI can tell the user
/// which condition is holding playback down. Without it every stop looks identical to a user pause,
/// which is what made a policy-suspended wallpaper indistinguishable from one the user paused themselves.
public enum WallpaperSuspendReason: String, Equatable, Hashable, Sendable, CaseIterable {
    // Safety: not governed by user settings, cannot be vetoed by `.neverPause`.
    case userAbsent
    case memoryPressure
    case thermal

    // Discretionary: each gated by its own setting, vetoable by `.neverPause`.
    case applicationRule
    case lowPowerMode
    case battery
    case fullScreen
    case windowOcclusion

    /// Safety reasons cannot be turned off in settings, so the UI must not offer
    /// a settings shortcut for them — only a "this will lift on its own" note.
    public var isSafety: Bool {
        switch self {
        case .userAbsent, .memoryPressure, .thermal:
            true
        case .applicationRule, .lowPowerMode, .battery, .fullScreen, .windowOcclusion:
            false
        }
    }

    /// While absent the user is not looking at the screen, so surfacing a reason
    /// for it would only ever be read after the fact.
    public var isUserVisible: Bool {
        self != .userAbsent
    }
}

/// A resolved performance decision: the profile plus why it came out that way.
public struct WallpaperPolicyDecision: Equatable, Sendable {
    public var profile: WallpaperPerformanceProfile
    /// Non-empty exactly when `profile == .suspended`.
    public var suspendReasons: Set<WallpaperSuspendReason>
    /// Conditions asking for less work while playback continues. Kept separate
    /// from suspension so a warm machine slows down instead of stopping.
    public var throttleReasons: Set<WallpaperSuspendReason>

    public init(
        profile: WallpaperPerformanceProfile,
        suspendReasons: Set<WallpaperSuspendReason> = [],
        throttleReasons: Set<WallpaperSuspendReason> = []
    ) {
        self.profile = profile
        self.suspendReasons = suspendReasons
        self.throttleReasons = throttleReasons
    }
}
