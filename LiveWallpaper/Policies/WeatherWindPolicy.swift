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
    /// Capped, and lower than the physics alone would suggest. The drawn fall
    /// speed is in points per second and is not calibrated to metres, so
    /// pushing a real wind through a real terminal velocity overstates the
    /// on-screen lean: rain no longer accelerates, so the lean now holds for
    /// the whole fall instead of being straightened out by gravity a second
    /// in, and an ordinary breeze came out looking like a gale. 30° is about
    /// where a leaning field still reads as rain rather than as sleet fired
    /// across the desktop.
    /// Compressed rather than clipped. `atan(wind / fall)` saturates fast — an
    /// ordinary 25 km/h breeze already puts rain past 40° — so a hard clamp at
    /// a comfortable angle made every wind above a light one produce the exact
    /// same lean, and the wind reading stopped mattering at all (it also made
    /// snow and rain lean identically, which they never do). `tanh` keeps the
    /// gentle end untouched, stays strictly increasing forever, and only
    /// approaches the limit instead of hitting it.
    static func tiltRadians(
        windSpeedKPH: Double,
        fallSpeedMPS: Double,
        maximum: Double = .pi / 6
    ) -> Double {
        guard windSpeedKPH.isFinite, windSpeedKPH > 0, fallSpeedMPS > 0, maximum > 0 else {
            return 0
        }
        let windMPS = windSpeedKPH / 3.6
        return maximum * tanh(atan(windMPS / fallSpeedMPS) / maximum)
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
