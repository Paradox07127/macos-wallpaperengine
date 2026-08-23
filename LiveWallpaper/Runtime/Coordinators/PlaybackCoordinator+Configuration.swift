import Foundation
import LiveWallpaperCore

@MainActor
extension PlaybackCoordinator {
    // MARK: - Configuration setters

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              speed != configuration.playbackSpeed else { return }

        let previous = configuration.playbackSpeed
        configuration.playbackSpeed = speed
        save(configuration)
        screen.videoPlayer?.setPlaybackSpeed(speed)
        Logger.info("Playback speed updated for screen \(screen.id): \(previous) -> \(speed)", category: .settings)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              muted != configuration.muted else { return }

        configuration.muted = muted
        save(configuration)
        syncVideoAudioLeadership()
        applySceneAudioState(configuration: configuration, screen: screen)
    }

    func updateVideoVolume(_ volume: Double, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let clampedVolume = Self.clampedVideoVolume(volume)
        guard abs(configuration.videoVolume - clampedVolume) > 0.001 else { return }

        configuration.videoVolume = clampedVolume
        save(configuration)
        syncVideoAudioLeadership()
        applySceneAudioState(configuration: configuration, screen: screen)
    }

    /// Routes mute/volume into scene `WPESoundRuntime` (no-op for video/html/no-sound).
    private func applySceneAudioState(configuration: ScreenConfiguration, screen: Screen) {
        #if !LITE_BUILD
        guard let session = screen.runtimeSession as? SceneWallpaperSession,
              let audio = session.audioController else { return }
        audio.setAudioMuted(configuration.muted)
        audio.setAudioVolume(configuration.videoVolume)
        #endif
    }

    /// Scene-only Follow Cursor: persist + live push.
    func updateSceneMouseInteraction(_ enabled: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              enabled != configuration.sceneMouseInteractionEnabled else { return }
        configuration.sceneMouseInteractionEnabled = enabled
        save(configuration)
        #if !LITE_BUILD
        (screen.runtimeSession as? SceneWallpaperSession)?.setMouseInteractionEnabled(enabled)
        #endif
    }

    /// Scene-only click capture; enabling steals desktop clicks.
    func updateSceneClickCapture(_ enabled: Bool, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              enabled != configuration.sceneClickCaptureEnabled else { return }
        configuration.sceneClickCaptureEnabled = enabled
        save(configuration)
        #if !LITE_BUILD
        (screen.runtimeSession as? SceneWallpaperSession)?.setClickCaptureEnabled(enabled)
        #endif
    }

    /// Scene fit mode: persist + live push via `SceneWallpaperSession`.
    func updateSceneFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              fitMode != configuration.fitMode else { return }
        configuration.fitMode = fitMode
        save(configuration)
        #if !LITE_BUILD
        (screen.runtimeSession as? SceneWallpaperSession)?.setSceneFitMode(fitMode)
        #endif
    }

    func updateVideoColorSpace(_ colorSpace: VideoColorSpace, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              configuration.videoColorSpace != colorSpace else { return }
        let previousColorSpace = configuration.videoColorSpace
        configuration.videoColorSpace = colorSpace
        save(configuration)
        guard let player = screen.videoPlayer else { return }
        player.setVideoColorSpace(colorSpace)

        // Force SDR and CIFilter share videoComposition; entering cancels in-flight effects.
        if configuration.effectConfig.hasActiveEffect,
           previousColorSpace == .forceSDR || colorSpace == .forceSDR {
            applyVideoEffects(screen, configuration)
        }
    }

    func refreshVideoAudioLeadership() {
        syncVideoAudioLeadership()
        applyVideoSpanLayout()
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              configuration.videoDisplayMode != mode else { return }

        configuration.videoDisplayMode = mode
        save(configuration)
        applyVideoSpanLayout()
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              fitMode != configuration.fitMode else { return }

        let previous = configuration.fitMode
        configuration.fitMode = fitMode
        save(configuration)
        screen.videoPlayer?.setVideoFitMode(fitMode)
        Logger.info("Fit mode updated for screen \(screen.id): \(previous.rawValue) -> \(fitMode.rawValue)", category: .settings)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
            Logger.warning("Cannot update frame rate limit: No configuration found for screen \(screen.id)", category: .videoPlayer)
            return
        }
        guard frameRateLimit != configuration.frameRateLimit else { return }

        configuration.frameRateLimit = frameRateLimit
        save(configuration)
        // Effects are an `AVVideoComposition` pass, so they can only carry the
        // limit for a screen that owns a player. A scene or HTML screen holding
        // a stale effect config used to route its limit into that path and lose it.
        if configuration.effectConfig.hasActiveEffect, screen.videoPlayer != nil {
            applyVideoEffects(screen, configuration)
        } else {
            applyFrameRateLimit(frameRateLimit, to: screen)
        }
    }

    func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        // Scene (and any future ambient renderer that owns its own
        // display link) responds via WallpaperFrameRateConfigurable.
        #if !LITE_BUILD
        if let session = screen.runtimeSession as? SceneWallpaperSession,
           let frameRateController = session.frameRateController {
            Logger.info(
                "Applying scene frame rate limit \(frameRateLimit.rawValue) to screen \(screen.id)",
                category: .videoPlayer
            )
            frameRateController.setFrameRateLimit(frameRateLimit)
            return
        }
        #endif

        // HTML paces itself with a JS rAF gate rather than a display link, so it
        // has no `videoPlayer` for the path below to reach. Without this branch
        // the limit was silently dropped for every HTML wallpaper.
        if let ambient = screen.runtimeSession as? AmbientWallpaperSession {
            Logger.info(
                "Applying HTML frame rate limit \(frameRateLimit.rawValue) to screen \(screen.id)",
                category: .videoPlayer
            )
            ambient.setFrameRateLimit(frameRateLimit)
            return
        }

        guard let player = screen.videoPlayer, player.videoFrameRate > 0 else { return }

        let screenRefreshRate = refreshRateLookup(screen.id)
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )

        if let limit {
            Logger.info("Applying frame rate limit of \(Int(limit)) FPS to screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(limit)
        } else {
            Logger.info("Using native playback path (\(Int(player.videoFrameRate)) FPS) for screen \(screen.id)", category: .videoPlayer)
            player.setFrameRateLimit(0)
        }
    }
}
