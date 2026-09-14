/// The single source of truth for `userIntendsToPlay`. Deliberately owns no timers and
/// knows nothing about hibernation depth — those stay with the resource owners downstream.
@MainActor
public final class WallpaperPlaybackStateMachine {
    /// The only persistent state. Only `userPlay()`/`userPause()` may change
    /// it — policy never rewrites user intent.
    public private(set) var userIntendsToPlay: Bool

    private var decision: WallpaperPolicyDecision

    public init(userIntendsToPlay: Bool = true) {
        self.userIntendsToPlay = userIntendsToPlay
        decision = WallpaperPolicyDecision(profile: .quality)
    }

    /// Split outputs, not one folded bool: downstream predicates differ
    /// (video particles follow policy alone; play/pause follows intent too).
    public struct Outputs: Equatable, Sendable {
        /// Policy alone, ignoring intent.
        public var policyProfile: WallpaperPerformanceProfile
        /// Intent folded in: plays only when the user wants it and policy allows.
        public var effectiveProfile: WallpaperPerformanceProfile
        /// Distinguishes `.paused` from `.policySuspended` in summaries; manual
        /// pause is deliberately not a `WallpaperSuspendReason`.
        public var userPaused: Bool
        public var throttleActive: Bool
        public var suspendReasons: Set<WallpaperSuspendReason>

        public init(
            policyProfile: WallpaperPerformanceProfile,
            effectiveProfile: WallpaperPerformanceProfile,
            userPaused: Bool,
            throttleActive: Bool,
            suspendReasons: Set<WallpaperSuspendReason>
        ) {
            self.policyProfile = policyProfile
            self.effectiveProfile = effectiveProfile
            self.userPaused = userPaused
            self.throttleActive = throttleActive
            self.suspendReasons = suspendReasons
        }
    }

    public var outputs: Outputs {
        Outputs(
            policyProfile: decision.profile,
            effectiveProfile: userIntendsToPlay && decision.profile == .quality
                ? .quality
                : .suspended,
            userPaused: !userIntendsToPlay,
            // Gate is policy suspension, not user pause: policy-only consumers keep seeing
            // throttle while the user has playback paused.
            throttleActive: decision.profile == .suspended
                ? false
                : !decision.throttleReasons.isEmpty,
            suspendReasons: decision.suspendReasons
        )
    }

    @discardableResult
    public func userPlay() -> Outputs {
        userIntendsToPlay = true
        return outputs
    }

    @discardableResult
    public func userPause() -> Outputs {
        userIntendsToPlay = false
        return outputs
    }

    @discardableResult
    public func policyChanged(_ decision: WallpaperPolicyDecision) -> Outputs {
        self.decision = decision
        return outputs
    }
}
