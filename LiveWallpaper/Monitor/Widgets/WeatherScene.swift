import Foundation

/// Everything the Weather tile draws, decided once from the weather service's
/// state so the drawing code carries no weather logic of its own. Pure, so the
/// mapping from sky to picture is testable without rendering a pixel.
struct WeatherScene: Equatable {
    enum Precipitation: Equatable {
        case none
        case rain
        case snow
    }

    /// How often the canvas must redraw for what is in it.
    enum Motion: Equatable {
        /// Nothing moves (a clear day): draw once.
        case still
        /// Clouds, fog, twinkling stars: a few frames a second is plenty.
        case drifting
        /// Rain, snow, lightning.
        case falling
    }

    /// An OKLCH colour, kept as numbers so the model stays free of SwiftUI.
    struct SkyStop: Equatable {
        var l: Double
        var c: Double
        var h: Double
    }

    var isDaylight: Bool
    var skyTop: SkyStop
    var skyBottom: SkyStop
    /// 0…1 of the sky that is cloud; drives how many blobs and how opaque.
    var cloudCover: Double
    /// 0 = charcoal storm cloud, 1 = white fair-weather cloud.
    var cloudBrightness: Double
    var precipitation: Precipitation
    /// 0…1 relative to the heaviest fall the tile draws.
    var precipitationRate: Double
    /// 0…1 fog density.
    var fog: Double
    var stars: Bool
    var sun: Bool
    var moon: Bool
    var lightning: Bool
    /// Radians from vertical, positive to the right of the screen. The same
    /// wind policy the full-screen particles use, so the tile and the desktop
    /// behind it never disagree about which way it is blowing.
    var lean: Double
    /// 0…1 wind strength, for cloud drift speed.
    var wind: Double

    var motion: Motion {
        if precipitation != .none || lightning {
            return .falling
        }
        if cloudCover > 0 || fog > 0 || stars {
            return .drifting
        }
        return .still
    }

    // MARK: - Sky → scene

    static func make(
        condition: WeatherReactiveService.WeatherDescription,
        isDaylight: Bool?,
        intensity: WeatherIntensity,
        wind: WeatherReactiveService.WeatherWind?
    ) -> WeatherScene {
        let day = isDaylight ?? true
        let sky = palette(for: condition, day: day)
        var scene = WeatherScene(
            isDaylight: day, skyTop: sky.top, skyBottom: sky.bottom,
            cloudCover: 0, cloudBrightness: day ? 1 : 0.6,
            precipitation: .none, precipitationRate: 0, fog: 0,
            stars: false, sun: false, moon: false, lightning: false,
            lean: 0, wind: 0
        )

        switch condition {
        case .clear:
            scene.sun = day
            scene.moon = !day
            scene.stars = !day
        case .partlyCloudy:
            scene.cloudCover = 0.45
            scene.sun = day
            scene.moon = !day
            scene.stars = !day
        case .cloudy:
            scene.cloudCover = 0.9
            scene.cloudBrightness = day ? 0.75 : 0.45
        case .foggy:
            scene.fog = 1
            scene.cloudCover = 0.3
        case .drizzle:
            scene.cloudCover = 0.8
            scene.cloudBrightness = day ? 0.6 : 0.4
            scene.precipitation = .rain
            scene.precipitationRate = 0.3
        case .rain:
            scene.cloudCover = 0.95
            scene.cloudBrightness = day ? 0.5 : 0.35
            scene.precipitation = .rain
            scene.precipitationRate = 0.6
        case .heavyRain:
            scene.cloudCover = 1
            scene.cloudBrightness = day ? 0.4 : 0.3
            scene.precipitation = .rain
            scene.precipitationRate = 1
        case .snow:
            scene.cloudCover = 0.8
            scene.cloudBrightness = day ? 0.85 : 0.5
            scene.precipitation = .snow
            scene.precipitationRate = 0.5
        case .heavySnow:
            scene.cloudCover = 0.95
            scene.cloudBrightness = day ? 0.8 : 0.45
            scene.precipitation = .snow
            scene.precipitationRate = 1
        case .thunderstorm:
            scene.cloudCover = 1
            scene.cloudBrightness = 0.25
            scene.precipitation = .rain
            scene.precipitationRate = 0.9
            scene.lightning = true
        case .unknown:
            scene.cloudCover = 0.5
        }

        // WMO intensity refines the description (51/53/55 are three drizzles), the
        // way it scales the full-screen particles; clamped so heavy stays drawable.
        if scene.precipitation != .none {
            scene.precipitationRate = min(1, max(0.15, scene.precipitationRate * intensity.densityMultiplier))
        }

        if let wind {
            let fallSpeed = scene.precipitation == .snow
                ? WeatherWindPolicy.FallSpeed.snow : WeatherWindPolicy.FallSpeed.rain
            scene.lean = WeatherWindPolicy.tiltRadians(windSpeedKPH: wind.speedKPH, fallSpeedMPS: fallSpeed)
                * WeatherWindPolicy.horizontalBias(fromDegrees: wind.fromDegrees)
            scene.wind = min(1, max(0, wind.speedKPH / 60))
        }
        return scene
    }

    /// Sky gradient per condition, day and night. Night is the same hue family
    /// pulled down in lightness, so the tile reads as one place at two hours
    /// rather than as two palettes.
    private static func palette(
        for condition: WeatherReactiveService.WeatherDescription, day: Bool
    ) -> (top: SkyStop, bottom: SkyStop) {
        func stops(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (SkyStop, SkyStop) {
            (SkyStop(l: a.0, c: a.1, h: a.2), SkyStop(l: b.0, c: b.1, h: b.2))
        }
        switch condition {
        case .clear:
            return day ? stops((0.60, 0.13, 250), (0.84, 0.07, 225))
                : stops((0.17, 0.05, 270), (0.29, 0.07, 280))
        case .partlyCloudy:
            return day ? stops((0.64, 0.10, 245), (0.83, 0.05, 230))
                : stops((0.19, 0.04, 265), (0.30, 0.05, 275))
        case .cloudy, .unknown:
            return day ? stops((0.58, 0.025, 240), (0.72, 0.02, 235))
                : stops((0.21, 0.02, 255), (0.29, 0.02, 260))
        case .foggy:
            return day ? stops((0.70, 0.012, 230), (0.78, 0.01, 230))
                : stops((0.29, 0.012, 250), (0.35, 0.01, 250))
        case .drizzle, .rain:
            return day ? stops((0.48, 0.035, 245), (0.62, 0.03, 240))
                : stops((0.19, 0.03, 255), (0.27, 0.03, 260))
        case .heavyRain:
            return day ? stops((0.40, 0.035, 250), (0.54, 0.03, 245))
                : stops((0.16, 0.03, 255), (0.24, 0.03, 260))
        case .snow:
            return day ? stops((0.72, 0.02, 235), (0.85, 0.015, 230))
                : stops((0.29, 0.03, 260), (0.39, 0.03, 265))
        case .heavySnow:
            return day ? stops((0.66, 0.02, 235), (0.80, 0.015, 230))
                : stops((0.26, 0.03, 260), (0.36, 0.03, 265))
        case .thunderstorm:
            return day ? stops((0.28, 0.04, 275), (0.40, 0.04, 265))
                : stops((0.13, 0.04, 275), (0.21, 0.04, 270))
        }
    }
}
