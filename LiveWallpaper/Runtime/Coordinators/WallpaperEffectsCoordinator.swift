import AppKit
import Foundation
import LiveWallpaperCore
import Observation

/// Video CIFilter effects + renderer-independent particle/weather overlay.
@MainActor
final class WallpaperEffectsCoordinator {
    let weatherService: WeatherReactiveService
    private let videoEffectsApplier: VideoEffectsApplicationService
    private let environmentOverlay = EnvironmentOverlayController()

    private let configurationStore: WallpaperConfigurationStore
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let applyFrameRateLimit: @MainActor (FrameRateLimit, Screen) -> Void
    private let screenRefreshRate: @MainActor (CGDirectDisplayID) -> Int
    private let isScreenSuspended: @MainActor (CGDirectDisplayID) -> Bool

    /// Bumped per weather observe registration; stale generation short-circuits stacked callbacks.
    private var weatherTrackingGeneration: UInt64 = 0
    private(set) var isShutdown = false

    init(
        weatherService: WeatherReactiveService = WeatherReactiveService(),
        videoEffectsApplier: VideoEffectsApplicationService = VideoEffectsApplicationService(),
        configurationStore: WallpaperConfigurationStore,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        applyFrameRateLimit: @MainActor @escaping (FrameRateLimit, Screen) -> Void,
        screenRefreshRate: @MainActor @escaping (CGDirectDisplayID) -> Int,
        isScreenSuspended: @MainActor @escaping (CGDirectDisplayID) -> Bool = { _ in false }
    ) {
        self.weatherService = weatherService
        self.videoEffectsApplier = videoEffectsApplier
        self.configurationStore = configurationStore
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.applyFrameRateLimit = applyFrameRateLimit
        self.screenRefreshRate = screenRefreshRate
        self.isScreenSuspended = isScreenSuspended
    }

    // MARK: - Public API (called from ScreenManager facade)

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard !isShutdown else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig != effectConfig else { return }
        config.effectConfig = effectConfig
        saveConfiguration(config)
        applyVideoEffects(for: screen, config: config)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard !isShutdown else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.particleEffect != effect else { return }
        config.particleEffect = effect
        saveConfiguration(config)
        let effect = resolvedParticleEffect(for: config)
        applyParticleEffect(
            effect,
            density: resolvedParticleDensity(for: config),
            tiltRadians: windTilt(for: effect, config: config),
            to: screen
        )
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard !isShutdown else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let clamped = min(max(density, 0.2), 3.0)
        guard abs(clamped - config.effectConfig.particleDensity) > 0.001 else { return }
        config.effectConfig.particleDensity = clamped
        saveConfiguration(config)
        let effect = resolvedParticleEffect(for: config)
        applyParticleEffect(
            effect,
            // Through the shared helper, not a second copy of the rule: the
            // last inline duplicate of this drifted and quietly ignored a
            // switch the user had just flipped.
            density: resolvedParticleDensity(for: config),
            tiltRadians: windTilt(for: effect, config: config),
            to: screen
        )
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard !isShutdown else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig.weatherReactive != enabled else { return }
        config.effectConfig.weatherReactive = enabled
        saveConfiguration(config)
        refreshWeatherMonitoringState()

        if enabled {
            applyWeatherEffects(for: screen)
        } else {
            applyParticleEffect(config.particleEffect, density: config.effectConfig.particleDensity, to: screen)
            if config.wallpaperType == .video {
                applyVideoEffects(for: screen, config: config)
            }
        }
    }

    /// Whether live wind leans the particles on this display.
    func setWeatherWind(_ enabled: Bool, for screen: Screen) {
        updateWeatherOption(for: screen) { config in
            guard config.effectConfig.weatherWind != enabled else { return false }
            config.effectConfig.weatherWind = enabled
            return true
        }
    }

    /// Whether the reported downpour/flurry strength scales the density.
    func setWeatherIntensity(_ enabled: Bool, for screen: Screen) {
        updateWeatherOption(for: screen) { config in
            guard config.effectConfig.weatherIntensity != enabled else { return false }
            config.effectConfig.weatherIntensity = enabled
            return true
        }
    }

    /// Both sub-options only ever matter while "match local weather" is on, and
    /// `applyWeatherEffects` already declines otherwise, so neither needs its
    /// own guard for that.
    private func updateWeatherOption(
        for screen: Screen, mutate: (inout ScreenConfiguration) -> Bool
    ) {
        guard !isShutdown else { return }
        guard var config = configurationStore.get(
            for: screen.id, fingerprint: screen.displayFingerprint
        ) else { return }
        guard mutate(&config) else { return }
        saveConfiguration(config)
        applyWeatherEffects(for: screen)
    }

    func applyWeatherEffects(for screen: Screen) {
        guard !isShutdown else { return }
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig.weatherReactive else { return }

        let effect = resolvedParticleEffect(for: config)
        applyParticleEffect(
            effect,
            density: resolvedParticleDensity(for: config),
            tiltRadians: windTilt(for: effect, config: config),
            to: screen
        )

        let adj = weatherService.currentEffectAdjustments
        var weatherConfig = config.effectConfig
        weatherConfig.saturation = adj.saturation
        weatherConfig.brightness = adj.brightness
        weatherConfig.warmth = adj.warmth
        weatherConfig.blurRadius = adj.blurRadius
        weatherConfig.vignetteIntensity = adj.vignetteIntensity

        if config.wallpaperType == .video {
            var updatedConfig = config
            updatedConfig.effectConfig = weatherConfig
            applyVideoEffects(for: screen, config: updatedConfig)
        }
    }

    /// Displays came or went. The weather poll used to be re-evaluated from exactly two
    /// places — the per-display switch and launch — so unplugging the last weather-reactive
    /// display left the hourly fetch running unrendered, and plugging one in mid-session left
    /// it inert (still holding its launch-time `.none`) until the user toggled the switch by
    /// hand. Only newly-arrived displays get the current weather pushed: this also runs on
    /// resolution/arrangement changes, where rebuilding a live emitter would be churn for no
    /// visible difference.
    func screensDidChange(arrivedScreenIDs: Set<CGDirectDisplayID>) {
        guard !isShutdown else { return }
        refreshWeatherMonitoringState()
        for screen in screensProvider() where arrivedScreenIDs.contains(screen.id) {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  config.effectConfig.weatherReactive else { continue }
            applyWeatherEffects(for: screen)
        }
    }

    func startWeatherMonitoring() {
        guard !isShutdown else { return }
        observeWeatherChanges()
        refreshWeatherMonitoringState()
        reconcileEnvironmentOverlays()
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
    /// Test-only introspection; no production reader.
    func trackedWorkKeyCount(for screenID: CGDirectDisplayID) -> Int {
        videoEffectsApplier.trackedWorkKeyCount(for: screenID)
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
            guard screen.runtimeSession != nil,
                  let config = configurationStore.get(
                    for: screen.id,
                    fingerprint: screen.displayFingerprint
                  ) else {
                environmentOverlay.teardown(screenID: screen.id)
                continue
            }
            let effect = resolvedParticleEffect(for: config)
            applyParticleEffect(
                effect,
                density: resolvedParticleDensity(for: config),
                tiltRadians: windTilt(for: effect, config: config),
                to: screen
            )
        }
    }

    /// Moves an already-live environment overlay to `frame` (resolution/arrangement
    /// change) without rebuilding the emitter — see `EnvironmentOverlayController.updateFrame`.
    func updateEnvironmentOverlayFrame(for screen: Screen, frame: CGRect) {
        environmentOverlay.updateFrame(screenID: screen.id, frame: frame)
    }

    func setEnvironmentOverlaySuspended(_ suspended: Bool, for screen: Screen) {
        environmentOverlay.setSuspended(suspended, screenID: screen.id)
    }

    func removeEnvironmentOverlay(for screen: Screen) {
        environmentOverlay.teardown(screenID: screen.id)
    }

    // MARK: - Private helpers

    private func applyFrameRateLimit(
        _ frameRateLimit: FrameRateLimit,
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID
    ) {
        guard player.videoFrameRate > 0 else { return }
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate(screenID))
        )
        player.setFrameRateLimit(limit ?? 0)
    }

    private func resolvedParticleEffect(for config: ScreenConfiguration) -> ParticleEffect {
        WeatherReactivePolicy.resolvedParticleEffect(
            chosen: config.particleEffect,
            weatherReactive: config.effectConfig.weatherReactive,
            weatherEffect: weatherService.currentParticleEffect
        )
    }

    /// Weather-reactive displays lean on the live intensity; everyone else runs
    /// the slider as set.
    private func resolvedParticleDensity(for config: ScreenConfiguration) -> Double {
        WeatherReactivePolicy.resolvedParticleDensity(
            userDensity: config.effectConfig.particleDensity,
            weatherReactive: config.effectConfig.weatherReactive,
            intensity: weatherService.currentIntensity,
            intensityEnabled: config.effectConfig.weatherIntensity
        )
    }

    /// How far the wind leans this effect on this display. Zero unless the
    /// display is weather-reactive, the user asked for wind, and the API
    /// actually sent a reading — a hand-picked snow effect should not start
    /// blowing sideways because it happens to be gusty outside.
    private func windTilt(for effect: ParticleEffect, config: ScreenConfiguration) -> Double {
        guard config.effectConfig.weatherReactive, config.effectConfig.weatherWind,
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
        _ effect: ParticleEffect, density: Double, tiltRadians: Double = 0, to screen: Screen
    ) {
        // Keep the legacy player state neutral: particles now live in the common
        // per-display overlay so Video, HTML, Shader, and Scene share one path.
        screen.videoPlayer?.setParticleEffect(.none, density: density)
        guard screen.runtimeSession != nil else {
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
        environmentOverlay.setSuspended(isScreenSuspended(screen.id), screenID: screen.id)
    }

    private func refreshWeatherMonitoringState() {
        guard !isShutdown else { return }
        let activeScreens = screensProvider()
        let activeScreenIDs = Set(activeScreens.map(\.id))
        let configurations = activeScreenIDs.compactMap { configurationStore.get(for: $0) }
        if WeatherReactivePolicy.shouldMonitor(configurations: configurations, activeScreenIDs: activeScreenIDs) {
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isShutdown,
                      self.weatherTrackingGeneration == generation else { return }
                for screen in self.screensProvider() {
                    guard let config = self.configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                          config.effectConfig.weatherReactive else { continue }
                    self.applyWeatherEffects(for: screen)
                }
                self.observeWeatherChanges()
            }
        }
    }
}
