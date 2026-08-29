import CoreGraphics
import Foundation

/// Turns a meteorological wind reading into something an emitter can use.
///
/// Kept pure and separate from both the service and the emitter so the
/// convention — which is genuinely easy to get backwards — is stated once and
/// tested once.
enum WeatherWindPolicy {

    /// Wind direction is reported as the direction it blows *from*, so a 270°
    /// reading is a westerly and pushes particles to the *right* of the screen.
    /// Returns the on-screen horizontal component in −1…1.
    static func horizontalBias(fromDegrees: Double) -> Double {
        guard fromDegrees.isFinite else { return 0 }
        return -sin(fromDegrees * .pi / 180)
    }

    /// How far falling particles lean, in radians from vertical.
    ///
    /// From the physics rather than taste: a particle at terminal velocity
    /// drifts with the air, so its path makes `atan(windSpeed / fallSpeed)`
    /// with the vertical. Fall speed differs per effect — a raindrop is an
    /// order of magnitude faster than a snowflake — which is why it is a
    /// parameter and not a constant.
    ///
    /// Capped: past roughly 60° the emitter is throwing particles sideways
    /// across the screen, which reads as a glitch rather than as weather, and
    /// gusts of that size are rare enough not to be worth looking wrong for.
    static func tiltRadians(
        windSpeedKPH: Double,
        fallSpeedMPS: Double,
        maximum: Double = .pi / 3
    ) -> Double {
        guard windSpeedKPH.isFinite, windSpeedKPH > 0, fallSpeedMPS > 0 else { return 0 }
        let windMPS = windSpeedKPH / 3.6
        return min(atan(windMPS / fallSpeedMPS), maximum)
    }

    /// Terminal fall speeds, m/s, used only to work out the lean above.
    /// Raindrops fall roughly an order of magnitude faster than snowflakes,
    /// so the same wind tilts snow far more than rain — which is exactly what
    /// it looks like out of a window.
    enum FallSpeed {
        static let rain: Double = 8
        static let snow: Double = 1
        static let dust: Double = 0.3
    }
}
