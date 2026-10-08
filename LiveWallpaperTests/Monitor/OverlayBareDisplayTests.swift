import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Overlays on a display with no wallpaper", .serialized)
@MainActor
struct OverlayBareDisplayTests {
    @Test("A Weather tile on a bare display is saved and gets a board host")
    func weatherTile() throws {
        try onBareDisplay { manager, screen in
            manager.setMonitorOverlayEnabled(true, for: screen)
            manager.setMonitorOverlayBoard(
                MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .weather, size: .medium)]),
                for: screen
            )
            manager.reconcileMonitorOverlays()

            let saved = SettingsManager.shared.loadMonitorOverlays()[screen.displayFingerprint]
            #expect(saved?.enabled == true)
            #expect(saved?.board.widgets.map(\.kind) == [.weather])
            #expect(OverlayController.shared.board(screenID: screen.id, module: .monitor)?.widgets.map(\.kind) == [.weather])
        }
    }

    @Test("A clock on a bare display is saved and gets a clock host")
    func clock() throws {
        try onBareDisplay { manager, screen in
            var clock = manager.monitorOverlay(for: screen).clock
            clock.enabled = true
            manager.setClockOverlay(clock, for: screen)
            manager.reconcileMonitorOverlays()

            #expect(SettingsManager.shared.loadMonitorOverlays()[screen.displayFingerprint]?.clock.enabled == true)
            #expect(OverlayController.shared.debugWindow(screenID: screen.id, module: .clock) != nil)
        }
    }

    @Test("A music layer on a bare display is saved and gets a music host")
    func music() throws {
        try onBareDisplay { manager, screen in
            manager.setMusicOverlayEnabled(true, for: screen)
            manager.reconcileMonitorOverlays()

            #expect(SettingsManager.shared.loadMonitorOverlays()[screen.displayFingerprint]?.music.enabled == true)
            #expect(OverlayController.shared.music(screenID: screen.id) != nil)
        }
    }

    @Test("A weather layer on a bare display is saved, gets a particle host, and outlives a cleared wallpaper")
    func weatherLayer() throws {
        try onBareDisplay { manager, screen in
            let previous = SettingsManager.shared.loadWeatherOverlays()
            defer {
                SettingsManager.shared.saveWeatherOverlays(previous)
                manager.weatherOverlays = previous
            }
            manager.updateParticleEffect(.rain, for: screen)
            manager.updateParticleDensity(2, for: screen)

            let saved = SettingsManager.shared.loadWeatherOverlays()[screen.displayFingerprint]
            #expect(saved?.particleEffect == .rain)
            #expect(saved?.particleDensity == 2)
            let hosted = manager.effectsCoordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id) != nil
            #expect(hosted, "no particle host was built for the bare display")

            manager.clearWallpaperForScreen(screen)
            manager.effectsCoordinator.reconcileEnvironmentOverlays()
            let kept = SettingsManager.shared.loadWeatherOverlays()[screen.displayFingerprint]?.particleEffect
            #expect(kept == .rain)
            let stillHosted = manager.effectsCoordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id) != nil
            #expect(stillHosted, "clearing the wallpaper took the weather layer down")
        }
    }

    private func onBareDisplay(_ body: (ScreenManager, Screen) throws -> Void) throws {
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
        let saved = manager.monitorOverlay(for: screen)
        defer {
            manager.setMonitorOverlay(saved, for: screen)
            OverlayController.shared.teardown(screenID: screen.id)
            manager.tearDownForTermination()
        }
        try #require(manager.getConfiguration(for: screen) == nil, "the display must have no wallpaper configuration")
        try #require(manager.wallpapersGloballyEnabled)
        try body(manager, screen)
    }
}
