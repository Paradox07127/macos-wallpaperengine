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
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
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
    private let libraryEntries: @MainActor () -> [LibraryShuffleCandidate]
    private let libraryEntryAvailable: @MainActor (WallpaperQueueEntry) async -> Bool
    private let bookmarkVolumeUnavailable: @MainActor (Data) -> Bool
    private let now: @MainActor () -> Date
    private let calendar: @MainActor () -> Calendar
    private var isMonitoring = false
    private var isSuspendedForUserAbsence = false
    private var validationTasksByScreen: [CGDirectDisplayID: Task<Void, Never>] = [:]
    /// The zone the saved settled-until instants were computed in.
    private var scheduleTimeZone: TimeZone
    /// Displays whose next schedule check must look past a settled-until stamped under an earlier zone.
    private var schedulesAwaitingRecheck: Set<CGDirectDisplayID> = []

    init(
        configurationStore: WallpaperConfigurationStore,
        automationCoordinator: WallpaperAutomationCoordinator,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreProposedConfiguration: @MainActor @escaping (
            Screen,
            ScreenConfiguration
        ) -> Void,
        bumpTransition: @MainActor @escaping (CGDirectDisplayID) -> Int,
        isCurrentTransition: @MainActor @escaping (Int, CGDirectDisplayID) -> Bool,
        now: @MainActor @escaping () -> Date = { Date() },
        // Calendar.current is cached and can keep the zone it was built with, so the system zone is re-read each call.
        calendar: @MainActor @escaping () -> Calendar = {
            var calendar = Calendar.current
            calendar.timeZone = .current
            return calendar
        },
        prepareAutomation: @escaping AutomationPreparer,
        automationAllowed: @MainActor @escaping () -> Bool = { true },
        libraryEntries: @MainActor @escaping () -> [LibraryShuffleCandidate] = { [] },
        libraryEntryAvailable: @MainActor @escaping (WallpaperQueueEntry) async -> Bool = { entry in
            await LibraryContentLocator.locate(content: entry.content, wpeOrigin: entry.origin).isAvailable
        },
        bookmarkVolumeUnavailable: @MainActor @escaping (Data) -> Bool = SettingsManager.isBookmarkVolumeUnavailable
    ) {
        self.configurationStore = configurationStore
        self.automationCoordinator = automationCoordinator
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.restoreProposedConfiguration = restoreProposedConfiguration
        self.bumpTransition = bumpTransition
        self.isCurrentTransition = isCurrentTransition
        self.now = now
        self.calendar = calendar
        scheduleTimeZone = calendar().timeZone
        self.prepareAutomation = prepareAutomation
        self.automationAllowed = automationAllowed
        self.libraryEntries = libraryEntries
        self.libraryEntryAvailable = libraryEntryAvailable
        self.bookmarkVolumeUnavailable = bookmarkVolumeUnavailable
    }

    // MARK: - Playlist

    func previewEntry(_ entry: WallpaperQueueEntry, for screen: Screen) {
        guard !isSuspendedForUserAbsence,
              let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        validationTasksByScreen.removeValue(forKey: screen.id)?.cancel()
        automaticSelections[screen.id] = nil
        restoreProposedConfiguration(screen, config.applyingAutomationEntry(entry))
    }

    func cancelAutomaticSelection(for screenID: CGDirectDisplayID) {
        validationTasksByScreen.removeValue(forKey: screenID)?.cancel()
        automaticSelections[screenID] = nil
    }

    /// `automatic` is true only for the rotation clock; with looping off it never wraps past the last entry.
    func advancePlaylist(for screen: Screen, automatic: Bool = false) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.canNavigatePlaylist else { return }
        let queue = config.effectiveWallpaperQueue
        var order = Self.forwardOrder(in: config).dropLast()
        if automatic, !config.playlistLoops, !config.shufflePlaylist {
            let current = max(0, min(config.playlistCursorIndex ?? 0, queue.count - 1))
            order = order.filter { $0 > current }
        }
        startAutomaticSelection(order.map { (queue[$0], Optional($0)) }, source: .playlist, for: screen)
    }

    /// Queue indices in the order the playlist moves forward from the cursor, ending with the cursor itself.
    private static func forwardOrder(in config: ScreenConfiguration) -> [Int] {
        let count = config.effectiveWallpaperQueue.count
        guard count > 0 else { return [] }
        let current = max(0, min(config.playlistCursorIndex ?? 0, count - 1))
        let others = config.shufflePlaylist
            ? (0 ..< count).filter { $0 != current }.shuffled()
            : (1 ..< count).map { (current + $0) % count }
        return others + [current]
    }

    /// Moves the display off content that is being deleted, the way its mode would move on; `onExhausted` runs when nothing else lands.
    func replaceDeletedContent(
        matching isDeleted: (WallpaperQueueEntry) -> Bool, for screen: Screen, onExhausted: @MainActor @escaping () -> Void
    ) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let candidates: [(entry: WallpaperQueueEntry, cursor: Int?)]
        let source: AutomaticSwitchMark.Source
        switch config.wallpaperMode {
        case .playlist:
            let queue = config.effectiveWallpaperQueue
            candidates = Self.forwardOrder(in: config).filter { !isDeleted(queue[$0]) }.map { (queue[$0], $0) }
            source = .playlist
        case .libraryShuffle:
            // Resolved up front: `isDeleted` cannot outlive this call, so it cannot run inside the selection loop.
            candidates = LibraryShufflePolicy.candidates(in: libraryEntries(), excluding: config.activeWallpaper, origin: config.wpeOrigin)
                .compactMap { $0.resolve() }.filter { !isDeleted($0) }.shuffled().map { ($0, nil) }
            source = .libraryShuffle
        case .schedule:
            candidates = []
            source = .schedule
        }
        guard let next = candidates.first else {
            onExhausted()
            return
        }
        // The worker below may be abandoned (wallpapers off, user away) without landing anything, so the saved row must not keep the deleted content.
        var replacement = config.applyingAutomationEntry(next.entry)
        if let cursor = next.cursor {
            replacement.playlistCursorIndex = cursor
        }
        saveConfiguration(replacement)
        startAutomaticSelection(candidates, source: source, for: screen, onExhausted: onExhausted)
    }

    func regressPlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.canNavigatePlaylist else { return }
        let queue = config.effectiveWallpaperQueue
        let current = max(0, min(config.playlistCursorIndex ?? 0, queue.count - 1))
        let indices = config.shufflePlaylist
            ? queue.indices.filter { $0 != current }.shuffled()
            : (1 ..< queue.count).map { (current - $0 + queue.count) % queue.count }
        startAutomaticSelection(indices.map { (queue[$0], Optional($0)) }, source: .playlist, for: screen)
    }

    func updateAutomation(
        queue: [WallpaperQueueEntry], slots: [ScheduleSlot], fallback: WallpaperQueueEntry? = nil, mode: WallpaperMode,
        rotationMinutes: Int?, autoAdvance: Bool = true, loops: Bool = true,
        shuffle: Bool, libraryShuffleRotationMinutes: Int? = nil,
        previewedEntryID: WallpaperQueueEntry.ID? = nil, for screen: Screen
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
        // A preview still loading or failed leaves the old content in config; only a landed preview moves the cursor.
        let previewedCursor = mode == .playlist ? config.wallpaperQueue?.firstIndex(where: {
            $0.id == previewedEntryID && SchedulePolicy.isSameContent($0.content, config.activeWallpaper)
        }) : nil
        config.playlistCursorIndex = previewedCursor ?? keptCursor ?? 0
        config.scheduleSlots = slots.isEmpty ? nil : slots
        config.wallpaperMode = mode
        config.playlistRotationMinutes = rotationMinutes.flatMap { $0 > 0 ? $0 : nil }
        config.playlistAutoAdvance = autoAdvance
        config.playlistLoops = loops
        config.shufflePlaylist = shuffle
        if let libraryShuffleRotationMinutes {
            config.libraryShuffleRotationMinutes = max(1, libraryShuffleRotationMinutes)
        }
        cancelAutomaticSelection(for: screen.id)
        saveConfiguration(config)
        if mode == .libraryShuffle {
            if previousMode != .libraryShuffle {
                advanceLibraryShuffle(for: screen)
            }
        } else if mode == .schedule {
            checkAndApplySchedule(for: screen, force: true)
        } else if previousMode != .playlist || (previewedCursor == nil && currentID != nil && keptCursor == nil),
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
        cancelAutomaticSelection(for: screen.id)
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
        validationTasksByScreen[screen.id]?.cancel()
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
        let candidates = LibraryShufflePolicy.candidates(in: libraryEntries(), excluding: config.activeWallpaper, origin: config.wpeOrigin)
        startAutomaticSelection(candidates.shuffled().map { ($0, nil) }, source: .libraryShuffle, for: screen)
    }

    private func startAutomaticSelection(
        _ entries: [(entry: WallpaperQueueEntry, cursor: Int?)], source: AutomaticSwitchMark.Source?, for screen: Screen,
        onExhausted: (@MainActor () -> Void)? = nil
    ) {
        startAutomaticSelection(
            entries.map { (LibraryShuffleCandidate($0.entry), $0.cursor) }, source: source, for: screen, onExhausted: onExhausted
        )
    }

    /// One cancellable worker per display; retries are sequential and never own periodic clocks.
    private func startAutomaticSelection(
        _ candidates: [(entry: LibraryShuffleCandidate, cursor: Int?)], source: AutomaticSwitchMark.Source?, for screen: Screen,
        onExhausted: (@MainActor () -> Void)? = nil
    ) {
        guard !isSuspendedForUserAbsence, let initial = configurationStore.get(for: screen.id) else { return }
        let expectedMode = initial.wallpaperMode
        // An unresolved candidate's failure record is checked once the loop resolves it.
        let candidates = candidates.filter { candidate in
            candidate.entry.resolvedEntry.map { initial.automationFailures[$0.id]?.entry.content != $0.content } ?? true
        }
        guard !candidates.isEmpty else {
            onExhausted?()
            return
        }
        let screenID = screen.id
        validationTasksByScreen[screenID]?.cancel()
        automaticSelectionSerial &+= 1
        let serial = automaticSelectionSerial
        automaticSelections[screenID] = serial
        let initialTransition = bumpTransition(screenID)
        // The selection awaits before it dispatches, so the barrier has to expect this display.
        let barrier = WallpaperSwitchGroup.current?.barrier
        barrier?.expect(screenID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if automaticSelections[screenID] == serial {
                    automaticSelections[screenID] = nil
                    validationTasksByScreen[screenID] = nil
                }
                barrier?.abandon(screenID)
            }
            let intended: @MainActor () -> Bool = { [weak self] in
                self?.automaticSelections[screenID] == serial && self?.isSuspendedForUserAbsence == false && !Task.isCancelled
            }
            var dispatched = false
            candidateLoop: for candidate in candidates {
                guard intended(), let config = configurationStore.get(for: screenID), config.wallpaperMode == expectedMode else { return }
                guard let entry = candidate.entry.resolve() else { continue }
                // Editing a source changes its snapshot and automatically gives it a fresh chance.
                if config.automationFailures[entry.id]?.entry.content == entry.content {
                    continue
                }
                var lastResult = WallpaperPreparationResult.failed
                var reason = WallpaperAutomationFailure.Reason.loadFailed
                var sourceWasFound = false
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
                    var cursor = candidate.cursor
                    if cursor != nil {
                        // The queue can change during the await: a removed or edited row must not land, and a kept row may sit at a new index.
                        guard let index = current.effectiveWallpaperQueue.firstIndex(where: { $0.id == entry.id && $0.content == entry.content })
                        else { continue candidateLoop }
                        cursor = index
                    }
                    if available {
                        sourceWasFound = true
                        var proposed = current.applyingAutomationEntry(entry)
                        if let cursor {
                            proposed.playlistCursorIndex = cursor
                        }
                        dispatched = true
                        lastResult = await prepareAutomation(liveScreen, proposed, source, intended)
                        reason = lastResult == .timedOut ? .timedOut : .loadFailed
                    } else {
                        lastResult = .failed
                        reason = .sourceMissing
                    }
                    guard intended(), lastResult != .cancelled, configurationStore.get(for: screenID)?.wallpaperMode == expectedMode else { return }
                    if lastResult == .ready {
                        if var committed = configurationStore.get(for: screenID), committed.automationFailures.removeValue(forKey: entry.id) != nil {
                            saveConfiguration(committed)
                        }
                        return
                    }
                }
                // An unmounted volume is temporary: skip this round instead of disabling the source until "Enable Again".
                if !sourceWasFound,
                   let bookmark = entry.content.activeVideoBookmarkData ?? entry.content.htmlSource?.localBookmarkData ?? entry.origin?.sourceFolderBookmark,
                   bookmarkVolumeUnavailable(bookmark) {
                    continue
                }
                guard intended(), var current = configurationStore.get(for: screenID), current.wallpaperMode == expectedMode else { return }
                current.automationFailures[entry.id] = WallpaperAutomationFailure(entry: entry, failedAt: now(), reason: reason)
                saveConfiguration(current)
            }
            onExhausted?()
        }
        validationTasksByScreen[screenID] = task
    }

    // MARK: - Schedule

    func checkAndApplySchedule(for screen: Screen, force: Bool = false) {
        guard !isSuspendedForUserAbsence,
              var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.wallpaperMode == .schedule,
              config.scheduleSlots?.isEmpty == false || config.scheduleFallback != nil else { return }
        let slots = config.scheduleSlots ?? []
        let currentTime = now()
        let awaitingRecheck = schedulesAwaitingRecheck.remove(screen.id) != nil
        if !force, !awaitingRecheck, let settled = config.scheduleSettledUntil, currentTime < settled {
            return
        }
        let calendar = calendar()
        let decision = SchedulePolicy.decision(for: config, hour: calendar.component(.hour, from: currentTime))
        // Saving here would move the revision and discard a launch restore candidate that is still preparing.
        guard decision != .none else { return }
        config.scheduleSettledUntil = SchedulePolicy.nextBoundary(after: currentTime, slots: slots, calendar: calendar)
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

    /// Settled-until instants mark local slot edges; after a zone change a hand-picked hold moves to the new zone's next edge, and anything else is re-planned.
    func handleTimeZoneChange() {
        let calendar = calendar()
        var previousCalendar = calendar
        previousCalendar.timeZone = scheduleTimeZone
        scheduleTimeZone = calendar.timeZone
        guard previousCalendar.timeZone != calendar.timeZone else { return }
        let currentTime = now()
        for screen in screensProvider() {
            guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  config.wallpaperMode == .schedule, config.scheduleSettledUntil != nil else { continue }
            // A switch still in flight already stamped settled-until while the old content is shown, so it looks like a manual hold.
            let heldByHand = automaticSelections[screen.id] == nil
                && SchedulePolicy.pausedUntil(for: config, now: currentTime, calendar: previousCalendar) != nil
            // Saving nil would not clear it: the save path keeps a later settled-until for unchanged content.
            config.scheduleSettledUntil = SchedulePolicy.nextBoundary(after: currentTime, slots: config.scheduleSlots ?? [], calendar: calendar)
            saveConfiguration(config)
            guard !heldByHand else { continue }
            // The old zone's target must not land even when the new plan picks the content already on screen.
            cancelAutomaticSelection(for: screen.id)
            schedulesAwaitingRecheck.insert(screen.id)
            if isMonitoring {
                checkAndApplySchedule(for: screen)
            }
        }
    }

    // MARK: - Automation start

    func startMonitoring() {
        isMonitoring = true
        startCoordinator(runInitialScheduleCheck: true)
    }

    private func startCoordinator(runInitialScheduleCheck: Bool) {
        // Already stopped by the suspend; a stop() here (wake refreshes screens first) would drop the frozen countdown.
        guard !isSuspendedForUserAbsence else { return }
        guard automationAllowed() else {
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
                self?.advancePlaylist(for: screen, automatic: true)
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
            validationTasksByScreen.removeValue(forKey: id)?.cancel()
            automaticSelections[id] = nil
            _ = bumpTransition(id)
        }
        startCoordinator(runInitialScheduleCheck: runInitialScheduleCheck)
    }

    func suspendForUserAbsence() {
        guard !isSuspendedForUserAbsence else { return }
        isSuspendedForUserAbsence = true
        automationCoordinator.suspendForUserAbsence(at: now())
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

    private func cancelValidationTasks() {
        let pending = Array(validationTasksByScreen.values)
        validationTasksByScreen.removeAll()
        automaticSelections.removeAll()
        for validation in pending {
            validation.cancel()
        }
    }
}
