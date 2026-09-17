import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
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
        // Reading `weatherService` builds the effects coordinator, so only a board
        // that draws the sky pays for it.
        OverlayController.shared.updateWeatherService(hasEnabledWeatherWidget ? weatherService : nil)
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

    func refreshMonitorOverlayVisibility() {
        let occludedScreenIDs = Set(screens.compactMap { screen in
            fullScreenDetector.isDesktopOccluded(for: screen.id) ? screen.id : nil
        })
        OverlayController.shared.updateVisibility(
            isUserAbsent: isUserAbsent,
            occludedScreenIDs: occludedScreenIDs
        )
    }

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

    var hasEnabledWeatherWidget: Bool {
        wallpapersGloballyEnabled && screens.contains { screen in
            let overlay = monitorOverlay(for: screen)
            return overlay.enabled && overlay.board.widgets.contains { $0.kind == .weather }
        }
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

    func setMusicOverlay(_ music: MusicOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music = music }
    }

    func setClockOverlay(_ clock: ClockOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.clock = clock.normalized }
    }

    /// Whole-struct overwrite so a field added to MonitorOverlayConfiguration later cannot be silently dropped on apply.
    func setMonitorOverlay(_ overlay: MonitorOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0 = overlay }
    }

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
        case .clock:
            let template = monitorOverlay(for: source).clock
            mutateMonitorOverlays(of: targets) { $0.clock = template }
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
                config.adoptWeatherOverlay(from: template)
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

    var hasEnabledDesktopMonitorOverlay: Bool {
        screens.contains {
            let overlay = monitorOverlay(for: $0)
            return (overlay.enabled && overlay.level == .desktop)
                || (overlay.music.enabled && overlay.music.level == .desktop)
                || (overlay.clock.enabled && overlay.clock.level == .desktop)
        }
    }

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
        // A Weather tile dropped on the desktop arrives with reconcile: false, so this is where a board already built gets the sky.
        OverlayController.shared.updateWeatherService(hasEnabledWeatherWidget ? weatherService : nil)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.monitorBoardsDidChange()
        }
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

    /// The store still describes the running scene here: proposals persist only in `beforeCommit`.
    private func runningSceneWorkshopID(for screen: Screen) -> String? {
        guard let stored = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              case let .scene(current) = stored.activeWallpaper else { return nil }
        return current.workshopID
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
        let attemptID: UUID?
        if case .scene(let descriptor) = definition {
            let current = wallpaperLoads.attempt(for: screen)
            // Rebuilding the scene that is already on screen (a property change) must not swap the detail page to the attempt views.
            let rebuildsRunningScene = screen.runtimeSession?.wallpaperType == .scene
                && runningSceneWorkshopID(for: screen) == descriptor.workshopID
            let id = current?.phase == .importing ? current!.id : wallpaperLoads.begin(for: screen, title: configuration.wpeOrigin?.title ?? definition.displayName(using: { bookmarkDisplayName(for: $0) }) ?? String(localized: "Scene wallpaper", bundle: .appLanguage), origin: configuration.wpeOrigin, inspecting: !rebuildsRunningScene)
            wallpaperLoads.update(id, for: screen) {
                $0.configuration = configuration
                $0.origin = configuration.wpeOrigin
                $0.title = configuration.wpeOrigin?.title ?? $0.title
                $0.phase = .preparing
            }
            attemptID = id
        } else {
            attemptID = nil
        }
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
            let isLeader = htmlCoordinator.isAudioLeader(source: effectiveSource, for: screen.id)
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
            // Seeded here: the coordinator only pushes the limit when the user changes it, so a session rebuilt by a wallpaper switch or a relaunch would otherwise run unthrottled until the next edit.
            session.setFrameRateCeiling(
                configuration.frameRateLimit.frameRate(
                    forRefreshRate: Double(getScreenRefreshRate(for: screen.id))
                )
            )
            candidate = session
            if case .url = effectiveSource {
                timeout = .seconds(12)
            } else {
                timeout = .seconds(5)
            }
            afterCommit = {
                _ = session.applyHTMLConfig(effectiveConfig)
            }
            Logger.notice("Preparing HTML wallpaper for screen \(screen.id) — \(LogPrivacyRedactor.sanitizedTitle(effectiveSource.displayName)) [leader=\(isLeader)]", category: .screenManager)
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
                if let attemptID {
                    failWallpaperAttempt(attemptID, for: screen, cause: WallpaperFailureCause(code: "scene.source_unavailable", reason: String(localized: "The scene source could not be opened. Check its location and access permission.", bundle: .appLanguage)), stage: "source")
                }
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
            sceneSession.frameRateController?.setFrameRateCeiling(
                configuration.frameRateLimit.frameRate(
                    forRefreshRate: Double(getScreenRefreshRate(for: screen.id))
                )
            )
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
            Logger.notice("Preparing scene wallpaper (workshop \(descriptor.workshopID))\(LogPrivacyRedactor.titleFragment(configuration.wpeOrigin?.title)) for screen \(screen.id)", category: .screenManager)
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
            attemptID: attemptID,
            expectedConfigurationRevision: expectedConfigurationRevision,
            timeout: timeout,
            beforeCommit: transactionalBeforeCommit,
            afterCommit: transactionalAfterCommit
        )
    }

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
        SchemeStore.shared.replaceHTMLBookmark(matching: original, with: refreshed)
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
            SchemeStore.shared.replaceWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            )
        }
    }

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
        SchemeStore.shared.replaceWPEOriginBookmark(
            workshopID: origin.workshopID,
            matching: original,
            with: refreshed
        )
    }
}
