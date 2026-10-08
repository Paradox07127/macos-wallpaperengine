import AppKit
import Foundation
import LiveWallpaperCore
import Observation

@MainActor
final class WallpaperEffectsCoordinator {
    let weatherService: WeatherReactiveService
    private let videoEffectsApplier: VideoEffectsApplicationService
    private let environmentOverlay = EnvironmentOverlayController()

    private let configurationStore: WallpaperConfigurationStore
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let weatherOverlay: @MainActor (Screen) -> WeatherOverlayConfiguration
    private let saveWeatherOverlay: @MainActor (WeatherOverlayConfiguration, Screen) -> Void
    private let applyFrameRateLimit: @MainActor (FrameRateLimit, Screen) -> Void
    private let screenRefreshRate: @MainActor (CGDirectDisplayID) -> Int
    private let isScreenSuspended: @MainActor (CGDirectDisplayID) -> Bool
    /// Whether a live Monitor board shows a Weather tile — the fetch's other consumer.
    private let weatherWidgetPlaced: @MainActor () -> Bool
    /// The master render gate. Particles do not need a wallpaper, but they do obey this.
    private let isGloballyEnabled: @MainActor () -> Bool

    /// Bumped per weather observe registration; stale generation short-circuits stacked callbacks.
    private var weatherTrackingGeneration: UInt64 = 0
    private(set) var isShutdown = false

    init(
        weatherService: WeatherReactiveService = WeatherReactiveService(),
        videoEffectsApplier: VideoEffectsApplicationService = VideoEffectsApplicationService(),
        configurationStore: WallpaperConfigurationStore,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        weatherOverlay: @MainActor @escaping (Screen) -> WeatherOverlayConfiguration,
        saveWeatherOverlay: @MainActor @escaping (WeatherOverlayConfiguration, Screen) -> Void,
        applyFrameRateLimit: @MainActor @escaping (FrameRateLimit, Screen) -> Void,
        screenRefreshRate: @MainActor @escaping (CGDirectDisplayID) -> Int,
        isScreenSuspended: @MainActor @escaping (CGDirectDisplayID) -> Bool = { _ in false },
        weatherWidgetPlaced: @MainActor @escaping () -> Bool = { false },
        isGloballyEnabled: @MainActor @escaping () -> Bool = { true }
    ) {
        self.weatherService = weatherService
        self.videoEffectsApplier = videoEffectsApplier
        self.configurationStore = configurationStore
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.weatherOverlay = weatherOverlay
        self.saveWeatherOverlay = saveWeatherOverlay
        self.applyFrameRateLimit = applyFrameRateLimit
        self.screenRefreshRate = screenRefreshRate
        self.isScreenSuspended = isScreenSuspended
        self.weatherWidgetPlaced = weatherWidgetPlaced
        self.isGloballyEnabled = isGloballyEnabled
    }

    // MARK: - Public API (called from ScreenManager facade)

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard !isShutdown else { return }
        let effectConfig = effectConfig.withoutWeatherOverlay
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig != effectConfig else { return }
        config.effectConfig = effectConfig
        saveConfiguration(config)
        applyVideoEffects(for: screen, config: config)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        updateWeatherOverlay(for: screen) { overlay in
            guard overlay.particleEffect != effect else { return false }
            overlay.particleEffect = effect
            return true
        }
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        let clamped = min(max(density, 0.2), 3.0)
        updateWeatherOverlay(for: screen) { overlay in
            guard abs(clamped - overlay.particleDensity) > 0.001 else { return false }
            overlay.particleDensity = clamped
            return true
        }
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        updateWeatherOverlay(for: screen) { overlay in
            guard overlay.weatherReactive != enabled else { return false }
            overlay.weatherReactive = enabled
            return true
        }
        guard !isShutdown, !enabled,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperType == .video else { return }
        // Drops the weather tint `applyWeatherEffects` put on the video.
        applyVideoEffects(for: screen, config: config)
    }

    func setWeatherWind(_ enabled: Bool, for screen: Screen) {
        updateWeatherOverlay(for: screen) { overlay in
            guard overlay.weatherWind != enabled else { return false }
            overlay.weatherWind = enabled
            return true
        }
    }

    /// Whether the reported downpour/flurry strength scales the density.
    func setWeatherIntensity(_ enabled: Bool, for screen: Screen) {
        updateWeatherOverlay(for: screen) { overlay in
            guard overlay.weatherIntensity != enabled else { return false }
            overlay.weatherIntensity = enabled
            return true
        }
    }

    private func updateWeatherOverlay(
        for screen: Screen, mutate: (inout WeatherOverlayConfiguration) -> Bool
    ) {
        guard !isShutdown else { return }
        var overlay = weatherOverlay(screen)
        guard mutate(&overlay) else { return }
        saveWeatherOverlay(overlay, screen)
        refreshWeatherMonitoringState()
        applyParticles(overlay, to: screen)
        applyWeatherEffects(for: screen)
    }

    func applyWeatherEffects(for screen: Screen) {
        guard !isShutdown else { return }
        let overlay = weatherOverlay(screen)
        guard overlay.weatherReactive else { return }
        applyParticles(overlay, to: screen)

        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperType == .video else { return }
        let adj = weatherService.currentEffectAdjustments
        var updatedConfig = config
        updatedConfig.effectConfig.saturation = adj.saturation
        updatedConfig.effectConfig.brightness = adj.brightness
        updatedConfig.effectConfig.warmth = adj.warmth
        updatedConfig.effectConfig.blurRadius = adj.blurRadius
        updatedConfig.effectConfig.vignetteIntensity = adj.vignetteIntensity
        applyVideoEffects(for: screen, config: updatedConfig)
    }

    func screensDidChange(arrivedScreenIDs: Set<CGDirectDisplayID>) {
        guard !isShutdown else { return }
        environmentOverlay.retainOnly(Set(screensProvider().map(\.id)))
        refreshWeatherMonitoringState()
        for screen in screensProvider() where arrivedScreenIDs.contains(screen.id) {
            applyWeatherEffects(for: screen)
        }
    }

    /// Re-reads every display's weather layer after it changed outside this coordinator.
    func weatherOverlaysDidChange() {
        guard !isShutdown else { return }
        refreshWeatherMonitoringState()
        reconcileEnvironmentOverlays()
        for screen in screensProvider() {
            applyWeatherEffects(for: screen)
        }
    }

    func startWeatherMonitoring() {
        guard !isShutdown else { return }
        observeWeatherChanges()
        refreshWeatherMonitoringState()
        reconcileEnvironmentOverlays()
    }

    func globalRenderGateDidChange() {
        refreshWeatherMonitoringState()
        reconcileEnvironmentOverlays()
    }

    func monitorBoardsDidChange() {
        guard !isShutdown else { return }
        refreshWeatherMonitoringState()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        weatherTrackingGeneration &+= 1
        weatherService.shutdown()
        videoEffectsApplier.retireAllWork()
        environmentOverlay.teardownAll()
    }

    func applyVideoEffects(for screen: Screen, config: ScreenConfiguration) {
        guard !isShutdown else { return }
        guard let player = screen.videoPlayer else {
            Logger.warning("Cannot apply effects: no active player for screen \(screen.id)", category: .videoPlayer)
            return
        }

        videoEffectsApplier.applyEffects(
            to: player,
            screenID: screen.id,
            config: config,
            screenRefreshRate: screenRefreshRate(screen.id),
            noEffectsHandler: { [weak self, weak screen] in
                guard let self, let screen else { return }
                self.applyFrameRateLimit(config.frameRateLimit, screen)
            }
        )
    }

    func prepareVideoEffects(
        for player: WallpaperVideoPlayer,
        screen: Screen,
        config: ScreenConfiguration
    ) async -> Bool {
        guard !isShutdown else { return false }
        let screenID = screen.id
        return await videoEffectsApplier.prepareEffects(
            to: player,
            screenID: screenID,
            config: config,
            screenRefreshRate: screenRefreshRate(screenID),
            noEffectsHandler: { [weak self, weak player] in
                guard let self, let player else { return }
                self.applyFrameRateLimit(
                    config.frameRateLimit,
                    to: player,
                    screenID: screenID
                )
            }
        )
    }

    func retireWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) {
        videoEffectsApplier.retireWork(for: screenID, player: player)
    }

    func retireAllWork(for screenID: CGDirectDisplayID) {
        videoEffectsApplier.retireAllWork(for: screenID)
    }

    #if DEBUG
    func trackedWorkKeyCount(for screenID: CGDirectDisplayID) -> Int {
        videoEffectsApplier.trackedWorkKeyCount(for: screenID)
    }

    var debugEnvironmentOverlay: EnvironmentOverlayController {
        environmentOverlay
    }
    #endif

    func workRevision(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> UInt64 {
        videoEffectsApplier.workRevision(for: screenID, player: player)
    }

    func hasActiveWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> Bool {
        videoEffectsApplier.hasActiveWork(for: screenID, player: player)
    }

    func reconcileEnvironmentOverlays() {
        guard !isShutdown else { return }
        let screens = screensProvider()
        environmentOverlay.retainOnly(Set(screens.map(\.id)))
        for screen in screens {
            applyParticles(weatherOverlay(screen), to: screen)
        }
    }

    /// Moves an already-live environment overlay to `frame` (resolution/arrangement
    /// change) without rebuilding the emitter — see `EnvironmentOverlayController.updateFrame`.
    func updateEnvironmentOverlayFrame(for screen: Screen, frame: CGRect) {
        environmentOverlay.updateFrame(screenID: screen.id, frame: frame)
    }

    func setEnvironmentOverlaySuspended(_ suspended: Bool, for screen: Screen) {
        environmentOverlay.setRuntimeSuspended(suspended, screenID: screen.id)
    }

    func applyCapturePolicyToEnvironmentOverlays(_ sharing: NSWindow.SharingType) {
        environmentOverlay.applyCapturePolicy(sharing)
    }

    // MARK: - Private helpers

    private func applyFrameRateLimit(
        _ frameRateLimit: FrameRateLimit,
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID
    ) {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: frameRateLimit,
            screenRefreshRate: Double(screenRefreshRate(screenID))
        )
        player.setFrameRateLimit(limit ?? 0)
    }

    private func applyParticles(_ overlay: WeatherOverlayConfiguration, to screen: Screen) {
        let effect = WeatherReactivePolicy.resolvedParticleEffect(
            chosen: overlay.particleEffect,
            weatherReactive: overlay.weatherReactive,
            weatherEffect: weatherService.currentParticleEffect
        )
        let density = WeatherReactivePolicy.resolvedParticleDensity(
            userDensity: overlay.particleDensity,
            weatherReactive: overlay.weatherReactive,
            intensity: weatherService.currentIntensity,
            intensityEnabled: overlay.weatherIntensity
        )
        applyParticleEffect(effect, density: density, tiltRadians: windTilt(for: effect, overlay: overlay), to: screen)
    }

    /// Zero unless the display is weather-reactive, the user asked for wind, and the API sent a reading — a hand-picked snow effect should not blow sideways because it is gusty outside.
    private func windTilt(for effect: ParticleEffect, overlay: WeatherOverlayConfiguration) -> Double {
        guard overlay.weatherReactive, overlay.weatherWind,
              effect.leansIntoWind,
              let wind = weatherService.currentWind else { return 0 }
        let fallSpeed: Double
        switch effect {
        case .rain:                       fallSpeed = WeatherWindPolicy.FallSpeed.rain
        case .snow, .fallingLeaves, .sakura: fallSpeed = WeatherWindPolicy.FallSpeed.snow
        default:                          fallSpeed = WeatherWindPolicy.FallSpeed.dust
        }
        let magnitude = WeatherWindPolicy.tiltRadians(
            windSpeedKPH: wind.speedKPH, fallSpeedMPS: fallSpeed
        )
        return magnitude * WeatherWindPolicy.horizontalBias(fromDegrees: wind.fromDegrees)
    }

    private func applyParticleEffect(
        _ effect: ParticleEffect, density: Double, tiltRadians: Double, to screen: Screen
    ) {
        guard WeatherReactivePolicy.shouldDrawParticles(
            effect: effect, wallpapersEnabled: isGloballyEnabled()
        ) else {
            environmentOverlay.teardown(screenID: screen.id)
            return
        }
        let frame = screen.nsScreen.frame
        environmentOverlay.apply(
            effect: effect,
            density: density,
            tiltRadians: tiltRadians,
            screenID: screen.id,
            screenFrame: frame
        )
        environmentOverlay.setRuntimeSuspended(isScreenSuspended(screen.id), screenID: screen.id)
    }

    private func refreshWeatherMonitoringState() {
        guard !isShutdown else { return }
        if WeatherReactivePolicy.shouldMonitor(
            overlays: screensProvider().map(weatherOverlay),
            weatherWidgetPlaced: weatherWidgetPlaced(),
            wallpapersEnabled: isGloballyEnabled()
        ) {
            weatherService.startMonitoring()
        } else {
            weatherService.stopMonitoring()
        }
    }

    private func observeWeatherChanges() {
        guard !isShutdown else { return }
        weatherTrackingGeneration &+= 1
        let generation = weatherTrackingGeneration
        withObservationTracking {
            _ = weatherService.currentParticleEffect
            _ = weatherService.currentEffectAdjustments
            _ = weatherService.currentWind
            _ = weatherService.currentIntensity
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isShutdown,
                      self.weatherTrackingGeneration == generation else { return }
                for screen in self.screensProvider() {
                    self.applyWeatherEffects(for: screen)
                }
                self.observeWeatherChanges()
            }
        }
    }
}
