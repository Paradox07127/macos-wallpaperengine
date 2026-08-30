import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class ScreenManager {
    var screens: [Screen] = []
    /// Master render gate: whether ALL wallpaper pipelines may display.
    var wallpapersGloballyEnabled: Bool = ScreenManager.loadGloballyEnabled()

    static let globallyEnabledDefaultsKey = "loomscreen.wallpapers.globallyEnabled.v1"
    private static func loadGloballyEnabled() -> Bool {
        UserDefaults.appScoped().object(forKey: globallyEnabledDefaultsKey) as? Bool ?? true
    }

    /// Single observable snapshot of derived wallpaper-session state.
    var wallpaperSessionState = WallpaperSessionState()
    var wallpaperSessionStateVersion: UInt64 { wallpaperSessionState.version }
    var wallpaperSessionSummaryCache: WallpaperSessionSummaryCache { wallpaperSessionState.summaryCache }
    #if !LITE_BUILD
    /// Per-screen WPE import bookkeeping (last error + generation counter).
    let wpeImportTracker = WPEImportTracker()
    #endif
    /// Display-name cache for security-scoped bookmarks.
    let bookmarkDisplayNameCache = BookmarkDisplayNameCache()
    /// Monitor overlay per display, keyed by `displayFingerprint`; write-through
    /// to global settings. Observed so the sidebar page and menu bar track edits.
    var monitorOverlays: [String: MonitorOverlayConfiguration] = SettingsManager.shared.loadMonitorOverlays()
    /// User-assigned display names keyed by `displayFingerprint`; write-through
    /// to global settings, re-applied to every rebuilt `Screen` on refresh.
    var screenNames: [String: String] = SettingsManager.shared.loadScreenNames()

    @ObservationIgnored var cleanupTasks: Set<AnyCancellable> = []
    /// One-way application-termination latch.
    @ObservationIgnored var isTerminating = false
    @ObservationIgnored let displayRegistry: any DisplayRegistering
    @ObservationIgnored let featureCatalog: FeatureCatalog
    @ObservationIgnored let originReconciler: any OriginReconciler
    @ObservationIgnored let configurationStore = WallpaperConfigurationStore()
    @ObservationIgnored let ambientSessionBuilder = AmbientWallpaperSessionBuilder()
    @ObservationIgnored private let automationCoordinator = WallpaperAutomationCoordinator()
    @ObservationIgnored let powerMonitor: any PowerMonitoring
    @ObservationIgnored let playbackStateSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored let fullScreenDetector: any FullScreenDetecting
    @ObservationIgnored private let playableVideoLoader: any PlayableVideoLoading
    @ObservationIgnored let memoryPressureWatcher: any MemoryPressureWatching
    @ObservationIgnored let restoresSavedWallpapersOnScreenRefresh: Bool
    @ObservationIgnored var lastScreenSignatures: [CGDirectDisplayID: ScreenConfigurationSignature] = [:]
    @ObservationIgnored var transientRuntimeErrors: [CGDirectDisplayID: WallpaperRuntimeError] = [:]
    /// App Nap throttles an `LSUIElement` accessory app's render loop to ~1fps the moment another app becomes active, freezing the wallpaper whenever the user focuses any other window.
    @ObservationIgnored var renderingActivityToken: (any NSObjectProtocol)?
    enum UserAbsenceReason: Hashable {
        case screenLocked
        case displaySleep
        case systemSleep
    }
    /// Reasons the user is not watching the desktop.
    @ObservationIgnored var userAbsenceReasons: Set<UserAbsenceReason> = []
    @ObservationIgnored let userPresenceProbe: any UserPresenceProbing
    @ObservationIgnored let absenceRevalidationGrace: Duration
    @ObservationIgnored let absenceRevalidationPollInterval: Duration
    /// When each reason was recorded, for the revalidation grace period.
    @ObservationIgnored var absenceMarkedAt: [UserAbsenceReason: ContinuousClock.Instant] = [:]
    /// Slow poll that re-runs revalidation while absent — the safety net for a
    /// lost wake/unlock notification with no later policy events.
    @ObservationIgnored var absenceRevalidationTimer: Task<Void, Never>?
    var isUserAbsent: Bool { !userAbsenceReasons.isEmpty }
    /// Feeds memory pressure into the performance policy without changing user playback intent.
    @ObservationIgnored var memoryPressureLevel = SystemMemoryPressureLevel.normal
    /// Why each screen is suspended, for the UI to explain itself.
    var suspendReasonsByScreen: [CGDirectDisplayID: Set<WallpaperSuspendReason>] = [:]
    /// One machine per screen — the single source of truth for user play
    /// intent. Installed sessions adopt it via `WallpaperIntentMachineAdopting`
    /// and write intent through their own `play()/pause()`; policy refreshes
    /// feed it the decision and take `suspendReasonsByScreen` from its outputs.
    @ObservationIgnored private var playbackStateMachines: [CGDirectDisplayID: WallpaperPlaybackStateMachine] = [:]

    func playbackStateMachine(for screenID: CGDirectDisplayID) -> WallpaperPlaybackStateMachine {
        if let machine = playbackStateMachines[screenID] { return machine }
        let machine = WallpaperPlaybackStateMachine()
        playbackStateMachines[screenID] = machine
        return machine
    }

    /// Session install/replace/release must not leak the previous session's intent into the
    /// machine: drop the entry (lazy rebuild intends to play, matching every fresh session), hand
    /// the fresh machine to a session that adopts it as its intent source, and re-sync if a non-
    /// adopting session disagrees.
    func resetPlaybackStateMachine(for screen: Screen) {
        playbackStateMachines.removeValue(forKey: screen.id)
        guard let playback = screen.playbackController else { return }
        let machine = playbackStateMachine(for: screen.id)
        if let adopting = playback as? any WallpaperIntentMachineAdopting {
            adopting.adoptPlaybackStateMachine(machine)
        } else if !playback.userIntendsToPlay {
            machine.userPause()
        }
    }
    /// Coarse "not normal" memory-pressure flag for tests.
    var isUnderMemoryPressure: Bool { memoryPressureLevel != .normal }
    /// Coordinates per-screen playback configuration mutations + transition tokens.
    @ObservationIgnored lazy var playbackCoordinator = PlaybackCoordinator(
        configurationStore: configurationStore,
        playableVideoLoader: playableVideoLoader,
        applyPolicy: { [weak self] screen in
            self?.applyPerformancePolicy(to: screen)
        },
        applyVideoEffects: { [weak self] screen, config in
            self?.effectsCoordinator.applyVideoEffects(for: screen, config: config)
        },
        prepareVideoEffects: { [weak self] player, screen, config in
            guard let self else { return false }
            return await self.effectsCoordinator.prepareVideoEffects(
                for: player,
                screen: screen,
                config: config
            )
        },
        effectsWorkRevision: { [weak self] screenID, player in
            guard let self, self.effectsCoordinatorWasInitialized else {
                return nil
            }
            return self.effectsCoordinator.workRevision(
                for: screenID,
                player: player
            )
        },
        effectsWorkIsActive: { [weak self] screenID, player in
            guard let self, self.effectsCoordinatorWasInitialized else {
                return false
            }
            return self.effectsCoordinator.hasActiveWork(
                for: screenID,
                player: player
            )
        },
        retireVideoEffectsWork: { [weak self] screenID, player in
            guard let self, self.effectsCoordinatorWasInitialized else { return }
            self.effectsCoordinator.retireWork(
                for: screenID,
                player: player
            )
        },
        refreshRateLookup: { [weak self] screenID in
            self?.getScreenRefreshRate(for: screenID) ?? 60
        },
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        markSessionStateChanged: { [weak self] in
            self?.markWallpaperSessionStateChanged()
        },
        releaseRuntimeSession: { [weak self] screen in
            self?.releaseRuntimeSession(screen)
        },
        resetPlaybackStateMachine: { [weak self] screen in
            self?.resetPlaybackStateMachine(for: screen)
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        },
        refreshOtherAudioLeadership: { [weak self] in
            self?.htmlCoordinator.refreshAudioLeadership()
        },
        reportRuntimeError: { [weak self] screenID, error in
            self?.setTransientRuntimeError(error, for: screenID)
        },
        originReconciler: originReconciler,
        isGloballyEnabled: { [weak self] in
            self?.wallpapersGloballyEnabled ?? true
        },
        isRuntimeInstallationAllowed: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating
        },
        advanceSceneMutationIntent: { [weak self] screenID in
            self?.advanceScenePropertyMutationIntent(for: screenID)
        }
    )
    /// Lazy because the `saveConfiguration` / `restoreWallpaperSession`
    /// callbacks capture `self` (matches `playbackCoordinator`'s pattern).
    #if !LITE_BUILD
    /// Shares the `wpeImportTracker` reference so both this coordinator and
    /// the views reading `wpeImportTracker.error(for:)` observe the same state.
    @ObservationIgnored lazy var wpeImportCoordinator = WPEImportCoordinator(
        tracker: wpeImportTracker,
        configurationStore: configurationStore,
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        restoreWallpaperSession: { [weak self] screen, config, preservingState, beforeCommit in
            self?.restoreWallpaperSession(
                for: screen,
                configuration: config,
                preservingState: preservingState,
                intent: .proposal,
                beforeCommit: beforeCommit
            )
        },
        persistOriginBookmarkRefresh: { [weak self] origin, refreshed in
            self?.persistRuntimeWPEBookmarkRefresh(origin: origin, with: refreshed)
        },
        isLifecycleActive: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating
        }
    )
    #endif
    /// Centralises the write side of ScreenConfiguration persistence (save / remove / prune / validate / display-name priming).
    @ObservationIgnored lazy var persistence = WallpaperPersistenceCoordinator(
        store: configurationStore,
        bookmarkDisplayNameCache: bookmarkDisplayNameCache,
        releaseRuntimeSession: { [weak self] screenID in
            guard let self,
                  let screen = self.screens.first(where: { $0.id == screenID }) else { return }
            Logger.warning("Removing invalid resource configuration for screen \(screenID)", category: .settings)
            self.releaseRuntimeSession(screen)
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        }
    )
    @ObservationIgnored var transitionRegistry: PlaybackTransitionRegistry {
        playbackCoordinator.transition
    }
    /// Owns playlist + schedule automation, including the `WallpaperAutomationCoordinator.start(...)` wiring.
    @ObservationIgnored lazy var automationOrchestrator = WallpaperAutomationOrchestrator(
        configurationStore: configurationStore,
        automationCoordinator: automationCoordinator,
        playableVideoLoader: playableVideoLoader,
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        recordBookmarkDisplayName: { [weak self] bookmark, name in
            self?.recordBookmarkDisplayName(bookmark, name: name)
        },
        setupPreparedVideoPlayback: { [weak self] url, screen, configuration, beforeCommit in
            guard let self else { return }
            self.playbackCoordinator.setupVideoPlayback(
                url: url,
                screen: screen,
                proposedConfiguration: configuration,
                beforeCommit: beforeCommit
            )
        },
        restoreProposedConfiguration: { [weak self] screen, configuration in
            self?.restoreProposedWallpaperSession(
                for: screen,
                configuration: configuration
            )
        },
        bumpTransition: { [weak self] screenID in
            self?.bumpTransition(for: screenID) ?? 0
        },
        isCurrentTransition: { [weak self] generation, screenID in
            self?.isCurrentTransition(generation, for: screenID) ?? false
        }
    )
    /// Owns HTML wallpaper management (setters + multi-instance audio-leader + trust evaluation).
    @ObservationIgnored lazy var htmlCoordinator = HTMLWallpaperCoordinator(
        configurationStore: configurationStore,
        screensProvider: { [weak self] in
            self?.screens ?? []
        },
        saveConfiguration: { [weak self] config in
            self?.saveConfiguration(config)
        },
        restoreWallpaperSession: { [weak self] screen, config, preservingState, beforeCommit in
            self?.restoreWallpaperSession(
                for: screen,
                configuration: config,
                preservingState: preservingState,
                intent: .proposal,
                beforeCommit: beforeCommit
            )
        },
        notifyWallpaperSessionChanged: { [weak self] in
            self?.notifyWallpaperSessionChanged()
        },
        originReconciler: originReconciler,
        prepareSource: { [weak self] source, bookmarkID, wpeOrigin in
            guard let self else { return source }
            return self.ambientSessionBuilder.refreshingHTMLSource(
                source,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed,
                        bookmarkID: bookmarkID,
                        ownerOrigin: wpeOrigin
                    )
                }
            )
        }
    )
    /// Owns video CIFilters plus the renderer-independent weather/particle overlay.
    @ObservationIgnored var effectsCoordinatorWasInitialized = false
    @ObservationIgnored lazy var effectsCoordinator: WallpaperEffectsCoordinator = {
        self.effectsCoordinatorWasInitialized = true
        return WallpaperEffectsCoordinator(
            configurationStore: self.configurationStore,
            screensProvider: { [weak self] in
                self?.screens ?? []
            },
            saveConfiguration: { [weak self] config in
                self?.saveConfiguration(config)
            },
            applyFrameRateLimit: { [weak self] limit, screen in
                self?.applyFrameRateLimit(limit, to: screen)
            },
            screenRefreshRate: { [weak self] screenID in
                self?.getScreenRefreshRate(for: screenID) ?? 60
            },
            isScreenSuspended: { [weak self] screenID in
                self?.suspendedScreenIDs.contains(screenID) ?? true
            }
        )
    }()
    /// Exposed for the WeatherLocation settings view, which reads `currentParticleEffect` / `currentEffectAdjustments` directly and triggers `refresh()` on user gestures.
    var weatherService: WeatherReactiveService {
        let coordinator = effectsCoordinator
        // Ignore mutations while AppKit is terminating (SwiftUI may still reevaluate).
        if isTerminating {
            coordinator.shutdown()
        }
        return coordinator.weatherService
    }
    @ObservationIgnored lazy var lockScreenSnapshotCoordinator = LockScreenSnapshotCoordinator { [weak self] in
        self?.captureDesktopSnapshotsForLockIfNeeded()
    }
    /// Bumped each time `observeFullScreenChanges()` registers a new observer.
    @ObservationIgnored var fullScreenTrackingGeneration: UInt64 = 0
    /// Per-display latch for the *occlusion* arm of the adaptive frame-rate throttle so the policy can apply hysteresis (avoids flapping as window coverage hovers near the enter/exit thresholds).
    @ObservationIgnored var adaptiveFrameRateOcclusionThrottled: [CGDirectDisplayID: Bool] = [:]

    /// Screens whose last-resolved profile was `.suspended`.
    @ObservationIgnored var suspendedScreenIDs: Set<CGDirectDisplayID> = []

    #if !LITE_BUILD
    /// Only sessions Loomscreen actually stopped for an in-place Steam update
    /// are eligible for the matching post-update reload.
    @ObservationIgnored var workshopMutationSuspendedScreenIDs: [String: Set<CGDirectDisplayID>] = [:]
    #endif

    // MARK: - Initialization
    init(startupOptions: ScreenManagerStartupOptions) {
        displayRegistry = startupOptions.displayRegistry ?? DisplayRegistry()
        featureCatalog = startupOptions.featureCatalog
        originReconciler = startupOptions.originReconciler
        powerMonitor = startupOptions.powerMonitor ?? PowerMonitor.shared
        fullScreenDetector = startupOptions.fullScreenDetector ?? FullScreenDetector()
        playableVideoLoader = startupOptions.playableVideoLoader ?? PlayableVideoLoader()
        memoryPressureWatcher = startupOptions.memoryPressureWatcher
        userPresenceProbe = startupOptions.userPresenceProbe
        absenceRevalidationGrace = startupOptions.absenceRevalidationGrace
        absenceRevalidationPollInterval = startupOptions.absenceRevalidationPollInterval
        restoresSavedWallpapersOnScreenRefresh = startupOptions.restoreSavedWallpapers

        Logger.notice("ScreenManager initializing", category: .screenManager)
        setupPowerMonitoring()
        setupScreenObservers()
        setupMemoryPressureMonitoring()
        setupFullScreenDetection()
        if featureCatalog.isEnabled(.lockScreenSnapshots) {
            _ = lockScreenSnapshotCoordinator
        }

        NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)
            .sink { [weak self] _ in
                self?.markWallpaperSessionStateChanged()
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)
            .sink { [weak self] _ in
                self?.automationOrchestrator.refreshMonitoringIfActive()
                guard let self, self.effectsCoordinatorWasInitialized else { return }
                self.effectsCoordinator.reconcileEnvironmentOverlays()
            }
            .store(in: &cleanupTasks)

        #if !LITE_BUILD
        observeWorkshopRepositoryMutations()
        #endif

        refreshScreens()
        if startupOptions.startAutomation {
            if featureCatalog.isEnabled(.playlists) || featureCatalog.isEnabled(.scheduleAutomation) {
                automationOrchestrator.startMonitoring()
            }
            if featureCatalog.isEnabled(.weatherReactive) {
                startWeatherMonitoring()
            }
        }
        Logger.notice("ScreenManager initialization complete", category: .screenManager)
    }

    // MARK: - Public Interface
    func reloadWallpaperForScreen(_ screen: Screen) {
        guard !isTerminating else { return }
        Logger.info("Manually reloading wallpaper for screen \(screen.id)", category: .screenManager)

        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else {
            releaseRuntimeSession(screen)
            return
        }

        primeBookmarkDisplayNames(from: configuration)
        // Keep live session until replacement reaches first-frame readiness.
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }
    
    // MARK: - Helper Methods

    @ObservationIgnored var refreshRateCache: [CGDirectDisplayID: Int] = [:]

    func getScreenRefreshRate(for screenID: CGDirectDisplayID) -> Int {
        if let cached = refreshRateCache[screenID] { return cached }

        guard let mode = CGDisplayCopyDisplayMode(screenID) else { return 60 }
        let rate = mode.refreshRate > 0 ? Int(mode.refreshRate) : 60
        refreshRateCache[screenID] = rate
        return rate
    }
    
}
