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
}
