import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The effects coordinator is built on first need, so a Weather tile placed
/// after startup must be the thing that builds it — and a board already on the
/// desktop must be handed the sky, since `apply(configuration:)` carries none.
@Suite("Weather tile placed after startup")
struct WeatherTileLateArrivalTests {
    @MainActor
    @Test("Placing the tile builds the coordinator and hands the sky to the overlay controller")
    func placingTheTileBuildsTheServiceLate() throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        #expect(!manager.effectsCoordinatorWasInitialized)

        manager.setMonitorOverlayEnabled(true, for: screen)
        manager.setMonitorOverlayBoard(
            MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .weather, size: .medium)]),
            for: screen
        )
        #expect(manager.effectsCoordinatorWasInitialized, "a Weather tile is the first consumer of the sky")
        #expect(OverlayController.shared.weatherService === manager.weatherService)
    }

    @MainActor
    @Test("A board built without the sky takes it when it arrives")
    func boardTakesTheServiceLate() {
        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: MonitorBoardConfiguration(widgets: [])
        )
        #expect(host.debugWeatherService == nil)
        let service = WeatherReactiveService()
        defer { service.shutdown() }
        host.setWeatherService(service)
        #expect(host.debugWeatherService === service)
    }
}
