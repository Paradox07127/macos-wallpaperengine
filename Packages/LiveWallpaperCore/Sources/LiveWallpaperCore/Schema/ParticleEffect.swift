import SwiftUI

public enum ParticleEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case snow = "Snow"
    case rain = "Rain"
    case bokeh = "Bokeh"
    case fireflies = "Fireflies"
    case dust = "Dust"
    case stars = "Stars"
    case fallingLeaves = "Leaves"
    case sakura = "Sakura"
    case mist = "Mist"

    public var id: String { rawValue }

    /// Whether wind should lean this effect.
    ///
    /// Only the ones that fall. Bokeh, fireflies and stars have no "down" to
    /// tilt away from — leaning them just rotates the whole field, which reads
    /// as the screen being crooked rather than as weather.
    public var leansIntoWind: Bool {
        switch self {
        case .rain, .snow, .fallingLeaves, .sakura, .dust: return true
        // Mist does not fall, so there is no fall direction to lean; it drifts
        // sideways on its own instead.
        case .none, .bokeh, .fireflies, .stars, .mist:     return false
        }
    }

    /// Tolerant decoder: a configuration persisted with a particle effect
    /// that no longer exists (e.g. the rolled-back `Lightning`) decodes to
    /// `.none` instead of failing the whole `ScreenConfiguration` parse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ParticleEffect(rawValue: rawValue) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .bokeh: return "Bokeh"
        case .fireflies: return "Fireflies"
        case .dust: return "Dust"
        case .stars: return "Stars"
        case .fallingLeaves: return "Leaves"
        case .sakura: return "Sakura"
        case .mist: return "Mist"
        }
    }

    public var iconName: String {
        switch self {
        case .none: return "xmark.circle"
        case .snow: return "snowflake"
        case .rain: return "cloud.rain"
        case .bokeh: return "sparkles"
        case .fireflies: return "lightbulb"
        case .dust: return "circle.dotted"
        case .stars: return "star"
        case .fallingLeaves: return "leaf"
        case .sakura: return "camera.macro"
        case .mist: return "cloud.fog"
        }
    }
}
