import CoreGraphics
import Foundation

enum WeatherWindPolicy {

    /// Wind direction is FROM, so 270° (westerly) pushes particles right. Returns on-screen horizontal component in −1…1.
    static func horizontalBias(fromDegrees: Double) -> Double {
        guard fromDegrees.isFinite else { return 0 }
        return -sin(fromDegrees * .pi / 180)
    }

    /// Lean = maximum * tanh(atan(wind/fall) / maximum), not a hard clamp. Drawn fall speed is points/s, so a real wind/velocity ratio overstates on-screen lean.
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

    /// Terminal fall speeds, m/s. Rain ~10× snow, so the same wind tilts snow more.
    enum FallSpeed {
        static let rain: Double = 8
        static let snow: Double = 1
        static let dust: Double = 0.3
    }
}
