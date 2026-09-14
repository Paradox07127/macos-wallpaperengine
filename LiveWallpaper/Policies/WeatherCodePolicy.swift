import Foundation

/// WMO triples already carry slight/moderate/heavy; collapsing each triple onto one description would draw drizzle and a downpour the same.
enum WeatherIntensity: String, Sendable, CaseIterable {
    case light
    case moderate
    case heavy

    var densityMultiplier: Double {
        switch self {
        case .light:    return 0.55
        case .moderate: return 1.0
        case .heavy:    return 1.8
        }
    }
}

enum WeatherCodePolicy {

    /// Intensity carried by the code itself. Codes with no intensity axis
    /// (clear, cloud, fog, thunder) answer `.moderate` — they have one look.
    static func intensity(forWMOCode code: Int) -> WeatherIntensity {
        switch code {
        // Drizzle: slight / moderate / dense, then freezing slight / dense.
        case 51, 56:            return .light
        case 53:                return .moderate
        case 55, 57:            return .heavy
        // Rain: slight / moderate / heavy, then freezing slight / heavy.
        case 61, 66:            return .light
        case 63:                return .moderate
        case 65, 67:            return .heavy
        // Snowfall: slight / moderate / heavy. 77 is snow grains — the lightest snow.
        case 71, 77:            return .light
        case 73:                return .moderate
        case 75:                return .heavy
        // Showers: rain slight / moderate / violent, then snow slight / heavy.
        case 80, 85:            return .light
        case 81:                return .moderate
        case 82, 86:            return .heavy
        // Thunderstorm, with and without hail.
        case 95:                return .moderate
        case 96, 99:            return .heavy
        default:                return .moderate
        }
    }

    /// Freezing drizzle and freezing rain. Visually still rain, but it is not
    /// the same weather, and the colour grade should not pretend it is.
    static func isFreezing(wmoCode code: Int) -> Bool {
        switch code {
        case 56, 57, 66, 67: return true
        default:             return false
        }
    }
}
