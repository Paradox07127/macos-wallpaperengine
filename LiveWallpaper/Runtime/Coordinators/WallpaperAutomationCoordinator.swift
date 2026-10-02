import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class WallpaperAutomationCoordinator {
    private(set) var currentTime = Date()
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    @ObservationIgnored private var taskGeneration = 0
    /// Deterministic tick seam for behavior tests. Production uses the existing
    /// one-minute clock when this is nil.
    @ObservationIgnored private let tickStreamFactory: (() -> AsyncStream<Date>)?
    /// Manual-apply times per screen, folded into the task's rotation clock on the next tick.
    @ObservationIgnored private var pendingRotationResets: [CGDirectDisplayID: Date] = [:]
    #if DEBUG
    private(set) var taskStartCountForTesting = 0
    #endif

    init(tickStreamFactory: (() -> AsyncStream<Date>)? = nil) {
        self.tickStreamFactory = tickStreamFactory
    }

    #if DEBUG
    var hasActiveTaskForTesting: Bool {
        automationTask != nil
    }
    #endif

    static func hasDemand(_ configuration: ScreenConfiguration) -> Bool {
        switch configuration.wallpaperMode {
        case .playlist:
            (configuration.playlistRotationMinutes ?? 0) > 0
                && configuration.effectiveWallpaperQueue.filter { configuration.automationFailures[$0.id]?.entry.content != $0.content }.count > 1
        case .libraryShuffle:
            // Keep polling even with an empty library, so later imports participate.
            configuration.libraryShuffleRotationMinutes > 0
        case .schedule:
            configuration.scheduleFallback != nil || configuration.scheduleSlots?.contains {
                $0.wallpaper != nil || $0.videoBookmarkData?.isEmpty == false
            } == true
        }
    }

    func start(
        screenProvider: @escaping @MainActor () -> [Screen],
        configurationProvider: @escaping @MainActor (CGDirectDisplayID) -> ScreenConfiguration?,
        scheduleHandler: @escaping @MainActor (Screen) -> Void,
        playlistHandler: @escaping @MainActor (Screen) -> Void,
        libraryShuffleHandler: @escaping @MainActor (Screen) -> Void = { _ in },
        runInitialScheduleCheck: Bool = true
    ) {
        let screens = screenProvider()
        if runInitialScheduleCheck {
            for screen in screens {
                scheduleHandler(screen)
            }
        }

        guard screens.contains(where: { screen in
            configurationProvider(screen.id).map(Self.hasDemand) == true
        }) else {
            stop()
            return
        }

        // Restart only on demand edge; keep lastRotation when already active.
        guard automationTask == nil else { return }
        // A reset recorded while idle predates this task's start time and would make the first tick rotate early.
        pendingRotationResets = [:]

        let generation = taskGeneration
        #if DEBUG
        taskStartCountForTesting += 1
        #endif
        automationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.taskGeneration == generation {
                    self.automationTask = nil
                }
            }

            var lastRotation: [CGDirectDisplayID: Date] = [:]
            var rotationSettings: [CGDirectDisplayID: (mode: WallpaperMode, minutes: Int)] = [:]
            // Real time starts at enable/resume, rather than one minute after the first tick.
            if self?.tickStreamFactory == nil {
                let startTime = Date()
                for screen in screens {
                    guard let config = configurationProvider(screen.id) else { continue }
                    let minutes = config.wallpaperMode == .libraryShuffle
                        ? config.libraryShuffleRotationMinutes : (config.playlistRotationMinutes ?? 0)
                    lastRotation[screen.id] = startTime
                    rotationSettings[screen.id] = (config.wallpaperMode, minutes)
                }
            }

            @MainActor
            func processTick(at now: Date) -> Bool {
                self?.currentTime = now
                let screens = screenProvider()
                let configurations = Dictionary(
                    uniqueKeysWithValues: screens.compactMap { screen in
                        configurationProvider(screen.id).map { (screen.id, $0) }
                    }
                )

                guard configurations.values.contains(where: Self.hasDemand) else {
                    return false
                }

                for screen in screens {
                    guard let configuration = configurations[screen.id],
                          configuration.wallpaperMode == .schedule,
                          Self.hasDemand(configuration) else {
                        continue
                    }
                    scheduleHandler(screen)
                }

                let liveIDs = Set(screens.map(\.id))
                lastRotation = lastRotation.filter { liveIDs.contains($0.key) }
                rotationSettings = rotationSettings.filter { liveIDs.contains($0.key) }
                for screen in screens {
                    guard let configuration = configurations[screen.id],
                          configuration.wallpaperMode == .libraryShuffle || configuration.effectiveWallpaperQueue.count > 1 else {
                        continue
                    }

                    let rotationMinutes = configuration.wallpaperMode == .libraryShuffle
                        ? configuration.libraryShuffleRotationMinutes : (configuration.playlistRotationMinutes ?? 0)
                    guard rotationMinutes > 0 else {
                        lastRotation[screen.id] = nil
                        rotationSettings[screen.id] = nil
                        continue
                    }
                    if let resetAt = self?.pendingRotationResets.removeValue(forKey: screen.id) {
                        lastRotation[screen.id] = resetAt
                    }
                    let previous = rotationSettings[screen.id]
                    rotationSettings[screen.id] = (configuration.wallpaperMode, rotationMinutes)
                    if previous?.mode != configuration.wallpaperMode || previous?.minutes != rotationMinutes {
                        lastRotation[screen.id] = now
                        continue
                    }

                    guard let lastTime = lastRotation[screen.id] else {
                        lastRotation[screen.id] = now
                        continue
                    }

                    if PlaylistPolicy.shouldRotate(
                        now: now,
                        lastRotation: lastTime,
                        rotationMinutes: rotationMinutes
                    ) {
                        lastRotation[screen.id] = now
                        // Advance deadline clock in schedule mode; rotate only in playlist.
                        if configuration.wallpaperMode == .playlist {
                            playlistHandler(screen)
                        } else if configuration.wallpaperMode == .libraryShuffle {
                            libraryShuffleHandler(screen)
                        }
                    }
                }
                return true
            }

            if let tickStream = self?.tickStreamFactory?() {
                for await now in tickStream {
                    guard !Task.isCancelled, processTick(at: now) else { return }
                }
                return
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard processTick(at: Date()) else { return }
            }
        }
    }

    func resetRotationClock(for screenID: CGDirectDisplayID, at now: Date = Date()) {
        pendingRotationResets[screenID] = now
    }

    func stop() {
        taskGeneration &+= 1
        automationTask?.cancel()
        automationTask = nil
    }

    deinit {
        automationTask?.cancel()
    }
}
