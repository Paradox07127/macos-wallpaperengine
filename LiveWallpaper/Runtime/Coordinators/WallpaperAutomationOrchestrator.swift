import CoreGraphics
import Foundation
import LiveWallpaperCore

/// The latest schedule or playlist switch on a display; `serial` counts them.
struct AutomaticSwitchMark: Equatable {
    enum Source: Equatable {
        case schedule, playlist, libraryShuffle
    }

    let serial: Int
    let source: Source
}

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
    /// The source is nil for switches that are not automatic (picking a row, entering a mode); those leave no mark.
    typealias AutomationPreparer = @MainActor (
        Screen, ScreenConfiguration, AutomaticSwitchMark.Source?, @MainActor @escaping () -> Bool
    ) async -> WallpaperPreparationResult
    private let automationAllowed: @MainActor () -> Bool
    private let prepareAutomation: AutomationPreparer
    private var automaticSelectionSerial = 0
    private var automaticSelections: [CGDirectDisplayID: Int] = [:]
    private let libraryEntries: @MainActor () -> [WallpaperQueueEntry]
    private let libraryEntryAvailable: @MainActor (WallpaperQueueEntry) async -> Bool
    private let now: @MainActor () -> Date
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
        isCurrentTransition: @MainActor @escaping (Int, CGDirectDisplayID) -> Bool,
        now: @MainActor @escaping () -> Date = { Date() },
        prepareAutomation: @escaping AutomationPreparer,
        automationAllowed: @MainActor @escaping () -> Bool = { true },
        libraryEntries: @MainActor @escaping () -> [WallpaperQueueEntry] = { [] },
        libraryEntryAvailable: @MainActor @escaping (WallpaperQueueEntry) async -> Bool = { entry in
            await LibraryContentLocator.locate(content: entry.content, wpeOrigin: entry.origin).isAvailable
        }
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
        self.now = now
        self.prepareAutomation = prepareAutomation
        self.automationAllowed = automationAllowed
        self.libraryEntries = libraryEntries
        self.libraryEntryAvailable = libraryEntryAvailable
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
        let oldActive: Data? = oldCombined.indices.contains(oldCursor) ? oldCombined[oldCursor] : config.videoBookmarkData

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

    func previewEntry(_ entry: WallpaperQueueEntry, for screen: Screen) {
        guard !isSuspendedForUserAbsence,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        validationTasksByScreen.removeValue(forKey: screen.id)?.task.cancel()
        automaticSelections[screen.id] = nil
        restoreProposedConfiguration(screen, config.applyingAutomationEntry(entry))
    }

    func cancelAutomaticSelection(for screenID: CGDirectDisplayID) {
        validationTasksByScreen.removeValue(forKey: screenID)?.task.cancel()
        automaticSelections[screenID] = nil
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
        let queue = config.effectiveWallpaperQueue
        let current = max(0, min(config.playlistCursorIndex ?? 0, queue.count - 1))
        var indices = queue.indices.filter { $0 != current }
        if config.shufflePlaylist {
            indices.shuffle()
        } else {
            indices.sort { lhs, rhs in
                let left = lhs - current + queue.count
                let right = rhs - current + queue.count
                return left % queue.count < right % queue.count
            }
        }
        startAutomaticSelection(indices.map { (queue[$0], Optional($0)) }, source: .playlist, for: screen)
    }

    func regressPlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.canNavigatePlaylist else { return }
        let queue = config.effectiveWallpaperQueue
        let current = max(0, min(config.playlistCursorIndex ?? 0, queue.count - 1))
        var indices = queue.indices.filter { $0 != current }
        if config.shufflePlaylist {
            indices.shuffle()
        } else {
            indices.sort { lhs, rhs in
                let left = current - lhs + queue.count
                let right = current - rhs + queue.count
                return left % queue.count < right % queue.count
            }
        }
        startAutomaticSelection(indices.map { (queue[$0], Optional($0)) }, source: .playlist, for: screen)
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let updated = config.withUpdatedActiveBookmark(bookmarkData)
        saveConfiguration(updated)
        if let original = config.activeWallpaper.activeVideoBookmarkData {
            SchemeStore.shared.replaceVideoBookmark(matching: original, with: bookmarkData)
        }
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              mode == .libraryShuffle || config.wallpaperQueue != nil || config.hasConfiguredVideoSource,
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
            checkAndApplySchedule(for: screen, force: true)
        case .libraryShuffle:
            advanceLibraryShuffle(for: screen)
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
        queue: [WallpaperQueueEntry], slots: [ScheduleSlot], fallback: WallpaperQueueEntry? = nil, mode: WallpaperMode,
        rotationMinutes: Int?, shuffle: Bool, libraryShuffleRotationMinutes: Int? = nil, for screen: Screen
    ) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              mode != .schedule || slots.allSatisfy({ SchedulePolicy.conflicts(slot: $0, against: slots).isEmpty }) else { return }
        let previousMode = config.wallpaperMode
        let previousQueue = config.effectiveWallpaperQueue
        let cursor = config.playlistCursorIndex ?? 0
        let currentID = previousQueue.indices.contains(cursor) ? previousQueue[cursor].id : nil
        if let fallback {
            config.scheduleFallback = fallback
        } else if mode == .schedule, config.scheduleFallback == nil {
            config.scheduleFallback = SchedulePolicy.initialFallback(
                for: config, current: WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin)
            )
        }
        var seen: Set<String> = []
        config.wallpaperQueue = queue.filter { seen.insert($0.id).inserted }
        let keptCursor = config.wallpaperQueue?.firstIndex(where: { $0.id == currentID })
        config.playlistCursorIndex = keptCursor ?? 0
        config.scheduleSlots = slots.isEmpty ? nil : slots
        config.wallpaperMode = mode
        config.playlistRotationMinutes = rotationMinutes.flatMap { $0 > 0 ? $0 : nil }
        config.shufflePlaylist = shuffle
        if let libraryShuffleRotationMinutes {
            config.libraryShuffleRotationMinutes = max(1, libraryShuffleRotationMinutes)
        }
        saveConfiguration(config)
        if mode == .libraryShuffle {
            if previousMode != .libraryShuffle {
                advanceLibraryShuffle(for: screen)
            }
        } else if mode == .schedule {
            checkAndApplySchedule(for: screen, force: true)
        } else if previousMode != .playlist || (currentID != nil && keptCursor == nil),
                  let entries = config.wallpaperQueue, !entries.isEmpty {
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

    private func applyEntry(_ entry: WallpaperQueueEntry, cursor: Int?, source: AutomaticSwitchMark.Source? = nil, for screen: Screen) {
        guard !isSuspendedForUserAbsence,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        if automationAllowed() {
            var candidates: [(WallpaperQueueEntry, Int?)] = [(entry, cursor)]
            if config.wallpaperMode == .schedule, let fallback = config.scheduleFallback,
               !SchedulePolicy.isSameContent(fallback.content, entry.content) {
                candidates.append((fallback, nil))
            }
            startAutomaticSelection(candidates, source: source, for: screen)
            return
        }
        validationTasksByScreen[screen.id]?.task.cancel()
        validationTasksByScreen[screen.id] = nil
        var proposed = config.applyingAutomationEntry(entry)
        if let cursor {
            proposed.playlistCursorIndex = cursor
        }
        // The product restore path owns validation, transition generations and the commit.
        restoreProposedConfiguration(screen, proposed)
    }

    // MARK: - Library shuffle

    func advanceLibraryShuffle(for screen: Screen) {
        guard !isSuspendedForUserAbsence,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperMode == .libraryShuffle else { return }
        let candidates = LibraryShufflePolicy.candidates(in: libraryEntries(), excluding: config.activeWallpaper).shuffled()
        startAutomaticSelection(candidates.map { ($0, nil) }, source: .libraryShuffle, for: screen)
    }

    /// One cancellable worker per display; retries are sequential and never own periodic clocks.
    private func startAutomaticSelection(
        _ candidates: [(entry: WallpaperQueueEntry, cursor: Int?)], source: AutomaticSwitchMark.Source?, for screen: Screen
    ) {
        guard !isSuspendedForUserAbsence, let initial = configurationStore.get(for: screen.id) else { return }
        let expectedMode = initial.wallpaperMode
        let candidates = candidates.filter { initial.automationFailures[$0.entry.id]?.entry.content != $0.entry.content }
        guard !candidates.isEmpty else { return }
        let screenID = screen.id
        validationTasksByScreen[screenID]?.task.cancel()
        automaticSelectionSerial &+= 1
        let serial = automaticSelectionSerial
        automaticSelections[screenID] = serial
        let initialTransition = bumpTransition(screenID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if automaticSelections[screenID] == serial {
                    automaticSelections[screenID] = nil
                    validationTasksByScreen[screenID] = nil
                }
            }
            let intended: @MainActor () -> Bool = { [weak self] in
                self?.automaticSelections[screenID] == serial && self?.isSuspendedForUserAbsence == false && !Task.isCancelled
            }
            var dispatched = false
            for candidate in candidates {
                let entry = candidate.entry
                guard intended(), let config = configurationStore.get(for: screenID), config.wallpaperMode == expectedMode else { return }
                // Editing a source changes its snapshot and automatically gives it a fresh chance.
                if config.automationFailures[entry.id]?.entry.content == entry.content {
                    continue
                }
                var lastResult = WallpaperPreparationResult.failed
                for _ in 0 ..< 2 {
                    guard intended() else { return }
                    if !dispatched, !isCurrentTransition(initialTransition, screenID) {
                        return
                    }
                    let available = await libraryEntryAvailable(entry)
                    guard intended(), let liveScreen = screensProvider().first(where: { $0.id == screenID }),
                          let current = configurationStore.get(for: screenID), current.wallpaperMode == expectedMode else { return }
                    if !dispatched, !isCurrentTransition(initialTransition, screenID) {
                        return
                    }
                    if available {
                        var proposed = current.applyingAutomationEntry(entry)
                        if let cursor = candidate.cursor {
                            proposed.playlistCursorIndex = cursor
                        }
                        dispatched = true
                        lastResult = await prepareAutomation(liveScreen, proposed, source, intended)
                    } else {
                        lastResult = .failed
                    }
                    guard intended(), lastResult != .cancelled, configurationStore.get(for: screenID)?.wallpaperMode == expectedMode else { return }
                    if lastResult == .ready {
                        if var committed = configurationStore.get(for: screenID), committed.automationFailures.removeValue(forKey: entry.id) != nil {
                            saveConfiguration(committed)
                        }
                        return
                    }
                }
                guard intended(), var current = configurationStore.get(for: screenID), current.wallpaperMode == expectedMode else { return }
                current.automationFailures[entry.id] = WallpaperAutomationFailure(entry: entry, failedAt: now())
                saveConfiguration(current)
            }
        }
        validationTasksByScreen[screenID] = PendingValidation(generation: serial, task: task)
    }

    // MARK: - Schedule

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        config.scheduleSlots = slots
        saveConfiguration(config)

        if slots != nil {
            checkAndApplySchedule(for: screen, force: true)
        }
    }

    func checkAndApplySchedule(for screen: Screen, force: Bool = false) {
        guard !isSuspendedForUserAbsence,
              var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperMode == .schedule,
              config.scheduleSlots?.isEmpty == false || config.scheduleFallback != nil else { return }
        let slots = config.scheduleSlots ?? []
        let currentTime = now()
        if !force, let settled = config.scheduleSettledUntil, currentTime < settled {
            return
        }
        let decision = SchedulePolicy.decision(for: config, hour: Calendar.current.component(.hour, from: currentTime))
        // Saving here would move the revision and discard a launch restore candidate that is still preparing.
        guard decision != .none else { return }
        config.scheduleSettledUntil = SchedulePolicy.nextBoundary(after: currentTime, slots: slots, calendar: .current)
        // Saved before dispatch: a web or scene candidate gives up when the revision moves while it prepares.
        saveConfiguration(config)

        let entry: WallpaperQueueEntry
        switch decision {
        case .none: return
        case let .applyWallpaper(value): entry = value
        case let .applySlot(slot, bookmark):
            entry = WallpaperQueueEntry(id: "schedule-\(slot.id)", title: slot.label, content: .video(bookmarkData: bookmark))
        case let .restorePrimary(bookmark):
            entry = WallpaperQueueEntry(id: "schedule-primary", title: "", content: .video(bookmarkData: bookmark, packageEntryName: config.savedVideoPackageEntryName))
        }
        applyEntry(entry, cursor: nil, source: .schedule, for: screen)
    }

    // MARK: - Automation start

    func startMonitoring() {
        isMonitoring = true
        startCoordinator(runInitialScheduleCheck: true)
    }

    private func startCoordinator(runInitialScheduleCheck: Bool) {
        guard !isSuspendedForUserAbsence, automationAllowed() else {
            cancelValidationTasks()
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
                guard self?.automaticSelections[screen.id] == nil else { return }
                self?.advancePlaylist(for: screen)
            },
            libraryShuffleHandler: { [weak self] screen in
                guard self?.automaticSelections[screen.id] == nil else { return }
                self?.advanceLibraryShuffle(for: screen)
            },
            runInitialScheduleCheck: runInitialScheduleCheck
        )
    }

    func stopMonitoring() {
        isMonitoring = false
        automationCoordinator.stop()
        for screen in screensProvider() {
            _ = bumpTransition(screen.id)
        }
        cancelValidationTasks()
    }

    func refreshMonitoringIfActive(runInitialScheduleCheck: Bool = false) {
        guard isMonitoring else { return }
        let live = Set(screensProvider().map(\.id))
        for id in Array(validationTasksByScreen.keys) where !live.contains(id) {
            validationTasksByScreen.removeValue(forKey: id)?.task.cancel()
            automaticSelections[id] = nil
            _ = bumpTransition(id)
        }
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
        automaticSelections.removeAll()
        for validation in pending {
            validation.task.cancel()
        }
    }

    private func replacePlaylistBookmark(
        in config: inout ScreenConfiguration,
        cursor: Int,
        bookmarkData: Data
    ) {
        PlaylistPolicy.refreshLegacyBookmark(at: cursor, in: &config, with: bookmarkData)
    }
}
