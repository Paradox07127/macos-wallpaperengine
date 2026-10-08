import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Weather layer moves out of display configurations")
@MainActor
struct WeatherOverlayMigrationTests {
    private static let migrated = WeatherOverlayConfiguration(
        particleEffect: .snow, weatherReactive: true, particleDensity: 1.8, weatherWind: true, weatherIntensity: false
    )

    private static func legacyConfiguration() -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        configuration.displayFingerprint = "fp-11"
        configuration.particleEffect = .snow
        configuration.effectConfig.weatherReactive = true
        configuration.effectConfig.particleDensity = 1.8
        configuration.effectConfig.weatherWind = true
        configuration.effectConfig.weatherIntensity = false
        configuration.effectConfig.warmth = 5200
        return configuration
    }

    @Test("Loading an older configuration moves its weather values once, and a later edit survives the next load")
    func migratesOnce() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.WeatherMigration")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WeatherMigration-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let seed = SettingsManager(directory: directory, defaults: defaults.defaults)
        seed.replaceAllConfigurations([Self.legacyConfiguration()])
        #expect(await seed.flushPendingWrites())

        let first = SettingsManager(directory: directory, defaults: defaults.defaults)
        let firstOverlays = first.loadWeatherOverlays()
        #expect(firstOverlays == ["fp-11": Self.migrated])
        let firstConfiguration = try #require(first.loadConfigurations().first)
        #expect(firstConfiguration.legacyWeatherOverlay == .default)
        #expect(firstConfiguration.effectConfig.warmth == 5200, "a video effect went along with the weather")
        var edited = Self.migrated
        edited.particleEffect = .rain
        first.saveWeatherOverlays(["fp-11": edited])
        #expect(await first.flushPendingWrites())

        let second = SettingsManager(directory: directory, defaults: defaults.defaults)
        let secondOverlays = second.loadWeatherOverlays()
        #expect(secondOverlays == ["fp-11": edited])

        await TestScratch.discard(root, flushing: seed, first, second)
        defaults.discard()
    }

    @Test("An existing weather layer is never overwritten by values still left on a configuration")
    func existingEntryWins() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.WeatherMigration")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WeatherMigration-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let seed = SettingsManager(directory: directory, defaults: defaults.defaults)
        let kept = WeatherOverlayConfiguration(particleEffect: .sakura)
        seed.saveWeatherOverlays(["fp-11": kept])
        seed.replaceAllConfigurations([Self.legacyConfiguration()])
        #expect(await seed.flushPendingWrites())

        let reloaded = SettingsManager(directory: directory, defaults: defaults.defaults)
        let overlays = reloaded.loadWeatherOverlays()
        #expect(overlays == ["fp-11": kept])
        let configuration = try #require(reloaded.loadConfigurations().first)
        #expect(configuration.legacyWeatherOverlay == .default, "the stale copy stayed on the configuration")

        await TestScratch.discard(root, flushing: seed, reloaded)
        defaults.discard()
    }

    @Test("Applying a bookmark that still carries weather values leaves the display's weather layer alone")
    func legacyBookmarkLeavesWeather() throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro),
            originReconciler: PreservingOriginReconciler()
        ))
        let previousConfiguration = manager.getConfiguration(for: screen)
        let previousWeather = SettingsManager.shared.loadWeatherOverlays()
        defer {
            SettingsManager.shared.saveWeatherOverlays(previousWeather)
            if let previousConfiguration {
                manager.saveConfiguration(previousConfiguration)
            } else {
                SettingsManager.shared.cleanSettingsForScreen(screen.id)
            }
            manager.tearDownForTermination()
        }
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([0x01])))
        configuration.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(configuration)
        let layer = WeatherOverlayConfiguration(particleEffect: .rain, particleDensity: 0.6)
        manager.weatherOverlays[screen.displayFingerprint] = layer

        var legacyEffects = VideoEffectConfig()
        legacyEffects.weatherReactive = true
        let bookmark = WallpaperBookmark(
            label: "Old",
            content: .video(bookmarkData: Data([0x02]), packageEntryName: nil),
            playbackSettings: BookmarkPlaybackSettings(particleEffect: .snow, effectConfig: legacyEffects)
        )
        manager.applyBookmark(bookmark, to: screen)

        let after = manager.weatherOverlay(for: screen)
        #expect(after == layer)
        let legacyAfter = manager.getConfiguration(for: screen)?.legacyWeatherOverlay
        #expect(legacyAfter == .default)
    }
}
