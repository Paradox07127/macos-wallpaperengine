/// Decides when a scene should use its lower-power frame-rate profile.
enum AdaptiveFrameRatePolicy {
    /// Occlusion enter threshold for adaptive FPS (below 0.85 pause cutoff).
    static let occlusionEnterThreshold = 0.5
    /// Occlusion exit threshold (hysteresis vs enter so FPS does not flap).
    static let occlusionExitThreshold = 0.4

    /// The caller must latch only the occlusion result so battery transitions do not bypass hysteresis.
    static func shouldThrottleForOcclusion(
        occlusionFraction: Double,
        currentlyThrottled: Bool
    ) -> Bool {
        let threshold = currentlyThrottled ? occlusionExitThreshold : occlusionEnterThreshold
        return occlusionFraction >= threshold
    }

    /// Combines the latched occlusion decision with the battery policy.
    static func shouldThrottle(
        enabled: Bool,
        occlusionThrottled: Bool,
        onBattery: Bool,
        pausesOnBattery: Bool
    ) -> Bool {
        guard enabled else { return false }
        return occlusionThrottled || (onBattery && !pausesOnBattery)
    }
}
