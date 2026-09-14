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
    case embers = "Embers"
    case bubbles = "Bubbles"
    case meteors = "Meteors"

    public var id: String { rawValue }

    /// Whether wind should lean this effect — only the ones that fall; the rest have no "down"
    /// to tilt away from.
    public var leansIntoWind: Bool {
        switch self {
        case .rain, .snow, .fallingLeaves, .sakura, .dust: return true
        // Mist drifts, embers and bubbles rise, meteors come in on a fixed slant — none has a
        // fall to tilt.
        case .none, .bokeh, .fireflies, .stars, .mist,
             .embers, .bubbles, .meteors:                  return false
        }
    }

    /// Tolerant: a persisted effect that no longer exists decodes to `.none` instead of
    /// failing the whole `ScreenConfiguration` parse.
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
        case .embers: return "Embers"
        case .bubbles: return "Bubbles"
        case .meteors: return "Meteors"
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
        case .embers: return "flame"
        case .bubbles: return "bubbles.and.sparkles"
        case .meteors: return "sparkle"
        }
    }
}
