import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
final class WallpaperAutomationCoordinator {
    private var automationTask: Task<Void, Never>?
    private var taskGeneration = 0
    /// Deterministic tick seam for behavior tests. Production uses the existing
    /// one-minute clock when this is nil.
    private let tickStreamFactory: (() -> AsyncStream<Date>)?
    #if DEBUG
    /// Test-only introspection; no production reader.
    private(set) var taskStartCountForTesting = 0
    #endif

    init(tickStreamFactory: (() -> AsyncStream<Date>)? = nil) {
        self.tickStreamFactory = tickStreamFactory
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    var hasActiveTaskForTesting: Bool {
        automationTask != nil
    }
    #endif

    static func hasDemand(_ configuration: ScreenConfiguration) -> Bool {
        switch configuration.wallpaperMode {
        case .playlist:
            return (configuration.playlistRotationMinutes ?? 0) > 0
                && configuration.combinedPlaylist.count > 1
        case .schedule:
            return configuration.scheduleSlots?.contains {
                $0.videoBookmarkData?.isEmpty == false
            } == true
        }
    }

    func start(
        screenProvider: @escaping @MainActor () -> [Screen],
        configurationProvider: @escaping @MainActor (CGDirectDisplayID) -> ScreenConfiguration?,
        scheduleHandler: @escaping @MainActor (Screen) -> Void,
        playlistHandler: @escaping @MainActor (Screen) -> Void,
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

        let generation = taskGeneration
        #if DEBUG
        taskStartCountForTesting += 1
        #endif
        // One 60s tick while demand exists; no timer when idle.
        automationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.taskGeneration == generation {
                    self.automationTask = nil
                }
            }

            var lastRotation: [CGDirectDisplayID: Date] = [:]

            @MainActor
            func processTick(at now: Date) -> Bool {
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
                for screen in screens {
                    guard let configuration = configurations[screen.id],
                          let rotationMinutes = configuration.playlistRotationMinutes,
                          rotationMinutes > 0,
                          configuration.combinedPlaylist.count > 1 else {
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

    func stop() {
        taskGeneration &+= 1
        automationTask?.cancel()
        automationTask = nil
    }

    deinit {
        automationTask?.cancel()
    }
}
