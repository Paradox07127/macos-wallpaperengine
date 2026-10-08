import Foundation

/// The weather (particle) layer of one display. Lives in `GlobalSettings.weatherOverlays`
/// so it exists without, and outlives, that display's wallpaper configuration.
public struct WeatherOverlayConfiguration: Codable, Equatable, Sendable {
    /// `.none` is the layer's off switch.
    public var particleEffect: ParticleEffect = .none
    public var weatherReactive: Bool = false
    public var particleDensity: Double = 1.0
    public var weatherWind: Bool = false
    public var weatherIntensity: Bool = true

    public static let `default` = WeatherOverlayConfiguration()

    public init(
        particleEffect: ParticleEffect = .none,
        weatherReactive: Bool = false,
        particleDensity: Double = 1.0,
        weatherWind: Bool = false,
        weatherIntensity: Bool = true
    ) {
        self.particleEffect = particleEffect
        self.weatherReactive = weatherReactive
        self.particleDensity = particleDensity
        self.weatherWind = weatherWind
        self.weatherIntensity = weatherIntensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        particleEffect = (try? c.decodeIfPresent(ParticleEffect.self, forKey: .particleEffect)) ?? .none
        weatherReactive = (try? c.decodeIfPresent(Bool.self, forKey: .weatherReactive)) ?? false
        particleDensity = (try? c.decodeIfPresent(Double.self, forKey: .particleDensity)) ?? 1.0
        weatherWind = (try? c.decodeIfPresent(Bool.self, forKey: .weatherWind)) ?? false
        weatherIntensity = (try? c.decodeIfPresent(Bool.self, forKey: .weatherIntensity)) ?? true
    }

    /// Moves the weather values older builds stored on each `ScreenConfiguration` into `overlays`,
    /// keyed by the configuration's fingerprint. An existing entry wins; a configuration without a
    /// fingerprint keeps its values for a later pass. nil = nothing to change.
    public static func migratingLegacy(
        configurations: [ScreenConfiguration],
        into overlays: [String: WeatherOverlayConfiguration]
    ) -> (configurations: [ScreenConfiguration], overlays: [String: WeatherOverlayConfiguration])? {
        var migratedConfigurations = configurations
        var migratedOverlays = overlays
        for index in migratedConfigurations.indices {
            let legacy = migratedConfigurations[index].legacyWeatherOverlay
            guard legacy != .default, let key = migratedConfigurations[index].displayFingerprint else { continue }
            if migratedOverlays[key] == nil {
                migratedOverlays[key] = legacy
            }
            migratedConfigurations[index].clearLegacyWeatherOverlay()
        }
        guard migratedConfigurations != configurations else { return nil }
        return (migratedConfigurations, migratedOverlays)
    }
}

public extension ScreenConfiguration {
    /// The weather values an older build stored here; read only to migrate them.
    var legacyWeatherOverlay: WeatherOverlayConfiguration {
        WeatherOverlayConfiguration(
            particleEffect: particleEffect,
            weatherReactive: effectConfig.weatherReactive,
            particleDensity: effectConfig.particleDensity,
            weatherWind: effectConfig.weatherWind,
            weatherIntensity: effectConfig.weatherIntensity
        )
    }

    mutating func clearLegacyWeatherOverlay() {
        particleEffect = .none
        effectConfig = effectConfig.withoutWeatherOverlay
    }
}

public extension VideoEffectConfig {
    /// This config with the weather fields at their defaults; those now live in `WeatherOverlayConfiguration`.
    var withoutWeatherOverlay: VideoEffectConfig {
        var copy = self
        copy.weatherReactive = false
        copy.weatherWind = false
        copy.weatherIntensity = true
        copy.particleDensity = 1.0
        return copy
    }
}
