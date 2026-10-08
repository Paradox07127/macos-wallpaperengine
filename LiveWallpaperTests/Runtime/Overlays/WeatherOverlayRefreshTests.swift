import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Weather layer refresh after display and batch changes", .serialized)
@MainActor
struct WeatherOverlayRefreshTests {
    @Test("A hand-picked particle layer on a display with no wallpaper comes back when the display does")
    func manualLayerReturnsWithBareDisplay() throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        var live = [screen]
        let coordinator = WallpaperEffectsCoordinator(
            configurationStore: WallpaperConfigurationStore(persistence: ScreenManagerFixtureState()),
            screensProvider: { live },
            saveConfiguration: { _ in },
            weatherOverlay: { _ in WeatherOverlayConfiguration(particleEffect: .snow) },
            saveWeatherOverlay: { _, _ in },
            applyFrameRateLimit: { _, _ in },
            screenRefreshRate: { _ in 60 }
        )
        defer { coordinator.shutdown() }

        coordinator.reconcileEnvironmentOverlays()
        live = []
        coordinator.screensDidChange(arrivedScreenIDs: [])
        let removed = coordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id) == nil
        try #require(removed, "the layer outlived its display")

        live = [screen]
        coordinator.screensDidChange(arrivedScreenIDs: [screen.id])
        let hosted = coordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id) != nil
        #expect(hosted, "the returning display got no particle host")
    }

    @Test("Turning weather-reactive off from outside puts the saved video effects back")
    func batchReactiveOffRestoresSavedEffects() throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/weather-overlay-refresh.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: player))
        defer { screen.resetRuntimeSession() }

        let store = WallpaperConfigurationStore(persistence: ScreenManagerFixtureState())
        var saved = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data())
        saved.displayFingerprint = screen.displayFingerprint
        saved.frameRateLimit = .fps15
        store.save(saved)
        var overlay = WeatherOverlayConfiguration(weatherReactive: true)
        var appliedLimits: [FrameRateLimit] = []
        let coordinator = WallpaperEffectsCoordinator(
            configurationStore: store,
            screensProvider: { [screen] },
            saveConfiguration: { _ in },
            weatherOverlay: { _ in overlay },
            saveWeatherOverlay: { _, _ in },
            applyFrameRateLimit: { limit, _ in appliedLimits.append(limit) },
            screenRefreshRate: { _ in 60 }
        )
        defer { coordinator.shutdown() }

        coordinator.weatherOverlaysDidChange()
        appliedLimits = []
        overlay.weatherReactive = false
        coordinator.weatherOverlaysDidChange()

        #expect(appliedLimits == [.fps15], "the saved configuration was not re-applied to the video")
    }
}
