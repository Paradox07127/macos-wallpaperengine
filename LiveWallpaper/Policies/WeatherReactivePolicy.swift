import CoreGraphics
import Foundation
import LiveWallpaperCore

enum WeatherReactivePolicy {
    static func shouldMonitor(
        configurations: [ScreenConfiguration],
        activeScreenIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        configurations.contains { configuration in
            activeScreenIDs.contains(configuration.screenID) && configuration.effectConfig.weatherReactive
        }
    }

    /// Which particles a display should actually draw.
    ///
    /// `.none` is the display's master off switch and always wins: weather
    /// chooses *which* particles fall, never *whether* they do. Resolving the
    /// other way round left "Show on This Display" inert for as long as
    /// "Match local weather" was on — the effect picker hid itself and the
    /// snow kept falling until the user found the weather switch.
    static func resolvedParticleEffect(
        chosen: ParticleEffect, weatherReactive: Bool, weatherEffect: ParticleEffect
    ) -> ParticleEffect {
        guard chosen != .none else { return .none }
        return weatherReactive ? weatherEffect : chosen
    }

    /// The density the emitter actually runs at.
    ///
    /// The user's slider is what they want in general; the intensity is what
    /// the sky is doing right now. Multiplying keeps both meaningful — turning
    /// the slider down still calms a downpour — where replacing either one
    /// would throw away the other. Clamped to the slider's own range so weather
    /// can never push the emitter somewhere the user could not have.
    static func resolvedParticleDensity(
        userDensity: Double,
        weatherReactive: Bool,
        intensity: WeatherIntensity,
        range: ClosedRange<Double> = 0.2...3.0
    ) -> Double {
        let base = userDensity.isFinite ? userDensity : 1
        guard weatherReactive else { return min(max(base, range.lowerBound), range.upperBound) }
        let scaled = base * intensity.densityMultiplier
        return min(max(scaled, range.lowerBound), range.upperBound)
    }
}
