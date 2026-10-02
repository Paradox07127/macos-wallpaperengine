import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
    #if !LITE_BUILD
    typealias WPEProjectApplyOutcome = WPEImportCoordinator.ApplyOutcome

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        guard !isTerminating else {
            return .rejected(reason: "Application terminating")
        }
        beginExplicitWallpaperSelection(for: screen)
        let id = wallpaperLoads.begin(for: screen, title: folderURL.lastPathComponent, sourceURL: folderURL)
        let outcome = await wpeImportCoordinator.importProject(at: folderURL, for: screen)
        if wallpaperLoads.attempt(for: screen)?.id == id, wallpaperLoads.attempt(for: screen)?.phase == .importing {
            if case .rejected(let reason) = outcome {
                failWallpaperAttempt(id, for: screen, cause: WallpaperFailureCause(code: "import.rejected", reason: reason), stage: .importing)
            } else { wallpaperLoads.clear(for: screen, matching: id) }
        }
        return outcome
    }

    @discardableResult
    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async -> WallpaperFailureSnapshot? {
        guard !isTerminating else { return nil }
        beginExplicitWallpaperSelection(for: screen)
        let id = wallpaperLoads.begin(for: screen, title: entry.origin.title, origin: entry.origin)
        await wpeImportCoordinator.activateHistoryEntry(entry, for: screen)
        if wallpaperLoads.attempt(for: screen)?.id == id, wallpaperLoads.attempt(for: screen)?.phase == .importing {
            if let error = wpeImportTracker.error(for: screen.id) {
                failWallpaperAttempt(id, for: screen, cause: WallpaperFailureCause(code: "import.source", reason: error.localizedDescription), stage: .importing)
            } else { wallpaperLoads.clear(for: screen, matching: id) }
        }
        let attempt = wallpaperLoads.attempt(for: screen)
        return attempt?.id == id ? attempt?.failure : nil
    }

    func removeWPEImport(workshopID: String) {
        guard !isTerminating else { return }
        let cacheRelativePath = "wpe-cache/\(workshopID)"
        clearActiveWPEWallpaper(
            matchingOrigin: { $0.workshopID == workshopID },
            matchingScene: { $0.workshopID == workshopID || $0.cacheRelativePath == cacheRelativePath }
        )
        wpeImportCoordinator.removeWorkshop(workshopID: workshopID)
    }
    /// Installed-page CAS delete: only an exact persisted identity match may
    /// disturb live sessions or scrub configuration references.
    @discardableResult
    func removeWPEImport(workshopID: String, matchingImportedAt importedAt: Date) -> Bool {
        let removed = SettingsManager.shared.loadGlobalSettings().recentWPEImports.first {
            $0.origin.workshopID == workshopID && $0.importedAt == importedAt
        }?.origin
        guard !isTerminating,
              let removed,
              SettingsManager.shared.removeWPEImport(
                  workshopID: workshopID,
                  matchingImportedAt: importedAt
              ) else { return false }
        // A local copy keeps its manifest's Workshop id, so the id alone would also match the Steam item it was copied from.
        let matchesRemoved = { (origin: WPEOrigin) in SettingsManager.isSameWPEItem(origin, removed) }
        clearActiveWPEWallpaper(
            matchingOrigin: matchesRemoved,
            matchingScene: { $0.cacheRelativePath == removed.cacheRelativePath }
        )
        for var config in configurationStore.loadAll() where config.wpeOrigin.map(matchesRemoved) == true {
            config.wpeOrigin = nil
            saveConfiguration(config)
        }
        return true
    }
    private func clearActiveWPEWallpaper(
        matchingOrigin: (WPEOrigin) -> Bool,
        matchingScene: (SceneDescriptor) -> Bool
    ) {
        // If a screen is currently rendering the scene being deleted, switch it away FIRST — otherwise its live renderer keeps reading the cache files that the delete is about to move to the Trash.
        WallpaperSwitchGroup.$current.withValue(WallpaperSwitchGroup(pace: .manual)) {
            for screen in screens {
                if let origin = wallpaperLoads.attempt(for: screen)?.origin, matchingOrigin(origin) {
                    beginExplicitWallpaperSelection(for: screen)
                }
                guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { continue }
                let matchesScene: Bool
                if case .scene(let descriptor) = config.activeWallpaper {
                    matchesScene = matchingScene(descriptor)
                } else {
                    matchesScene = false
                }
                guard matchesScene || config.wpeOrigin.map(matchingOrigin) == true else { continue }
                clearWallpaperOfType(config.activeWallpaper.wallpaperType, for: screen)
            }
        }
    }
    #endif

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateEffectConfig(effectConfig, for: screen)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateParticleEffect(effect, for: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateParticleDensity(density, for: screen)
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.setWeatherReactive(enabled, for: screen)
    }

    func setWeatherWind(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.setWeatherWind(enabled, for: screen)
    }

    func setWeatherIntensity(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.setWeatherIntensity(enabled, for: screen)
    }

    func startWeatherMonitoring() {
        guard !isTerminating else { return }
        effectsCoordinator.startWeatherMonitoring()
    }

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updatePlaylistBookmarks(bookmarks, for: screen)
    }

    func updateWallpaperAutomation(
        queue: [WallpaperQueueEntry], slots: [ScheduleSlot], fallback: WallpaperQueueEntry? = nil, mode: WallpaperMode,
        rotationMinutes: Int?, shuffle: Bool, libraryShuffleRotationMinutes: Int? = nil, for screen: Screen
    ) {
        guard !isTerminating else { return }
        automationOrchestrator.updateAutomation(
            queue: queue, slots: slots, fallback: fallback, mode: mode, rotationMinutes: rotationMinutes,
            shuffle: shuffle, libraryShuffleRotationMinutes: libraryShuffleRotationMinutes, for: screen
        )
    }

    func replaceWallpaperQueue(_ entries: [WallpaperQueueEntry], for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.replaceWallpaperQueue(entries, for: screen)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        automationOrchestrator.setPrimaryVideo(bookmark: bookmark, for: screen)
    }

    func replacePlaylist(ordered: [Data], primary: Data, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        automationOrchestrator.playPlaylistEntry(at: index, for: screen)
    }

    func previewWallpaperQueueEntry(_ entry: WallpaperQueueEntry, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        automationOrchestrator.previewEntry(entry, for: screen)
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateShufflePlaylist(shuffle, for: screen)
    }

    func advancePlaylist(for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.advancePlaylist(for: screen)
    }

    var automationTime: Date { automationCoordinator.currentTime }

    func clearAutomationFailure(_ entryID: String, for screen: Screen) {
        guard !isTerminating, var config = getConfiguration(for: screen) else { return }
        config.automationFailures[entryID] = nil
        saveConfiguration(config)
    }

    /// Awaits the actual first-frame/commit result; no polling timer or detached retry loop.
    func prepareAutomationWallpaper(
        _ configuration: ScreenConfiguration, for screen: Screen, source: AutomaticSwitchMark.Source?,
        isStillIntended: @MainActor @escaping () -> Bool
    ) async -> WallpaperPreparationResult {
        guard !isTerminating, !isUserAbsent, wallpapersGloballyEnabled,
              screens.contains(where: { $0 === screen }) else { return .cancelled }
        wallpaperLoads.clear(for: screen)
        let commit: @MainActor (_ saves: Bool) -> Bool = { [weak self, weak screen] saves in
            guard let self, let screen, !isTerminating, !isUserAbsent, isStillIntended() else { return false }
            // Marked before the save: the automation panel reads the serial in the change notification.
            if let source {
                noteAutomaticSwitch(on: screen, source: source)
            }
            if saves {
                saveConfiguration(configuration)
            }
            return true
        }
        return await withCheckedContinuation { continuation in
            if case let .video(bookmark, _) = configuration.activeWallpaper {
                guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient) else {
                    continuation.resume(returning: .failed)
                    return
                }
                var effective = configuration
                if resolved.didRefresh { effective = effective.withUpdatedActiveBookmark(resolved.bookmarkData) }
                // setupVideoPlayback saves `effective` itself once the commit passes, so this commit must not save too.
                playbackCoordinator.setupVideoPlayback(
                    url: resolved.url, screen: screen, proposedConfiguration: effective, beforeCommit: { commit(false) },
                    completion: { continuation.resume(returning: $0) }
                )
            } else {
                restoreWallpaperSession(
                    for: screen, configuration: configuration, preservingState: false, intent: .proposal,
                    inspectPreparation: false,
                    beforeCommit: { commit(true) }, sceneCompletion: { result, _ in continuation.resume(returning: result) }
                )
            }
        }
    }

    func advanceLibraryShuffle(for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.advanceLibraryShuffle(for: screen)
    }

    func regressPlaylist(for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.regressPlaylist(for: screen)
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.replaceActiveBookmark(bookmarkData, for: screen)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateWallpaperMode(mode, for: screen)
    }

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateScheduleSlots(slots, for: screen)
    }

    func resumeSchedule(for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        automationOrchestrator.checkAndApplySchedule(for: screen, force: true)
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updatePlaylistRotationMinutes(minutes, for: screen)
    }
}
