import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
extension PlaybackCoordinator {
    // MARK: - Asset readiness + startup playback policy

    func applyConfigurationWhenAssetReady(
        player: WallpaperVideoPlayer,
        screen: Screen,
        fallbackDelay: Duration = .seconds(5)
    ) {
        let screenID = screen.id
        transition.cancelAssetReadiness(for: screenID)

        let apply: @MainActor () -> Void = { [weak self] in
            self?.applyAssetReadyConfigurationIfCurrent(
                player: player,
                screenID: screenID
            )
        }

        if player.videoFrameRate > 0 {
            apply()
            return
        }

        let work = AssetReadinessWork()
        transition.setAssetReadiness(work, for: screenID)
        var didApply = false

        let finish: @MainActor () -> Void = { [weak self, weak work] in
            guard let self, !didApply else { return }
            didApply = true
            apply()
            work?.cancel()
            if let work {
                self.transition.clearAssetReadinessIfMatch(work, for: screenID)
            }
        }

        work.frameRateSubscription = player.$videoFrameRate
            .first(where: { $0 > 0 })
            .receive(on: DispatchQueue.main)
            .sink { _ in
                finish()
            }

        work.fallbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: fallbackDelay)
            } catch {
                return
            }
            finish()
        }
    }

    /// Publishes deferred asset settings only while this player still owns the exact entry.
    /// Must not replay the startup snapshot — settings can change during asset discovery.
    @discardableResult
    func applyAssetReadyConfigurationIfCurrent(
        player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID
    ) -> Bool {
        guard let liveScreen = screensProvider().first(where: { $0.id == screenID }),
              liveScreen.videoPlayer === player,
              let configuration = configurationStore.get(
                for: screenID,
                fingerprint: liveScreen.displayFingerprint
              ),
              case .video(let bookmarkData, let packageEntryName) = configuration.activeWallpaper,
              let playerURL = player.videoURL,
              bookmarkResolves(to: playerURL, bookmark: bookmarkData),
              packageEntryName == player.packageEntryName else {
            return false
        }
        player.setParticleEffect(
            configuration.particleEffect,
            density: configuration.effectConfig.particleDensity
        )
        if configuration.effectConfig.hasActiveEffect {
            applyVideoEffects(liveScreen, configuration)
        } else {
            applyFrameRateLimit(configuration.frameRateLimit, to: liveScreen)
        }
        return true
    }
}
