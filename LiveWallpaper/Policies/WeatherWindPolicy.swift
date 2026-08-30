import CoreGraphics
import Foundation

/// Turns a meteorological wind reading into something an emitter can use. Kept pure and separate from
/// both the service and the emitter so the convention — which is genuinely easy to get backwards — is
/// stated once and tested once.
enum WeatherWindPolicy {

    /// Wind direction is reported as the direction it blows *from*, so a 270°
    /// reading is a westerly and pushes particles to the *right* of the screen.
    /// Returns the on-screen horizontal component in −1…1.
    static func horizontalBias(fromDegrees: Double) -> Double {
        guard fromDegrees.isFinite else { return 0 }
        return -sin(fromDegrees * .pi / 180)
    }

    /// How far falling particles lean, in radians from vertical: `atan(windSpeed / fallSpeed)`, the drift angle
    /// at terminal velocity. Fall speed is a parameter, not a constant — rain falls ~10x faster than snow.
    /// Capped at 30° via `tanh`, not a hard clamp: drawn fall speed is points/s, not metres, so a real
    /// wind/velocity ratio overstates the on-screen lean (rain no longer accelerates, so the lean holds the
    /// whole fall instead of being straightened by gravity); `atan` also saturates fast (25 km/h already passes
    /// 40°), so a hard clamp flattened every wind above light to one lean — snow and rain alike, reading moot —
    /// while `tanh` stays monotonic and only approaches the limit.
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
