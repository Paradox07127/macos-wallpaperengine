import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

enum WallpaperSessionRestoreIntent: Equatable {
    /// Restore persisted config; tear down live session if it cannot describe a runtime.
    case persistedConfiguration
    /// Applies a not-yet-committed user/automation proposal. Invalid proposals
    /// must not disturb the runtime or configuration that is still authoritative.
    case proposal
}

struct LegacyFingerprintMapping: Equatable {
    let legacy: String
    let current: String
}

extension ScreenManager {
    func refreshScreens(preserveRuntimeSessions: Bool = true) {
        guard !isTerminating else { return }
        let newScreens = displayRegistry.currentScreens()
        migrateLegacyDisplayIdentities(of: newScreens)
        // Screens are rebuilt from NSScreen on every refresh, so the user's names
        // have to be re-attached here or they vanish on the next display change.
        for screen in newScreens {
            screen.customName = screenNames[screen.displayFingerprint]
        }
        Logger.screensDetected(newScreens.count)

        let oldScreens = screens
        let oldScreenIDs = Set(oldScreens.map(\.id))
        let newScreenIDs = Set(newScreens.map(\.id))
        let oldFingerprintsByID = Dictionary(
            oldScreens.map { ($0.id, $0.displayFingerprint) },
            uniquingKeysWith: { first, _ in first }
        )

        for screenID in oldScreenIDs.subtracting(newScreenIDs) {
            if let screen = oldScreens.first(where: { $0.id == screenID }) {
                Logger.info("Cleaning up removed screen \(screenID)", category: .screenManager)
                releaseRuntimeSession(screen)
            }

        }

        // A recycled/repurposed CGDirectDisplayID (same ID, different physical panel) reports a new displayFingerprint.
        let identityChangedIDs = Set(newScreens.compactMap { newScreen -> CGDirectDisplayID? in
            guard let oldFingerprint = oldFingerprintsByID[newScreen.id],
                  oldFingerprint != newScreen.displayFingerprint else { return nil }
            return newScreen.id
        })
        for screen in oldScreens where identityChangedIDs.contains(screen.id) {
            Logger.info("Display \(screen.id) fingerprint changed — releasing prior panel's session", category: .screenManager)
            releaseRuntimeSession(screen)
        }

        var forcedReloadIDs: Set<CGDirectDisplayID> = []
        if !preserveRuntimeSessions {
            for screen in oldScreens where newScreenIDs.contains(screen.id) {
                releaseRuntimeSession(screen)
            }
            forcedReloadIDs = oldScreenIDs.intersection(newScreenIDs)
        }

        var updatedScreens = [Screen]()

        for newScreen in newScreens {
            if preserveRuntimeSessions,
               !identityChangedIDs.contains(newScreen.id),
               let existingScreen = oldScreens.first(where: { $0.id == newScreen.id }) {
                newScreen.adoptRuntimeSession(from: existingScreen)
            }

            updatedScreens.append(newScreen)
        }

        screens = updatedScreens

        let reloadIDs = newScreenIDs.subtracting(oldScreenIDs).union(identityChangedIDs).union(forcedReloadIDs)
        for screen in newScreens where reloadIDs.contains(screen.id) {
            Logger.info("Configuring new screen \(screen.id)", category: .screenManager)
            if restoresSavedWallpapersOnScreenRefresh {
                loadConfigurationForScreen(screen)
            }
        }

        updateAllWindowFrames()

        markWallpaperSessionStateChanged()
        updateFullScreenFallbackPolling()

        if !wallpapersGloballyEnabled {
            applyGlobalRenderGate()
        }

        automationOrchestrator.refreshMonitoringIfActive()
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.screensDidChange(arrivedScreenIDs: reloadIDs)
        }
        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        Logger.notice("Clearing wallpaper for screen \(screen.id)", category: .screenManager)
        releaseRuntimeSession(screen)
        persistence.remove(for: screen.id)
        notifyWallpaperSessionChanged()
    }

    /// Clear only one wallpaper type for this screen — drops that type's saved state (saved video bookmark, saved HTML source, etc.).
    func clearWallpaperOfType(_ type: WallpaperType, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let wasActive = (config.activeWallpaper.wallpaperType == type)
        // Clear wpeOrigin when leaving a scene so reloads cannot revive deleted content.
        if wasActive, type == .scene {
            config.wpeOrigin = nil
        }

        switch type {
        case .video:
            config.savedVideoBookmarkData = nil
            config.playlistBookmarks = nil
            config.playlistPrimaryIndex = nil
        case .html:
            config.savedHTMLSource = nil
            config.savedHTMLConfig = nil
        case .scene:
            config.savedSceneDescriptor = nil
        }

        guard wasActive else {
            saveConfiguration(config)
            return
        }

        if type != .video, config.activateSavedVideoWallpaper() {
            restoreProposedWallpaperSession(for: screen, configuration: config)
            return
        }

        if type != .html, config.activateSavedHTMLWallpaper() {
            restoreProposedWallpaperSession(for: screen, configuration: config)
            return
        }

        clearWallpaperForScreen(screen)
    }

    /// Tears down the live runtime session without touching persistence.
    func releaseRuntimeSession(_ screen: Screen) {
        adaptiveFrameRateOcclusionThrottled[screen.id] = nil
        suspendReasonsByScreen[screen.id] = nil
        bumpTransition(for: screen.id)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.retireAllWork(for: screen.id)
            effectsCoordinator.removeEnvironmentOverlay(for: screen)
        }
        transitionRegistry.cancelAssetReadiness(for: screen.id)
        setTransientRuntimeError(nil, for: screen.id)
        screen.resetRuntimeSession()
        resetPlaybackStateMachine(for: screen)
        playbackCoordinator.refreshVideoAudioLeadership()
        // Refresh HTML audio leadership after tearing down a leader session.
        htmlCoordinator.refreshAudioLeadership()
        refreshAppNapAssertion()
    }

    /// App-termination teardown: synchronously tears down every render session (each `cleanup()` pauses its AVPlayer, releases its WKWebView / Metal renderer, and closes its window) and stops lifecycle observers.
    func tearDownForTermination() {
        guard !isTerminating else { return }

        OverlayController.shared.teardownAll()
        isTerminating = true
        memoryPressureWatcher.stop()

        cleanupTasks.removeAll()
        fullScreenTrackingGeneration &+= 1
        fullScreenDetector.setFallbackPollingEnabled(false)
        fullScreenDetector.stop()
        automationOrchestrator.stopMonitoring()
        #if !LITE_BUILD
        wpeImportTracker.invalidateForTermination()
        #endif
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.shutdown()
        }
        if featureCatalog.isEnabled(.lockScreenSnapshots) {
            lockScreenSnapshotCoordinator.stop()
        }

        for screen in screens {
            releaseRuntimeSession(screen)
        }
    }

    func resetAllWallpaperSessions() {
        let snapshot = screens
        for screen in snapshot {
            releaseRuntimeSession(screen)
        }
        configurationStore.clearCache()
        Task { @MainActor in
            for screen in snapshot {
                NotificationCenter.default.post(
                    name: .wallpaperConfigurationDidChange,
                    object: nil,
                    userInfo: ["screenID": screen.id]
                )
            }
        }
        notifyWallpaperSessionChanged()
    }
    

    /// Light launch-time pass: prunes configurations whose local resource bookmark is no longer resolvable.
    func pruneInvalidConfigurationsIfNeeded() {
        guard !isTerminating else { return }
        persistence.pruneInvalidConfigurations()
    }

    func loadConfigurationForScreen(_ screen: Screen) {
        guard !isTerminating else { return }
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        primeBookmarkDisplayNames(from: config)
        restoreWallpaperSession(for: screen, configuration: config, preservingState: false)
    }

    func restoreWallpaperSession(
        for screen: Screen,
        configuration: ScreenConfiguration,
        preservingState: Bool,
        intent: WallpaperSessionRestoreIntent = .persistedConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        guard !isTerminating else { return }
        guard let definition = WallpaperSessionDefinition(configuration: configuration) else {
            switch intent {
            case .persistedConfiguration:
                Logger.warning("Skipping malformed persisted wallpaper configuration for screen \(screen.id)", category: .screenManager)
                releaseRuntimeSession(screen)
            case .proposal:
                Logger.warning("Rejecting malformed wallpaper proposal for screen \(screen.id); keeping current runtime and configuration", category: .screenManager)
            }
            return
        }

        guard wallpapersGloballyEnabled else {
            guard beforeCommit() else { return }
            if screen.runtimeSession != nil { releaseRuntimeSession(screen) }
            notifyWallpaperSessionChanged()
            return
        }

        switch definition {
        case .video:
            applyConfiguration(
                configuration,
                to: screen,
                preservingState: preservingState,
                forceReplacement: !preservingState,
                intent: intent,
                beforeCommit: beforeCommit
            )
        case .html(let source, let htmlConfig):
            activateAmbientWallpaper(
                .html(source, htmlConfig),
                for: screen,
                configuration: configuration,
                beforeCommit: beforeCommit
            )
        case .scene(let descriptor):
            activateAmbientWallpaper(
                .scene(descriptor),
                for: screen,
                configuration: configuration,
                beforeCommit: beforeCommit
            )
        }
    }

    /// Applies a configuration proposal transactionally: persistence is delayed
    /// until the prepared candidate still matches the screen's expected session.
    func restoreProposedWallpaperSession(
        for screen: Screen,
        configuration: ScreenConfiguration,
        preservingState: Bool = false
    ) {
        restoreWallpaperSession(
            for: screen,
            configuration: configuration,
            preservingState: preservingState,
            intent: .proposal,
            beforeCommit: { [weak self] in
                guard let self else { return false }
                self.saveConfiguration(configuration)
                return true
            }
        )
    }


    func saveConfiguration(_ configuration: ScreenConfiguration) {
        guard !isTerminating else { return }
        advanceScenePropertyMutationIntent(for: configuration.screenID)
        persistence.save(configuration)
    }

    func updatePlaybackSpeed(_ speed: Double, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updatePlaybackSpeed(speed, for: screen)
    }

    func updateMuted(_ muted: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateMuted(muted, for: screen)
    }

    func updateVideoVolume(_ volume: Double, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateVideoVolume(volume, for: screen)
    }

    func updateVideoColorSpace(_ colorSpace: VideoColorSpace, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateVideoColorSpace(colorSpace, for: screen)
    }

    func updateSceneMouseInteraction(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneMouseInteraction(enabled, for: screen)
    }

    func updateSceneClickCapture(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneClickCapture(enabled, for: screen)
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        guard !isTerminating else { return }
        guard var sourceConfiguration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              sourceConfiguration.wallpaperType == .video,
              sourceConfiguration.hasConfiguredVideoSource else { return }

        switch mode {
        case .perDisplay:
            let sourceBookmark = sourceConfiguration.videoBookmarkData
            var changed = false

            for target in screens {
                guard var targetConfiguration = configurationStore.get(for: target.id, fingerprint: target.displayFingerprint),
                      targetConfiguration.wallpaperType == .video,
                      targetConfiguration.videoDisplayMode == .spanAllDisplays else { continue }

                if let sourceBookmark,
                   targetConfiguration.videoBookmarkData != sourceBookmark {
                    continue
                }

                targetConfiguration.videoDisplayMode = .perDisplay
                restoreProposedWallpaperSession(
                    for: target,
                    configuration: targetConfiguration,
                    preservingState: true
                )
                changed = true
            }

            if !changed {
                playbackCoordinator.updateVideoDisplayMode(mode, for: screen)
            }

        case .spanAllDisplays:
            guard screens.count > 1 else {
                playbackCoordinator.updateVideoDisplayMode(.perDisplay, for: screen)
                return
            }

            sourceConfiguration.videoDisplayMode = .spanAllDisplays
            for target in screens {
                let copy = sourceConfiguration.reboundToDisplay(
                    target.id,
                    fingerprint: target.displayFingerprint
                )

                restoreProposedWallpaperSession(
                    for: target,
                    configuration: copy,
                    preservingState: target.id == screen.id
                )
                Logger.info("Span Video: copied configuration from screen \(screen.id) → \(target.id)", category: .screenManager)
            }
        }
    }

    func updateFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateFitMode(fitMode, for: screen)
    }

    func updateSceneFitMode(_ fitMode: VideoFitMode, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateSceneFitMode(fitMode, for: screen)
    }

    func updateFrameRateLimit(_ frameRateLimit: FrameRateLimit, for screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.updateFrameRateLimit(frameRateLimit, for: screen)
    }

    func applyFrameRateLimit(_ frameRateLimit: FrameRateLimit, to screen: Screen) {
        guard !isTerminating else { return }
        playbackCoordinator.applyFrameRateLimit(frameRateLimit, to: screen)
    }
    
    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
    }

    func displayPlaybackDiffersFromDefaults(for screen: Screen) -> Bool {
        guard let config = getConfiguration(for: screen) else { return false }
        return config.playbackDiffers(from: SettingsManager.shared.loadDisplayDefaults())
    }

    func displaySettingsDifferFromDefaults(for screen: Screen) -> Bool {
        guard let config = getConfiguration(for: screen) else { return false }
        if config.storedPlaybackDiffers(from: SettingsManager.shared.loadDisplayDefaults()) {
            return true
        }
        return config.particleEffect != .none
            || config.effectConfig != .default
            || config.scheduleSlots != nil
            || config.shufflePlaylist
            || config.playlistRotationMinutes != nil
            || config.setAsLockScreen
            || config.wallpaperMode != .playlist
    }

    func resetPlaybackSettings(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.resetPlayback(to: SettingsManager.shared.loadDisplayDefaults())
        restoreProposedWallpaperSession(
            for: screen,
            configuration: config,
            preservingState: true
        )
        Logger.info("Reset playback defaults for screen \(screen.id)", category: .screenManager)
    }

    /// Resets per-display controls while preserving wallpaper content and source metadata.
    func resetDisplaySettings(for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let displayDefaults = SettingsManager.shared.loadDisplayDefaults()
        config.resetStoredPlayback(to: displayDefaults)
        config.particleEffect = .none
        config.effectConfig = .default
        config.scheduleSlots = nil
        config.shufflePlaylist = false
        config.playlistRotationMinutes = nil
        config.setAsLockScreen = false
        config.wallpaperMode = .playlist
        config.savedHTMLConfig = .default
        config.resetSavedHTMLPlayback(to: displayDefaults, createIfMissing: true)
        if case .html(let source, _) = config.activeWallpaper {
            config.activeWallpaper = .html(source: source, config: .default)
            config.resetPlayback(to: displayDefaults)
        }

        restoreProposedWallpaperSession(for: screen, configuration: config)
        Logger.info("Reset display settings for screen \(screen.id)", category: .screenManager)
    }

    /// Copies the active wallpaper + per-screen settings from `source` onto every other registered screen, restoring each runtime session so the new content shows immediately.
    func applyConfigurationToAllDisplays(from source: Screen) {
        guard !isTerminating,
              screens.count > 1,
              let template = configurationStore.get(for: source.id, fingerprint: source.displayFingerprint) else { return }

        for target in screens where target.id != source.id {
            // Shared with `applyScheme`: one rebind implementation, so the two
            // paths cannot drift on which identity fields have to move.
            let copy = template.reboundToDisplay(
                target.id,
                fingerprint: target.displayFingerprint
            )
            restoreProposedWallpaperSession(for: target, configuration: copy)
            Logger.info("Apply to All: copied configuration from screen \(source.id) → \(target.id)", category: .screenManager)
        }
    }
    
    func reloadAllScreens() {
        guard !isTerminating else { return }
        Logger.notice("Reloading all screens", category: .screenManager)

        _ = persistence.pruneInvalidConfigurations()

        let configurations = configurationStore.loadAll()
        configurations.forEach { primeBookmarkDisplayNames(from: $0) }

        for screen in screens {
            guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
                releaseRuntimeSession(screen)
                continue
            }

            restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
        }

        Logger.notice("All screens reloaded", category: .screenManager)
    }

    /// Move per-display settings from a panel's pre-UUID key to its current one.
    /// Only panels that report EDID serial 0 have a key change at all; this runs
    /// on every refresh so a display that was unplugged during the upgrade still
    /// gets migrated the first time it comes back.
    private func migrateLegacyDisplayIdentities(of newScreens: [Screen]) {
        let mappings: [LegacyFingerprintMapping] = newScreens.compactMap { screen in
            guard let legacy = screen.legacyDisplayFingerprint else { return nil }
            return LegacyFingerprintMapping(legacy: legacy, current: screen.displayFingerprint)
        }

        let defaults = UserDefaults.appScoped()
        var sidebarOrder = SidebarDisplayOrder.decode(
            defaults.data(forKey: SidebarDisplayOrder.preferencesKey) ?? Data()
        )
        let sidebarOrderBefore = sidebarOrder

        let migratedNames = Self.migrateLegacyFingerprintKeys(screenNames, mappings: mappings)
        let migratedOverlays = Self.migrateLegacyFingerprintKeys(monitorOverlays, mappings: mappings)
        let namesChanged = migratedNames != screenNames
        let overlaysChanged = migratedOverlays != monitorOverlays
        screenNames = migratedNames
        monitorOverlays = migratedOverlays

        for screen in newScreens {
            guard let legacy = screen.legacyDisplayFingerprint else { continue }
            configurationStore.migrateFingerprint(from: legacy, to: screen.displayFingerprint, preferring: screen.id)
            // Without this the saved entry keeps the pre-UUID key, matches
            // neither by (ID, fingerprint) nor by fingerprint, and the user's
            // sidebar order silently resets to system order.
            sidebarOrder = SidebarDisplayOrder.rekeyed(
                sidebarOrder, displayID: screen.id, from: legacy, to: screen.displayFingerprint
            )
        }

        if namesChanged {
            SettingsManager.shared.saveScreenNames(screenNames)
        }
        if overlaysChanged {
            SettingsManager.shared.saveMonitorOverlays(monitorOverlays)
        }
        if sidebarOrder != sidebarOrderBefore {
            defaults.set(SidebarDisplayOrder.encode(sidebarOrder), forKey: SidebarDisplayOrder.preferencesKey)
        }
    }

    /// Migrates every value keyed by a legacy fingerprint to its current-key counterpart. Two-phase so a legacy key shared by multiple screens (two
    /// same-model panels both reporting EDID serial 0) is cloned to every mapped current key instead of being consumed by whichever screen is processed first —
    /// existing current-key values always win, and legacy keys are only dropped after all clones are assigned.
    nonisolated static func migrateLegacyFingerprintKeys<Value>(
        _ dict: [String: Value],
        mappings: [LegacyFingerprintMapping]
    ) -> [String: Value] {
        var result = dict
        var consumedLegacyKeys: Set<String> = []
        for mapping in mappings {
            guard dict[mapping.current] == nil, let value = dict[mapping.legacy] else { continue }
            result[mapping.current] = value
            consumedLegacyKeys.insert(mapping.legacy)
        }
        for legacy in consumedLegacyKeys {
            result.removeValue(forKey: legacy)
        }
        return result
    }

    /// Rename a display. Blank input, or the system's own name, clears the
    /// override rather than storing a redundant copy of it.
    func setCustomName(_ name: String?, for screen: Screen) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = screen.displayFingerprint
        if trimmed.isEmpty || trimmed == screen.systemName {
            screenNames.removeValue(forKey: key)
        } else {
            screenNames[key] = trimmed
        }
        screen.customName = screenNames[key]
        SettingsManager.shared.saveScreenNames(screenNames)
    }
}
