import CoreGraphics
import Foundation
import LiveWallpaperCore

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
        if let queue = config.wallpaperQueue {
            guard queue.indices.contains(index) else { return }
            applyEntry(queue[index], cursor: index, for: screen)
            return
        }
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
              config.canNavigatePlaylist else { return }

        if let queue = config.wallpaperQueue {
            stepQueue(queue, configuration: config, forward: true, for: screen)
            return
        }
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
              config.canNavigatePlaylist else { return }

        if let queue = config.wallpaperQueue {
            stepQueue(queue, configuration: config, forward: false, for: screen)
            return
        }
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
              config.wallpaperQueue != nil || config.hasConfiguredVideoSource,
              config.wallpaperMode != mode else { return }
        if mode == .schedule, config.scheduleFallback == nil, config.wallpaperQueue != nil {
            config.scheduleFallback = WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin)
        }
        config.wallpaperMode = mode
        saveConfiguration(config)

        switch mode {
        case .playlist:
            if let queue = config.wallpaperQueue {
                guard !queue.isEmpty else { return }
                let cursor = max(0, min(config.playlistCursorIndex ?? 0, queue.count - 1))
                applyEntry(queue[cursor], cursor: cursor, for: screen)
                return
            }
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

    func updateAutomation(
        queue: [WallpaperQueueEntry], slots: [ScheduleSlot], mode: WallpaperMode,
        rotationMinutes: Int?, shuffle: Bool, for screen: Screen
    ) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              mode != .schedule || slots.allSatisfy({ SchedulePolicy.conflicts(slot: $0, against: slots).isEmpty }) else { return }
        let previousMode = config.wallpaperMode
        let previousQueue = config.effectiveWallpaperQueue
        let cursor = config.playlistCursorIndex ?? 0
        let currentID = previousQueue.indices.contains(cursor) ? previousQueue[cursor].id : nil
        if mode == .schedule, config.scheduleFallback == nil {
            let legacyPrimary = previousMode == .schedule && config.wallpaperQueue == nil
                ? config.savedVideoBookmarkData : nil
            config.scheduleFallback = WallpaperQueueEntry(
                title: "", content: legacyPrimary.map { .video(bookmarkData: $0, packageEntryName: config.savedVideoPackageEntryName) } ?? config.activeWallpaper,
                origin: legacyPrimary == nil ? config.wpeOrigin : nil
            )
        }
        var seen: Set<String> = []
        config.wallpaperQueue = queue.filter { seen.insert($0.id).inserted }
        config.playlistCursorIndex = config.wallpaperQueue?.firstIndex(where: { $0.id == currentID }) ?? 0
        config.scheduleSlots = slots.isEmpty ? nil : slots
        config.wallpaperMode = mode
        config.playlistRotationMinutes = rotationMinutes.flatMap { $0 > 0 ? $0 : nil }
        config.shufflePlaylist = shuffle
        saveConfiguration(config)
        if mode == .schedule {
            checkAndApplySchedule(for: screen)
        } else if previousMode != .playlist, let entries = config.wallpaperQueue, !entries.isEmpty {
            let index = config.playlistCursorIndex ?? 0
            applyEntry(entries[index], cursor: index, for: screen)
        }
    }

    func replaceWallpaperQueue(_ entries: [WallpaperQueueEntry], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let oldQueue = config.effectiveWallpaperQueue
        let oldCursor = config.playlistCursorIndex ?? 0
        let currentID = oldQueue.indices.contains(oldCursor) ? oldQueue[oldCursor].id : nil
        var seen: Set<String> = []
        let unique = entries.filter { seen.insert($0.id).inserted }
        config.wallpaperQueue = unique
        config.playlistCursorIndex = unique.firstIndex(where: { $0.id == currentID }) ?? 0
        saveConfiguration(config)
    }

    private func stepQueue(_ queue: [WallpaperQueueEntry], configuration: ScreenConfiguration, forward: Bool, for screen: Screen) {
        let current = configuration.playlistCursorIndex ?? 0
        let next = forward
            ? PlaylistPolicy.nextCursor(currentCursor: current, playlistCount: queue.count, shuffle: configuration.shufflePlaylist)
            : PlaylistPolicy.previousCursor(currentCursor: current, playlistCount: queue.count, shuffle: configuration.shufflePlaylist)
        guard let next, queue.indices.contains(next) else { return }
        applyEntry(queue[next], cursor: next, for: screen)
    }

    private func applyEntry(_ entry: WallpaperQueueEntry, cursor: Int?, for screen: Screen) {
        guard !isSuspendedForUserAbsence,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        validationTasksByScreen[screen.id]?.task.cancel()
        validationTasksByScreen[screen.id] = nil
        var proposed = config.applyingAutomationEntry(entry)
        if let cursor {
            proposed.playlistCursorIndex = cursor
        }
        // The product restore path owns validation, transition generations and the commit.
        restoreProposedConfiguration(screen, proposed)
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

        case let .applyWallpaper(entry):
            applyEntry(entry, cursor: nil, for: screen)

        case let .applySlot(slot, bookmark):
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
