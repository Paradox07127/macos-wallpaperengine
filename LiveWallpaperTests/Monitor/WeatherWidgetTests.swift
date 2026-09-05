import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Weather widget")
struct WeatherWidgetTests {
    private typealias Condition = WeatherReactiveService.WeatherDescription

    private func scene(
        _ condition: Condition, day: Bool? = true,
        intensity: WeatherIntensity = .moderate,
        wind: WeatherReactiveService.WeatherWind? = nil
    ) -> WeatherScene {
        WeatherScene.make(condition: condition, isDaylight: day, intensity: intensity, wind: wind)
    }

    @Test("Each condition draws the sky it names")
    func conditionsMapToSceneElements() {
        let clearDay = scene(.clear)
        #expect(clearDay.sun && !clearDay.moon && !clearDay.stars && clearDay.cloudCover == 0)
        #expect(clearDay.motion == .still, "a clear day has nothing to animate")

        let clearNight = scene(.clear, day: false)
        #expect(clearNight.moon && clearNight.stars && !clearNight.sun)

        let rain = scene(.rain)
        #expect(rain.precipitation == .rain && rain.precipitationRate > 0)
        #expect(rain.cloudCover >= 0.7 && !rain.sun)
        #expect(rain.motion == .falling)

        let snow = scene(.snow)
        #expect(snow.precipitation == .snow)

        let storm = scene(.thunderstorm)
        #expect(storm.lightning && storm.precipitation == .rain)

        let fog = scene(.foggy)
        #expect(fog.fog > 0 && fog.precipitation == .none)

        #expect(scene(.cloudy).motion == .drifting)
    }

    @Test("Heavier descriptions and heavier WMO intensity both fall harder")
    func precipitationRateFollowsIntensity() {
        #expect(scene(.drizzle).precipitationRate < scene(.rain).precipitationRate)
        #expect(scene(.rain).precipitationRate < scene(.heavyRain).precipitationRate)
        #expect(scene(.rain, intensity: .light).precipitationRate < scene(.rain, intensity: .heavy).precipitationRate)
        #expect(scene(.heavyRain, intensity: .heavy).precipitationRate <= 1)
    }

    @Test("Night is the same sky, darker")
    func nightIsDarkerThanDay() {
        for condition in [Condition.clear, .partlyCloudy, .cloudy, .foggy, .rain, .snow, .thunderstorm] {
            let day = scene(condition, day: true), night = scene(condition, day: false)
            #expect(night.skyTop.l < day.skyTop.l, "\(condition)")
            #expect(night.skyBottom.l < day.skyBottom.l, "\(condition)")
        }
    }

    /// The tile and the full-screen particles read the same wind through the
    /// same policy, so a westerly leans both to the right by the same angle.
    @Test("Rain leans with the wind exactly as the desktop particles do")
    func leanMatchesTheParticlePolicy() {
        let westerly = WeatherReactiveService.WeatherWind(speedKPH: 40, gustKPH: nil, fromDegrees: 270)
        let easterly = WeatherReactiveService.WeatherWind(speedKPH: 40, gustKPH: nil, fromDegrees: 90)
        let expected = WeatherWindPolicy.tiltRadians(windSpeedKPH: 40, fallSpeedMPS: WeatherWindPolicy.FallSpeed.rain)
        #expect(abs(scene(.rain, wind: westerly).lean - expected) < 1e-9)
        #expect(abs(scene(.rain, wind: easterly).lean + expected) < 1e-9)
        #expect(scene(.rain).lean == 0, "no wind reading, no lean")
        // Snow leans further than rain in the same wind, as it does outside.
        #expect(scene(.snow, wind: westerly).lean > scene(.rain, wind: westerly).lean)
    }

    @Test("Lightning strikes are rare, brief and repeatable")
    func lightningIsSparseAndDeterministic() {
        let period = WeatherScenePainter.lightningPeriod
        var litSeconds = 0.0
        let step = 0.01
        for tick in stride(from: 0.0, to: period * 10, by: step)
            where WeatherScenePainter.lightningFlash(at: tick).brightness > 0.05 {
            litSeconds += step
        }
        // Two pulses of ~0.1 s each per strike, ten strikes: well under a tenth of the time lit.
        #expect(litSeconds > 0, "no strike ever fired")
        #expect(litSeconds < period, "the sky is lit \(litSeconds)s out of \(period * 10)s")
        #expect(WeatherScenePainter.lightningFlash(at: 12.34) == WeatherScenePainter.lightningFlash(at: 12.34))
    }

    @Test("Particle constants are stable per index and spread over 0..<1")
    func unitHashIsStableAndSpread() throws {
        let values = (0 ..< 500).map { WeatherScenePainter.unit($0, 7) }
        #expect(values == (0 ..< 500).map { WeatherScenePainter.unit($0, 7) })
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(try #require(values.min()) < 0.05 && values.max()! > 0.95)
        #expect(WeatherScenePainter.unit(3, 1) != WeatherScenePainter.unit(3, 2), "salt tells purposes apart")
    }

    @Test("Caption shows by default and hides on request")
    func captionOption() {
        let placement = MonitorWidgetPlacement(kind: .weather)
        #expect(WeatherWidgetOptions.showsCaption(placement))
        let hidden = MonitorWidgetDraft.settingBool(
            false, key: WeatherWidgetOptions.showCaptionKey,
            default: WeatherWidgetOptions.showCaptionDefault, on: placement
        )
        #expect(!WeatherWidgetOptions.showsCaption(hidden))
    }

    @Test("A weather-only board runs no system sampler")
    func weatherDemandsNoSystemMetrics() {
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: [.weather]))
        #expect(MonitorSampleDemand.of([MonitorWidgetPlacement(kind: .weather, size: .large)]) == MonitorSampleDemand())
    }

    @Test("A placed weather tile earns the forecast fetch by itself")
    func weatherWidgetKeepsMonitoringOn() {
        #expect(WeatherReactivePolicy.shouldMonitor(configurations: [], activeScreenIDs: [], weatherWidgetPlaced: true))
        #expect(!WeatherReactivePolicy.shouldMonitor(configurations: [], activeScreenIDs: [], weatherWidgetPlaced: false))
    }

    @MainActor
    @Test("The tile is added at medium, where the sky has room")
    func defaultSizeIsMedium() {
        #expect(InteractionModel.defaultSize(for: .weather) == .medium)
    }
}
