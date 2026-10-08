import CoreGraphics
import Foundation
import LiveWallpaperCore

enum WeatherReactivePolicy {
    /// Fetch when a live display's weather layer has particles and weatherReactive, or a Weather tile is placed. Particle switch is master.
    /// `overlays` holds the live displays' layers only.
    static func shouldMonitor(
        overlays: [WeatherOverlayConfiguration],
        weatherWidgetPlaced: Bool = false,
        wallpapersEnabled: Bool = true
    ) -> Bool {
        guard wallpapersEnabled else { return false }
        return weatherWidgetPlaced || overlays.contains { overlay in
            overlay.particleEffect != .none && overlay.weatherReactive
        }
    }

    /// Independent of the wallpaper session; requiring one would hide the overlay when it is the only thing the app draws. Master render gate still applies.
    static func shouldDrawParticles(effect: ParticleEffect, wallpapersEnabled: Bool) -> Bool {
        effect != .none && wallpapersEnabled
    }

    /// .none is the master off switch and always wins: weather chooses which particles fall, never whether they do.
    static func resolvedParticleEffect(
        chosen: ParticleEffect, weatherReactive: Bool, weatherEffect: ParticleEffect
    ) -> ParticleEffect {
        guard chosen != .none else { return .none }
        return weatherReactive ? weatherEffect : chosen
    }

    /// Multiply slider by intensity; replacing either would throw the other away. Clamp to the slider range so weather cannot exceed what the user could set.
    static func resolvedParticleDensity(
        userDensity: Double,
        weatherReactive: Bool,
        intensity: WeatherIntensity,
        intensityEnabled: Bool = true,
        range: ClosedRange<Double> = 0.2...3.0
    ) -> Double {
        let base = userDensity.isFinite ? userDensity : 1
        guard weatherReactive, intensityEnabled else {
            return min(max(base, range.lowerBound), range.upperBound)
        }
        let scaled = base * intensity.densityMultiplier
        return min(max(scaled, range.lowerBound), range.upperBound)
    }
}
