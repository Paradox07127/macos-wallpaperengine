import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Playlist + schedule automation on top of `WallpaperAutomationCoordinator`.
@MainActor
final class WallpaperAutomationOrchestrator {
    private let configurationStore: WallpaperConfigurationStore
    private let automationCoordinator: WallpaperAutomationCoordinator
    private let playableVideoLoader: any PlayableVideoLoading
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let recordBookmarkDisplayName: @MainActor (Data, String?) -> Void
    private let setupPreparedVideoPlayback: @MainActor (
        URL,
        Screen,
        ScreenConfiguration,
        @MainActor @escaping () -> Bool
    ) -> Void
    private let restoreProposedConfiguration: @MainActor (
        Screen,
        ScreenConfiguration
    ) -> Void
    private let bumpTransition: @MainActor (CGDirectDisplayID) -> Int
    private let isCurrentTransition: @MainActor (Int, CGDirectDisplayID) -> Bool
    private var isMonitoring = false
    private var isSuspendedForUserAbsence = false
    private struct PendingValidation {
        let generation: Int
        let task: Task<Void, Never>
    }
    private var validationTasksByScreen: [CGDirectDisplayID: PendingValidation] = [:]

    init(
        configurationStore: WallpaperConfigurationStore,
        automationCoordinator: WallpaperAutomationCoordinator,
        playableVideoLoader: any PlayableVideoLoading,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        recordBookmarkDisplayName: @MainActor @escaping (Data, String?) -> Void,
        setupPreparedVideoPlayback: @MainActor @escaping (
            URL,
            Screen,
            ScreenConfiguration,
            @MainActor @escaping () -> Bool
        ) -> Void,
        restoreProposedConfiguration: @MainActor @escaping (
            Screen,
            ScreenConfiguration
        ) -> Void,
        bumpTransition: @MainActor @escaping (CGDirectDisplayID) -> Int,
        isCurrentTransition: @MainActor @escaping (Int, CGDirectDisplayID) -> Bool
    ) {
        self.configurationStore = configurationStore
        self.automationCoordinator = automationCoordinator
        self.playableVideoLoader = playableVideoLoader
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.recordBookmarkDisplayName = recordBookmarkDisplayName
        self.setupPreparedVideoPlayback = setupPreparedVideoPlayback
        self.restoreProposedConfiguration = restoreProposedConfiguration
        self.bumpTransition = bumpTransition
        self.isCurrentTransition = isCurrentTransition
    }

    // MARK: - Playlist

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.playlistBookmarks = bookmarks.isEmpty ? nil : bookmarks
        saveConfiguration(config)
    }

    /// Promotes to primary without reordering (star stays put).
    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.savedVideoBookmarkData != bookmark else { return }

        let combined = config.combinedPlaylist
        guard let newPrimaryPosition = combined.firstIndex(of: bookmark) else { return }

        let extras = combined.enumerated().compactMap { idx, b -> Data? in
            idx == newPrimaryPosition ? nil : b
        }

        config.savedVideoBookmarkData = bookmark
        config.activeWallpaper = .video(bookmarkData: bookmark)
        config.playlistBookmarks = extras.isEmpty ? nil : extras
        config.playlistPrimaryIndex = newPrimaryPosition
        config.playlistCursorIndex = newPrimaryPosition
        restoreProposedConfiguration(screen, config)
    }

    /// Keeps the active bookmark when only playlist order changed.
    func replacePlaylist(ordered: [Data], primary: Data, for screen: Screen) {
        guard let primaryIndex = ordered.firstIndex(of: primary) else { return }
        let existing = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
        var config = existing ?? ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: primary
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())

        let oldCombined = config.combinedPlaylist
        let oldCursor = config.playlistCursorIndex ?? 0
        let oldActive: Data? = oldCursor < oldCombined.count ? oldCombined[oldCursor] : config.videoBookmarkData

        let primaryChanged = config.savedVideoBookmarkData != primary
        // Deleted playing bookmark: reload so the player swaps to the new cursor.
        let activeWasRemoved = oldActive.map { !ordered.contains($0) } ?? false
        let extras = ordered.enumerated().compactMap { idx, b -> Data? in
            idx == primaryIndex ? nil : b
        }
        config.savedVideoBookmarkData = primary
        config.playlistBookmarks = extras.isEmpty ? nil : extras
        config.playlistPrimaryIndex = primaryIndex

        if primaryChanged {
            config.playlistCursorIndex = primaryIndex
            config.activeWallpaper = .video(bookmarkData: primary)
        } else {
            let resolved = PlaylistPolicy.resolveCursor(activeBookmark: oldActive, in: ordered)
            config.playlistCursorIndex = resolved
            if resolved < ordered.count {
                config.activeWallpaper = .video(bookmarkData: ordered[resolved])
            }
        }
        if existing == nil || primaryChanged || activeWasRemoved {
            restoreProposedConfiguration(screen, config)
        } else {
            saveConfiguration(config)
        }
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let combined = config.combinedPlaylist
        guard index >= 0, index < combined.count else { return }
        applyCursor(index, combined: combined, screen: screen, label: "jumping")
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.shufflePlaylist != shuffle else { return }
        config.shufflePlaylist = shuffle
        saveConfiguration(config)
    }

    func advancePlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperMode == .playlist else { return }

        let combined = config.combinedPlaylist
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let nextCursor = PlaylistPolicy.nextCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyCursor(nextCursor, combined: combined, screen: screen, label: "advancing")
    }

    func regressPlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperMode == .playlist else { return }

        let combined = config.combinedPlaylist
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let prevCursor = PlaylistPolicy.previousCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyCursor(prevCursor, combined: combined, screen: screen, label: "regressing")
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let updated = config.withUpdatedActiveBookmark(bookmarkData)
        saveConfiguration(updated)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperType == .video,
              config.hasConfiguredVideoSource,
              config.wallpaperMode != mode else { return }
        config.wallpaperMode = mode
        saveConfiguration(config)

        switch mode {
        case .playlist:
            let combined = config.combinedPlaylist
            guard !combined.isEmpty else { return }
            let cursor = max(0, min(config.playlistCursorIndex ?? 0, combined.count - 1))
            applyCursor(cursor, combined: combined, screen: screen, label: "entering playlist mode")
        case .schedule:
            checkAndApplySchedule(for: screen)
        }
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.playlistRotationMinutes = minutes
        saveConfiguration(config)
    }

    private func applyCursor(
        _ cursor: Int,
        combined: [Data],
        screen: Screen,
        label: String
    ) {
        guard !isSuspendedForUserAbsence else { return }
        guard cursor < combined.count else { return }
        let targetBookmark = combined[cursor]

        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            targetBookmark,
            target: .transient
        ) else { return }
        let url = resolved.url
        let resolvedBookmark = resolved.bookmarkData
        recordBookmarkDisplayName(resolvedBookmark, url.lastPathComponent)

        let screenID = screen.id
        validationTasksByScreen[screenID]?.task.cancel()
        let generation = bumpTransition(screenID)
        let videoLoader = playableVideoLoader

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearValidationTask(for: screenID, generation: generation) }
            do {
                try Task.checkCancellation()
                guard !self.isSuspendedForUserAbsence else { return }
                try await videoLoader.validatePlayableVideo(at: url)
                try Task.checkCancellation()
                guard !self.isSuspendedForUserAbsence,
                      self.isCurrentTransition(generation, screenID),
                      let liveScreen = self.screensProvider().first(where: { $0.id == screenID }),
                      var liveConfig = self.configurationStore.get(for: screenID) else { return }
                liveConfig.playlistCursorIndex = cursor
                liveConfig.activeWallpaper = .video(bookmarkData: resolvedBookmark)
                if resolved.didRefresh {
                    self.replacePlaylistBookmark(in: &liveConfig, cursor: cursor, bookmarkData: resolvedBookmark)
                }
                Logger.info("Playlist: \(label) to \(url.lastPathComponent) (cursor \(cursor)) for screen \(screenID)", category: .screenManager)
                self.setupPreparedVideoPlayback(
                    url,
                    liveScreen,
                    liveConfig,
                    { [weak self] in
                        self?.isSuspendedForUserAbsence == false
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                Logger.error("Playlist \(label) failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
        validationTasksByScreen[screenID] = PendingValidation(
            generation: generation,
            task: task
        )
    }

    // MARK: - Schedule

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.scheduleSlots = slots
        saveConfiguration(config)

        if slots != nil {
            checkAndApplySchedule(for: screen)
        }
    }

    func checkAndApplySchedule(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }

        let currentHour = Calendar.current.component(.hour, from: Date())

        switch SchedulePolicy.decision(for: config, hour: currentHour) {
        case .none:
            return

        case .applySlot(let slot, let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "switching to \(slot.label) wallpaper",
                for: screen
            ) { config in
                config.applyScheduledBookmark(bookmark)
            }

        case .restorePrimary(let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "slot window ended, restoring primary",
                for: screen
            ) { config in
                _ = config.activateSavedVideoWallpaper()
            }
        }
    }

    private func performScheduledSwitch(
        bookmark: Data,
        logLabel: String,
        for screen: Screen,
        mutate: @escaping (inout ScreenConfiguration) -> Void
    ) {
        guard !isSuspendedForUserAbsence else { return }
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmark,
            target: .transient
        ) else { return }
        let url = resolved.url
        let resolvedBookmark = resolved.bookmarkData
        recordBookmarkDisplayName(resolvedBookmark, url.lastPathComponent)

        let screenID = screen.id
        validationTasksByScreen[screenID]?.task.cancel()
        let generation = bumpTransition(screenID)
        let videoLoader = playableVideoLoader

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearValidationTask(for: screenID, generation: generation) }
            do {
                try Task.checkCancellation()
                guard !self.isSuspendedForUserAbsence else { return }
                try await videoLoader.validatePlayableVideo(at: url)
                try Task.checkCancellation()
                guard !self.isSuspendedForUserAbsence,
                      self.isCurrentTransition(generation, screenID),
                      let liveScreen = self.screensProvider().first(where: { $0.id == screenID }),
                      var liveConfig = self.configurationStore.get(for: screenID) else { return }
                Logger.info("Schedule: \(logLabel) for screen \(screenID)", category: .screenManager)
                mutate(&liveConfig)
                if resolved.didRefresh {
                    self.replaceScheduledBookmark(in: &liveConfig, original: bookmark, refreshed: resolvedBookmark)
                }
                self.setupPreparedVideoPlayback(
                    url,
                    liveScreen,
                    liveConfig,
                    { [weak self] in
                        self?.isSuspendedForUserAbsence == false
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                Logger.error("Schedule transition failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
        validationTasksByScreen[screenID] = PendingValidation(
            generation: generation,
            task: task
        )
    }

    // MARK: - Automation start

    func startMonitoring() {
        isMonitoring = true
        startCoordinator(runInitialScheduleCheck: true)
    }

    private func startCoordinator(runInitialScheduleCheck: Bool) {
        guard !isSuspendedForUserAbsence else {
            automationCoordinator.stop()
            return
        }
        automationCoordinator.start(
            screenProvider: { [weak self] in
                self?.screensProvider() ?? []
            },
            configurationProvider: { [weak self] screenID in
                self?.configurationStore.get(for: screenID)
            },
            scheduleHandler: { [weak self] screen in
                self?.checkAndApplySchedule(for: screen)
            },
            playlistHandler: { [weak self] screen in
                self?.advancePlaylist(for: screen)
            },
            runInitialScheduleCheck: runInitialScheduleCheck
        )
    }

    func stopMonitoring() {
        isMonitoring = false
        automationCoordinator.stop()
        cancelValidationTasks()
    }

    func refreshMonitoringIfActive(runInitialScheduleCheck: Bool = false) {
        guard isMonitoring else { return }
        startCoordinator(runInitialScheduleCheck: runInitialScheduleCheck)
    }

    /// Absence is an energy boundary: stop the timer so sleep/lock cannot decode candidates.
    func suspendForUserAbsence() {
        guard !isSuspendedForUserAbsence else { return }
        isSuspendedForUserAbsence = true
        automationCoordinator.stop()
        cancelValidationTasks()
        // Invalidate transition generations so in-flight prep handed off before absence is cancelled.
        for screen in screensProvider() {
            _ = bumpTransition(screen.id)
        }
    }

    func resumeAfterUserAbsence() {
        guard isSuspendedForUserAbsence else { return }
        isSuspendedForUserAbsence = false
        guard isMonitoring else { return }
        startCoordinator(runInitialScheduleCheck: true)
    }

    private func clearValidationTask(
        for screenID: CGDirectDisplayID,
        generation: Int
    ) {
        guard validationTasksByScreen[screenID]?.generation == generation else { return }
        validationTasksByScreen[screenID] = nil
    }

    private func cancelValidationTasks() {
        let pending = Array(validationTasksByScreen.values)
        validationTasksByScreen.removeAll()
        for validation in pending {
            validation.task.cancel()
        }
    }

    private func replacePlaylistBookmark(
        in config: inout ScreenConfiguration,
        cursor: Int,
        bookmarkData: Data
    ) {
        if cursor == 0 {
            config.savedVideoBookmarkData = bookmarkData
        } else if var additional = config.playlistBookmarks,
                  additional.indices.contains(cursor - 1) {
            additional[cursor - 1] = bookmarkData
            config.playlistBookmarks = additional
        }
    }

    private func replaceScheduledBookmark(
        in config: inout ScreenConfiguration,
        original: Data,
        refreshed: Data
    ) {
        if config.savedVideoBookmarkData == original {
            config.savedVideoBookmarkData = refreshed
        }

        if var slots = config.scheduleSlots {
            for index in slots.indices where slots[index].videoBookmarkData == original {
                slots[index].videoBookmarkData = refreshed
            }
            config.scheduleSlots = slots
        }

        config.activeWallpaper = .video(bookmarkData: refreshed)
    }
}
