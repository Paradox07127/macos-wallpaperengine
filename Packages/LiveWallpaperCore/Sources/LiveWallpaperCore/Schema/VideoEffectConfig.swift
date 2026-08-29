import Foundation

public struct VideoEffectConfig: Codable, Equatable, Sendable {
    public var blurRadius: Double = 0
    public var saturation: Double = 1.0
    public var brightness: Double = 0
    public var warmth: Double = 6500
    public var vignetteIntensity: Double = 0
    public var autoTimeTint: Bool = false
    public var weatherReactive: Bool = false
    /// Whether live wind leans the particles. Off by default: the lean is
    /// honest for the whole fall now that rain no longer accelerates, and an
    /// ordinary breeze then reads as a gale across the desktop. Opt-in.
    public var weatherWind: Bool = false
    /// Whether the reported rain/snow intensity scales the density.
    public var weatherIntensity: Bool = true
    public var particleDensity: Double = 1.0

    public static let `default` = VideoEffectConfig()

    public var hasActiveEffect: Bool {
        blurRadius > 0 || saturation != 1.0 || brightness != 0 ||
        warmth != 6500 || vignetteIntensity > 0 || autoTimeTint || weatherReactive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 6500
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        autoTimeTint = try container.decodeIfPresent(Bool.self, forKey: .autoTimeTint) ?? false
        weatherReactive = try container.decodeIfPresent(Bool.self, forKey: .weatherReactive) ?? false
        weatherWind = try container.decodeIfPresent(Bool.self, forKey: .weatherWind) ?? false
        weatherIntensity = try container.decodeIfPresent(Bool.self, forKey: .weatherIntensity) ?? true
        particleDensity = try container.decodeIfPresent(Double.self, forKey: .particleDensity) ?? 1.0
    }

    public init() {}
}
