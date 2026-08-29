import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
    /// Reconcile the Monitor overlay for every live display against its persisted config.
    ///
    /// The master switch counts as a reason to have none: it means "stop every
    /// wallpaper", and these panels are drawn over the wallpaper. Particles
    /// already stopped, because `releaseRuntimeSession` takes their layer down
    /// on the way past — the Monitor and Now Playing panels are owned here
    /// instead and used to keep rendering over a bare desktop.
    func reconcileMonitorOverlays() {
        guard !isTerminating, wallpapersGloballyEnabled else {
            OverlayController.shared.teardownAll()
            updateFullScreenFallbackPolling()
            return
        }
        if hasEnabledDesktopMonitorOverlay {
            fullScreenDetector.checkNow()
        }
        // Suspend before host create so occluded overlays never get a prime snapshot.
        refreshMonitorOverlayVisibility()
        OverlayController.shared.onOverlayEdited = { [weak self] screenID, board in
            self?.persistMonitorOverlayBoard(board, screenID: screenID)
        }
        OverlayController.shared.retainOnly(Set(screens.map(\.id)))
        for screen in screens {
            let frame = displayRegistry.findNSScreen(for: screen.id)?.frame ?? screen.frame
            OverlayController.shared.apply(
                overlay: monitorOverlays[screen.displayFingerprint],
                screenID: screen.id,
                screenFrame: frame
            )
        }
        refreshMonitorOverlayVisibility()
        updateFullScreenFallbackPolling()
    }

    /// Bridge ScreenManager's lifecycle state and FullScreenDetector's 85% union-window occlusion result into the overlay-specific visibility policy.
    func refreshMonitorOverlayVisibility() {
        let occludedScreenIDs = Set(screens.compactMap { screen in
            fullScreenDetector.isDesktopOccluded(for: screen.id) ? screen.id : nil
        })
        OverlayController.shared.updateVisibility(
            isUserAbsent: isUserAbsent,
            occludedScreenIDs: occludedScreenIDs
        )
    }

    /// Reconcile on the NEXT runloop tick.
    private func scheduleMonitorOverlayReconcile() {
        Task { @MainActor [weak self] in
            guard let self, !self.isTerminating else { return }
            self.reconcileMonitorOverlays()
        }
    }

    /// Persist a board edit made ON the floating overlay. Skips the reconcile —
    /// re-applying the config would echo the edit back onto the board mid-drag.
    private func persistMonitorOverlayBoard(_ board: MonitorBoardConfiguration, screenID: CGDirectDisplayID) {
        guard let screen = screens.first(where: { $0.id == screenID }) else { return }
        mutateMonitorOverlays(of: [screen], reconcile: false) { $0.board = board }
    }

    /// This display's overlay config; absent = never configured, i.e. off.
    func monitorOverlay(for screen: Screen) -> MonitorOverlayConfiguration {
        monitorOverlays[screen.displayFingerprint] ?? .default
    }

    func setMonitorOverlayEnabled(_ enabled: Bool, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.enabled = enabled }
    }

    func setMonitorOverlayLevel(_ level: MonitorOverlayLevel, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.level = level }
    }

    func setMonitorOverlayBoard(_ board: MonitorBoardConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.board = board }
    }

    func setMusicOverlayEnabled(_ enabled: Bool, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music.enabled = enabled }
    }

    func setMusicOverlayLevel(_ level: MonitorOverlayLevel, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music.level = level }
    }

    /// Position, size and appearance of the Now Playing layer.
    func setMusicOverlay(_ music: MusicOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music = music }
    }

    /// Copies one overlay from `source` onto every other display, leaving each
    /// target's wallpaper — and the overlays the user is not looking at —
    /// exactly as they were.
    ///
    /// Deliberately not folded into "Apply to All Displays" on the wallpaper
    /// header: that action means "put this picture on every screen", and
    /// quietly taking a carefully arranged board along with it would destroy
    /// work the user never offered up. On the overlay tab the same button means
    /// the layer in front of you, and only that one.
    func applyOverlayToAllDisplays(_ kind: OverlayKind, from source: Screen) {
        guard !isTerminating, screens.count > 1 else { return }
        let targets = screens.filter { $0.id != source.id }
        guard !targets.isEmpty else { return }

        switch kind {
        case .monitor:
            let template = monitorOverlay(for: source)
            mutateMonitorOverlays(of: targets) {
                $0.enabled = template.enabled
                $0.level = template.level
                $0.board = template.board
            }
        case .music:
            let template = monitorOverlay(for: source).music
            mutateMonitorOverlays(of: targets) { $0.music = template }
        case .weather:
            // Weather is not in `monitorOverlays` — it rides on each display's
            // own configuration, so only its three fields move.
            guard let template = configurationStore.get(
                for: source.id, fingerprint: source.displayFingerprint
            ) else { return }
            for target in targets {
                guard var config = configurationStore.get(
                    for: target.id, fingerprint: target.displayFingerprint
                ) else { continue }
                config.particleEffect = template.particleEffect
                config.effectConfig.weatherReactive = template.effectConfig.weatherReactive
                config.effectConfig.particleDensity = template.effectConfig.particleDensity
                saveConfiguration(config)
                effectsCoordinator.applyWeatherEffects(for: target)
            }
            effectsCoordinator.reconcileEnvironmentOverlays()
        }
        Logger.info(
            "Applied \(kind) overlay from screen \(source.id) to \(targets.count) other displays",
            category: .screenManager
        )
    }

    /// Pure configuration query used to keep FullScreenDetector's fallback poll
    /// alive whenever a desktop-level overlay depends on its occlusion cache.
    /// Either module counts: a desktop-level Music layer needs the same
    /// occlusion cache even with the Monitor board switched off.
    var hasEnabledDesktopMonitorOverlay: Bool {
        screens.contains {
            let overlay = monitorOverlay(for: $0)
            return (overlay.enabled && overlay.level == .desktop)
                || (overlay.music.enabled && overlay.music.level == .desktop)
        }
    }

    /// Sole writer of `monitorOverlays`; write-through to global settings.
    private func mutateMonitorOverlays(
        of targets: [Screen],
        reconcile: Bool = true,
        _ mutate: (inout MonitorOverlayConfiguration) -> Void
    ) {
        var next = monitorOverlays
        for screen in targets {
            var overlay = next[screen.displayFingerprint] ?? .default
            mutate(&overlay)
            next[screen.displayFingerprint] = overlay
        }
        guard next != monitorOverlays else { return }
        monitorOverlays = next
        SettingsManager.shared.saveMonitorOverlays(next)
        if reconcile { scheduleMonitorOverlayReconcile() }
    }

    func setSceneWallpaper(descriptor: SceneDescriptor, origin: WPEOrigin?, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .scene(descriptor)
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        if configuration.activeWallpaper == .scene(descriptor),
           configuration.wpeOrigin == origin,
           screen.runtimeSession?.wallpaperType == .scene {
            Logger.info("Scene wallpaper already active for screen \(screen.id); keeping existing scene session", category: .screenManager)
            return
        }

        configuration.setSceneWallpaper(descriptor, origin: origin)
        restoreWallpaperSession(
            for: screen,
            configuration: configuration,
            preservingState: false,
            intent: .proposal,
            beforeCommit: { [weak self] in
                self?.saveConfiguration(configuration)
                return self != nil
            }
        )
    }

    func activateAmbientWallpaper(
        _ definition: WallpaperSessionDefinition,
        for screen: Screen,
        configuration: ScreenConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        guard !isTerminating else { return }
        let generation = bumpTransition(for: screen.id)
        let expected = screen.runtimeSession
        let candidate: any WallpaperRuntimeSession
        let timeout: Duration
        var afterCommit: @MainActor () -> Void = {}
        // Keep bookmark-refreshed config for commit (do not write the stale grant).
        var effectiveCommitConfiguration = configuration

        switch definition {
        case .html(let source, let htmlConfig):
            let effectiveSource = ambientSessionBuilder.refreshingHTMLSource(
                source,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed
                    )
                }
            )
            let isLeader = htmlCoordinator.isAudioLeader(source: effectiveSource, excluding: screen.id)
            let effectiveConfig = htmlCoordinator.runtimeConfig(
                source: effectiveSource,
                config: htmlConfig,
                for: screen
            )
            var preparationConfig = effectiveConfig
            preparationConfig.muteAudio = true
            preparationConfig.audioVolume = 0
            var finalEffectiveSource = effectiveSource
            let session = ambientSessionBuilder.makeHTMLSession(
                source: effectiveSource,
                config: preparationConfig,
                frame: screen.frame,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    if let updated = finalEffectiveSource.replacingLocalBookmark(
                        matching: original,
                        with: refreshed
                    ) {
                        finalEffectiveSource = updated
                    }
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed
                    )
                }
            )
            if let original = source.localBookmarkData,
               let refreshed = finalEffectiveSource.localBookmarkData,
               original != refreshed {
                if let origin = configuration.wpeOrigin,
                   origin.sourceFolderBookmark == original,
                   let updated = configuration.replacingWPEOriginBookmark(
                    workshopID: origin.workshopID,
                    matching: original,
                    with: refreshed
                ) {
                    effectiveCommitConfiguration = updated
                } else if let updated = configuration.replacingHTMLBookmark(
                    matching: original,
                    with: refreshed
                ) {
                    effectiveCommitConfiguration = updated
                }
            }
            // Seeded here for the same reason the scene branch seeds its own
            // controller below: the coordinator only pushes the limit when the
            // user changes it, so a session rebuilt by a wallpaper switch or a
            // relaunch would otherwise run unthrottled until the next edit.
            session.setFrameRateLimit(configuration.frameRateLimit)
            candidate = session
            if case .url = effectiveSource {
                timeout = .seconds(12)
            } else {
                timeout = .seconds(5)
            }
            afterCommit = {
                _ = session.applyHTMLConfig(effectiveConfig)
            }
            Logger.info("Preparing HTML wallpaper for screen \(screen.id) — \(effectiveSource.displayName) [leader=\(isLeader)]", category: .screenManager)
        case .scene(let descriptor):
            #if !LITE_BUILD
            let runtimeOrigin: WPEOrigin? = if !descriptor.dependencyWorkshopIDs.isEmpty,
                                               let origin = configuration.wpeOrigin {
                ambientSessionBuilder.refreshingWPEOrigin(
                    origin,
                    onOriginBookmarkRefresh: { [weak self] origin, refreshed in
                        self?.persistRuntimeWPEBookmarkRefresh(
                            origin: origin,
                            with: refreshed
                        )
                    }
                )?.origin ?? origin
            } else {
                configuration.wpeOrigin
            }
            var finalRuntimeOrigin = runtimeOrigin
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: runtimeOrigin
            )
            let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
            guard let sceneSession = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor,
                origin: runtimeOrigin,
                frame: screen.frame,
                fitMode: configuration.fitMode,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineRoot,
                onOriginBookmarkRefresh: { [weak self] origin, refreshed in
                    finalRuntimeOrigin = origin.replacingSourceFolderBookmark(
                        matching: origin.sourceFolderBookmark,
                        with: refreshed
                    ) ?? finalRuntimeOrigin
                    self?.persistRuntimeWPEBookmarkRefresh(
                        origin: origin,
                        with: refreshed
                    )
                }
            ) else {
                Logger.warning("Scene wallpaper for screen \(screen.id) (workshop \(descriptor.workshopID)) could not be built — cache missing or descriptor invalid", category: .screenManager)
                return
            }
            if let originalOrigin = configuration.wpeOrigin,
               let finalRuntimeOrigin,
               originalOrigin.sourceFolderBookmark != finalRuntimeOrigin.sourceFolderBookmark,
               let updated = configuration.replacingWPEOriginBookmark(
                workshopID: originalOrigin.workshopID,
                matching: originalOrigin.sourceFolderBookmark,
                with: finalRuntimeOrigin.sourceFolderBookmark
            ) {
                effectiveCommitConfiguration = updated
            }
            sceneSession.frameRateController?.setFrameRateLimit(configuration.frameRateLimit)
            sceneSession.setMouseInteractionEnabled(configuration.sceneMouseInteractionEnabled)
            sceneSession.setClickCaptureEnabled(false)
            // Fit mode is a construction argument now (see `makeSceneSession`);
            // re-submitting it here would just be a second source for the value.
            if let audio = sceneSession.audioController {
                audio.setAudioMuted(true)
                audio.setAudioVolume(configuration.videoVolume)
            }
            candidate = sceneSession
            timeout = .seconds(12)
            afterCommit = {
                sceneSession.setClickCaptureEnabled(configuration.sceneClickCaptureEnabled)
                if let audio = sceneSession.audioController {
                    audio.setAudioMuted(configuration.muted)
                    audio.setAudioVolume(configuration.videoVolume)
                }
            }
            Logger.info("Preparing scene wallpaper (workshop \(descriptor.workshopID)) for screen \(screen.id)", category: .screenManager)
            #else
            _ = descriptor
            return
            #endif
        case .video:
            return
        }

        // Fail closed if config revision advances while this candidate prepares.
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)
        var outgoingVideoPlayerAtCommit: WallpaperVideoPlayer?
        let transactionalBeforeCommit: @MainActor () -> Bool = { [weak self] in
            guard let self,
                  self.commitPreparedAmbientConfiguration(
                proposed: configuration,
                effective: effectiveCommitConfiguration,
                screenID: screen.id,
                ownerCommit: beforeCommit
            ) else {
                return false
            }
            // Capture outgoing player in the same installRuntimeSession CAS turn.
            outgoingVideoPlayerAtCommit =
                (expected as? VideoWallpaperSession)?.videoPlayer
            return true
        }
        let transactionalAfterCommit: @MainActor () -> Void = { [weak self] in
            self?.retireOutgoingVideoWork(
                for: screen.id,
                player: outgoingVideoPlayerAtCommit
            )
            afterCommit()
        }
        beginPreparedAmbientSession(
            candidate,
            for: screen,
            replacing: expected,
            generation: generation,
            expectedConfigurationRevision: expectedConfigurationRevision,
            timeout: timeout,
            beforeCommit: transactionalBeforeCommit,
            afterCommit: transactionalAfterCommit
        )
    }

    /// Persists a local HTML refresh into every screen that still owns the original grant.
    func persistRuntimeHTMLBookmarkRefresh(
        matching original: Data,
        with refreshed: Data,
        bookmarkID: UUID? = nil,
        ownerOrigin: WPEOrigin? = nil
    ) {
        guard !isTerminating else { return }
        var wpeWorkshopIDs: Set<String> = []
        if let ownerOrigin,
           ownerOrigin.sourceFolderBookmark == original {
            wpeWorkshopIDs.insert(ownerOrigin.workshopID)
        }
        for configuration in configurationStore.loadAll() {
            if let origin = configuration.wpeOrigin,
               origin.sourceFolderBookmark == original,
               let updated = configuration.replacingWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
               ) {
                saveConfiguration(updated)
                wpeWorkshopIDs.insert(origin.workshopID)
            } else if let updated = configuration.replacingHTMLBookmark(
                matching: original,
                with: refreshed
            ) {
                saveConfiguration(updated)
            }
        }
        if let bookmarkID {
            _ = BookmarkStore.shared.replaceHTMLBookmark(
                id: bookmarkID,
                matching: original,
                with: refreshed
            )
        }
        _ = BookmarkStore.shared.replaceMatchingHTMLBookmarks(
            matching: original,
            with: refreshed
        )
        for workshopID in wpeWorkshopIDs {
            _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
            _ = BookmarkStore.shared.replaceWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
        }
    }

    /// MainActor owner for scene/history stale refreshes.
    func persistRuntimeWPEBookmarkRefresh(
        origin: WPEOrigin,
        with refreshed: Data
    ) {
        guard !isTerminating else { return }
        let original = origin.sourceFolderBookmark
        for configuration in configurationStore.loadAll() {
            guard let updated = configuration.replacingWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: original,
                with: refreshed
            ) else { continue }
            saveConfiguration(updated)
        }
        _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
        _ = BookmarkStore.shared.replaceWPEOriginBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
    }
}
