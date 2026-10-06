import AppKit
import Foundation
import LiveWallpaperCore
import Testing
import WebKit
@testable import LiveWallpaper

@Suite("ScreenManager ↔ PlaybackCoordinator coordination")
@MainActor
struct ScreenManagerCoordinationTests {
    @Test("Display refresh preserves a live session unless a reload is explicitly requested", arguments: [false, true])
    func displayRefreshSessionLifetime(preserve: Bool) throws {
        let display = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: display)
        let refreshed = Screen(nsScreen: display)
        let registry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: registry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        let session = TestRuntimeSession(wallpaperType: .html)
        screen.installRuntimeSession(session)
        manager.wallpapersGloballyEnabled = true
        registry.screens = [refreshed]

        manager.refreshScreens(preserveRuntimeSessions: preserve)

        #expect(manager.screens.first === refreshed)
        #expect((refreshed.runtimeSession != nil) == preserve)
        #expect(session.cleanupCount == (preserve ? 0 : 1))
        if preserve {
            #expect((refreshed.runtimeSession as AnyObject?) === session)
        }
    }

    @Test("A prepared wallpaper follows a refreshed Screen, but not removal or a newer selection",
          arguments: [false, true], ["refresh", "disconnect", "new-selection"])
    func preparedWallpaperFollowsDisplayRefresh(hasOutgoing: Bool, change: String) async throws {
        let display = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: display)
        let refreshed = Screen(nsScreen: display)
        let registry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: registry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        manager.wallpapersGloballyEnabled = true
        let outgoing = hasOutgoing ? TestRuntimeSession(wallpaperType: .html) : nil
        if let outgoing {
            screen.installRuntimeSession(outgoing)
        }
        let candidate = TestRuntimeSession(wallpaperType: .html)
        candidate.prepareAction = {
            if change == "new-selection" {
                manager.beginExplicitWallpaperSelection(for: screen)
            } else {
                registry.screens = change == "disconnect" ? [] : [refreshed]
                manager.refreshScreens()
            }
            return .ready
        }
        let generation = manager.bumpTransition(for: screen.id)
        let configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("new"), config: .default))
        var committed = false
        var completed: WallpaperPreparationResult?
        let work = manager.beginPreparedAmbientSession(
            candidate, for: screen, replacing: outgoing, generation: generation,
            proposedConfiguration: configuration,
            expectedConfigurationRevision: manager.configurationStore.revision(for: screen.id),
            timeout: .seconds(2), beforeCommit: { committed = true; return true },
            afterCommit: {}, completion: { result, _ in completed = result }
        )
        await work.task?.value
        if change == "refresh" {
            #expect(committed)
            #expect(completed == .ready)
            #expect(manager.screens.first === refreshed)
            #expect((refreshed.runtimeSession as AnyObject?) === candidate)
            #expect(candidate.cleanupCount == 0)
        } else {
            #expect(!committed)
            #expect(completed == .cancelled)
            #expect(candidate.cleanupCount == 1)
        }
    }

    @Test("A preparing attempt follows a same-display refresh to the replacement Screen", arguments: ["commit", "cancel"])
    func preparingAttemptFollowsDisplayRefresh(outcome: String) async throws {
        let display = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: display)
        let refreshed = Screen(nsScreen: display)
        let registry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: registry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        manager.wallpapersGloballyEnabled = true
        let attemptID = manager.wallpaperLoads.begin(for: screen, title: "Scene")
        manager.wallpaperLoads.update(attemptID, for: screen) { $0.phase = .preparing }
        let candidate = TestRuntimeSession(wallpaperType: .html)
        var inFlightOnRefreshed: UUID?
        var orphanedByCancel = false
        candidate.prepareAction = {
            registry.screens = [refreshed]
            manager.refreshScreens()
            inFlightOnRefreshed = manager.wallpaperLoads.attempt(for: refreshed)?.id
            if outcome == "cancel" {
                manager.beginExplicitWallpaperSelection(for: refreshed)
                orphanedByCancel = !manager.wallpaperLoads.attempts.isEmpty
            }
            return .ready
        }
        let generation = manager.bumpTransition(for: screen.id)
        let configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("new"), config: .default))
        let work = manager.beginPreparedAmbientSession(
            candidate, for: screen, replacing: nil, generation: generation, attemptID: attemptID,
            proposedConfiguration: configuration,
            expectedConfigurationRevision: manager.configurationStore.revision(for: screen.id),
            timeout: .seconds(2), beforeCommit: { true }, afterCommit: {}
        )
        await work.task?.value
        #expect(inFlightOnRefreshed == attemptID)
        #expect(!orphanedByCancel)
        #expect(manager.wallpaperLoads.attempts.isEmpty)
        #expect(((refreshed.runtimeSession as AnyObject?) === candidate) == (outcome == "commit"))
    }

    @Test("Wallpaper rendering activity allows idle system sleep")
    func renderingActivityAllowsIdleSystemSleep() {
        let options = WallpaperRenderingActivityPolicy.options

        #expect(options.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(!options.contains(.idleSystemSleepDisabled))
    }

    // MARK: - UserDefaults.standard isolation

    /// The sentinel is a non-Bool string on purpose: the setter's `Bool` write landing in
    /// the real domain is then unambiguous, not just "value looks unchanged".
    @Test("The master render gate never touches the real defaults domain under tests")
    func masterGateSwitchesAreIsolatedFromStandardDefaults() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for defaults isolation test")
            return
        }
        let standard = UserDefaults.standard
        // Both stores have to be put back: leaving `false` in the scoped one would make every
        // later ScreenManager in this process start with wallpapers disabled.
        let scoped = UserDefaults.appScoped()
        let gateKey = ScreenManager.globallyEnabledDefaultsKey
        let previousGate = standard.object(forKey: gateKey)
        let previousScopedGate = scoped.object(forKey: gateKey)
        defer {
            if let previousGate {
                standard.set(previousGate, forKey: gateKey)
            } else {
                standard.removeObject(forKey: gateKey)
            }
            if let previousScopedGate {
                scoped.set(previousScopedGate, forKey: gateKey)
            } else {
                scoped.removeObject(forKey: gateKey)
            }
        }
        standard.set("sentinel-gate", forKey: gateKey)
        scoped.set(true, forKey: gateKey)

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        manager.setWallpapersEnabled(false)

        #expect(standard.string(forKey: gateKey) == "sentinel-gate")
    }

    // MARK: - Launch opening

    /// Synchronous on purpose: no other MainActor test can observe the scoped defaults while they are swapped.
    private static func withOpeningDefaults(globallyEnabled: Bool, _ body: () throws -> Void) rethrows {
        let scoped = UserDefaults.appScoped()
        let keys = [ScreenManager.globallyEnabledDefaultsKey, WallpaperOpeningChoice.defaultsKey]
        let previous = keys.map { scoped.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value {
                    scoped.set(value, forKey: key)
                } else {
                    scoped.removeObject(forKey: key)
                }
            }
        }
        scoped.set(globallyEnabled, forKey: ScreenManager.globallyEnabledDefaultsKey)
        scoped.set(WallpaperOpeningChoice.loom.rawValue, forKey: WallpaperOpeningChoice.defaultsKey)
        try body()
    }

    private static func makeOpeningManager(playsOpening: Bool?) -> (ScreenManager, [Screen]) {
        let screens = NSScreen.screens.map(Screen.init(nsScreen:))
        var options = ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: screens),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        )
        if let playsOpening {
            options.playsOpening = playsOpening
        }
        return (ScreenManager(startupOptions: options), screens)
    }

    @Test("No launch opening batch unless startup asks for one")
    func openingBatchIsOffByDefault() {
        Self.withOpeningDefaults(globallyEnabled: true) {
            let (manager, _) = Self.makeOpeningManager(playsOpening: nil)
            #expect(manager.openingBatch == nil)
        }
    }

    @Test("A launch that plays the opening covers exactly the current displays")
    func openingBatchCoversCurrentDisplays() throws {
        try Self.withOpeningDefaults(globallyEnabled: true) {
            let (manager, screens) = Self.makeOpeningManager(playsOpening: true)
            try #require(!screens.isEmpty)
            let batch = try #require(manager.openingBatch)
            let outsider = (screens.map(\.id).max() ?? 0) &+ 1
            #expect(batch.claim(outsider)?.effect == nil)
            for screen in screens {
                #expect(batch.claim(screen.id)?.effect == .loom)
            }
        }
    }

    @Test("No launch opening batch while wallpapers are globally off")
    func openingBatchNeedsWallpapersOn() {
        Self.withOpeningDefaults(globallyEnabled: false) {
            let (manager, _) = Self.makeOpeningManager(playsOpening: true)
            #expect(manager.openingBatch == nil)
        }
    }

    @Test("A manual selection cancels an automatic retry still waiting on source availability")
    func manualSelectionCancelsPendingAutomaticRetry() async throws {
        let entry = WallpaperQueueEntry(id: "auto", title: "Auto", content: .html(source: .inline("auto"), config: .default))
        try await Self.runWithHTMLConfiguration { manager, screen in
            var config = try #require(manager.getConfiguration(for: screen))
            config.wallpaperMode = .libraryShuffle
            manager.configurationStore.save(config)
            var prepareCalls = 0
            var availabilityChecks = 0
            var resumeAvailability: CheckedContinuation<Bool, Never>?
            manager.automationOrchestrator = WallpaperAutomationOrchestrator(
                configurationStore: manager.configurationStore, automationCoordinator: WallpaperAutomationCoordinator(),
                playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
                saveConfiguration: { manager.configurationStore.save($0) }, recordBookmarkDisplayName: { _, _ in },
                setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
                bumpTransition: { manager.bumpTransition(for: $0) },
                isCurrentTransition: { manager.isCurrentTransition($0, for: $1) },
                prepareAutomation: { _, _, _, _ in
                    prepareCalls += 1
                    return .failed
                },
                libraryEntries: { [entry] },
                libraryEntryAvailable: { _ in
                    availabilityChecks += 1
                    guard availabilityChecks > 1 else { return true }
                    return await withCheckedContinuation { resumeAvailability = $0 }
                }
            )
            manager.automationOrchestrator.advanceLibraryShuffle(for: screen)
            for _ in 0 ..< 100 where resumeAvailability == nil {
                await Task.yield()
            }
            let resume = try #require(resumeAvailability)
            #expect(prepareCalls == 1)
            manager.beginExplicitWallpaperSelection(for: screen)
            resume.resume(returning: true)
            for _ in 0 ..< 100 {
                await Task.yield()
            }
            #expect(prepareCalls == 1)
        }
    }

    // MARK: - PlaybackTransitionRegistry

    @Test("bumpTransition starts at 1 and increments monotonically per screen")
    func bumpTransitionIncrementsMonotonically() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 100

        #expect(registry.bumpTransition(for: screenID) == 1)
        #expect(registry.bumpTransition(for: screenID) == 2)
        #expect(registry.bumpTransition(for: screenID) == 3)
    }

    @Test("Each screen ID has an independent generation counter")
    func transitionGenerationsAreIndependentPerScreen() {
        let registry = PlaybackTransitionRegistry()

        #expect(registry.bumpTransition(for: 100) == 1)
        #expect(registry.bumpTransition(for: 200) == 1)
        #expect(registry.bumpTransition(for: 100) == 2)
        #expect(registry.bumpTransition(for: 200) == 2)
    }

    @Test("isCurrentTransition rejects stale generations")
    func isCurrentTransitionRejectsStaleGenerations() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 300

        let stale = registry.bumpTransition(for: screenID)
        let current = registry.bumpTransition(for: screenID)

        #expect(registry.isCurrentTransition(current, for: screenID))
        #expect(!registry.isCurrentTransition(stale, for: screenID))
    }

    @Test("Bumping a transition cancels the candidate runtime preparation")
    func bumpTransitionCancelsRuntimePreparation() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 350
        let task = Self.makeSuspendedTask()
        let work = RuntimePreparationWork()
        work.task = task
        registry.setRuntimePreparation(work, for: screenID)

        _ = registry.bumpTransition(for: screenID)

        #expect(task.isCancelled)
    }

    @Test("cancelAssetReadiness cancels the installed work")
    func cancelAssetReadinessCancelsInstalledWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 400
        let task = Self.makeSuspendedTask()
        defer { task.cancel() }

        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)
        registry.cancelAssetReadiness(for: screenID)

        #expect(task.isCancelled)
    }

    @Test("cancelAssetReadiness is harmless when no work is installed")
    func cancelAssetReadinessOnEmptySlotIsNoOp() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 401
        let task = Self.makeSuspendedTask()
        defer {
            task.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.cancelAssetReadiness(for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)

        #expect(!task.isCancelled)
    }

    @Test("setAssetReadiness cancels prior work when replacing")
    func setAssetReadinessCancelsPriorWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 500
        let priorTask = Self.makeSuspendedTask()
        let replacementTask = Self.makeSuspendedTask()
        defer {
            priorTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(Self.makeWork(task: priorTask), for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        #expect(priorTask.isCancelled)
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch removes the matching installed work")
    func clearAssetReadinessIfMatchRemovesMatchingWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 600
        let installedTask = Self.makeSuspendedTask()
        let installedWork = Self.makeWork(task: installedTask)
        let replacementTask = Self.makeSuspendedTask()
        defer {
            installedTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(installedWork, for: screenID)
        registry.clearAssetReadinessIfMatch(installedWork, for: screenID)

        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        withExtendedLifetime(installedWork) {
            #expect(!installedTask.isCancelled)
        }
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch is a no-op when a newer work has replaced the slot")
    func clearAssetReadinessIfMatchIgnoresStaleHandle() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 601
        let originalWork = AssetReadinessWork()
        let newerTask = Self.makeSuspendedTask()
        let newerWork = Self.makeWork(task: newerTask)
        defer {
            newerTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(originalWork, for: screenID)
        registry.setAssetReadiness(newerWork, for: screenID)
        registry.clearAssetReadinessIfMatch(originalWork, for: screenID)

        let followupTask = Self.makeSuspendedTask()
        defer { followupTask.cancel() }
        registry.setAssetReadiness(Self.makeWork(task: followupTask), for: screenID)

        #expect(newerTask.isCancelled)
    }

    @Test("Deferred asset configuration rejects a retired player on the same screen")
    func deferredAssetConfigurationRequiresCurrentPlayerIdentity() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for asset-readiness identity test")
            return
        }
        let bookmark = Data([0xA1])
        let currentURL = URL(fileURLWithPath: "/tmp/asset-ready-current.mov")
        let retired = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/asset-ready-retired.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        let current = WallpaperVideoPlayer(
            url: currentURL,
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: current))
        defer {
            retired.cleanup()
            screen.resetRuntimeSession()
        }

        let persistence = AssetReadinessConfigurationPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: bookmark
        )
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.effectConfig.blurRadius = 2
        store.save(configuration)

        var effectsApplyCount = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (currentURL, false) },
                refreshData: { _ in bookmark }
            ),
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in effectsApplyCount += 1 },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )

        let didApply = coordinator.applyAssetReadyConfigurationIfCurrent(
            player: retired,
            screenID: screen.id
        )

        #expect(!didApply)
        #expect(effectsApplyCount == 0)
        #expect(screen.videoPlayer === current)
    }

    @Test("Deferred asset readiness applies the latest same-player configuration")
    func deferredAssetConfigurationUsesLatestConfiguration() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for deferred configuration test")
            return
        }
        let bookmark = Data([0xA2])
        let videoURL = URL(fileURLWithPath: "/tmp/asset-ready-latest.mov")
        let player = WallpaperVideoPlayer(
            url: videoURL,
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: player))

        let persistence = AssetReadinessConfigurationPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        var startupConfiguration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: bookmark,
            frameRateLimit: .fps15,
            particleEffect: .snow
        )
        startupConfiguration.displayFingerprint = screen.displayFingerprint
        startupConfiguration.effectConfig.blurRadius = 1
        startupConfiguration.effectConfig.particleDensity = 0.5
        store.save(startupConfiguration)

        var appliedConfigurations: [ScreenConfiguration] = []
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (videoURL, false) },
                refreshData: { _ in bookmark }
            ),
            applyPolicy: { _ in },
            applyVideoEffects: { _, configuration in
                appliedConfigurations.append(configuration)
            },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
        defer {
            coordinator.transition.cancelAssetReadiness(for: screen.id)
            screen.resetRuntimeSession()
        }

        coordinator.applyConfigurationWhenAssetReady(
            player: player,
            screen: screen,
            fallbackDelay: .milliseconds(50)
        )

        var latestConfiguration = startupConfiguration
        latestConfiguration.frameRateLimit = .fps30
        latestConfiguration.particleEffect = .rain
        latestConfiguration.effectConfig.blurRadius = 4
        latestConfiguration.effectConfig.particleDensity = 2
        store.save(latestConfiguration)

        try await Self.waitUntil(timeout: .seconds(1)) {
            appliedConfigurations.count == 1
        }

        let applied = try #require(appliedConfigurations.first)
        #expect(applied.frameRateLimit == .fps30)
        #expect(applied.particleEffect == .rain)
        #expect(applied.effectConfig.blurRadius == 4)
        #expect(applied.effectConfig.particleDensity == 2)
    }

    @Test("Deferred asset configuration rejects a changed package entry")
    func deferredAssetConfigurationRequiresCurrentPackageEntry() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for package-entry identity test")
            return
        }
        let bookmark = Data([0xA3])
        let packageURL = URL(fileURLWithPath: "/tmp/asset-ready-package.pkg")
        let player = WallpaperVideoPlayer(
            url: packageURL,
            frame: screen.frame,
            packageEntryName: "original/video.mp4",
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: player))
        defer { screen.resetRuntimeSession() }

        let persistence = AssetReadinessConfigurationPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        var configuration = ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .video(
                bookmarkData: bookmark,
                packageEntryName: "replacement/video.mp4"
            )
        )
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.effectConfig.blurRadius = 2
        store.save(configuration)

        var effectsApplyCount = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (packageURL, false) },
                refreshData: { _ in bookmark }
            ),
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in effectsApplyCount += 1 },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )

        let didApply = coordinator.applyAssetReadyConfigurationIfCurrent(
            player: player,
            screenID: screen.id
        )

        #expect(!didApply)
        #expect(effectsApplyCount == 0)
    }

    @Test("Retiring an outgoing video cancels readiness and player-scoped effects work")
    func retiringOutgoingVideoCancelsOwnedAsyncWork() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for outgoing-video retirement test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let outgoing = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/outgoing-video-work.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: outgoing))
        defer { screen.resetRuntimeSession() }

        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data()
        )
        configuration.effectConfig.blurRadius = 2
        manager.effectsCoordinator.applyVideoEffects(
            for: screen,
            config: configuration
        )
        #expect(manager.effectsCoordinator.hasActiveWork(
            for: screen.id,
            player: outgoing
        ))
        let effectsRevisionBeforeRetirement =
            manager.effectsCoordinator.workRevision(
                for: screen.id,
                player: outgoing
            )

        let readinessTask = Self.makeSuspendedTask()
        manager.transitionRegistry.setAssetReadiness(
            Self.makeWork(task: readinessTask),
            for: screen.id
        )

        manager.retireOutgoingVideoWork(for: screen.id, player: outgoing)

        #expect(readinessTask.isCancelled)
        #expect(!manager.effectsCoordinator.hasActiveWork(
            for: screen.id,
            player: outgoing
        ))
        #expect(manager.effectsCoordinator.workRevision(
            for: screen.id,
            player: outgoing
        ) == 0)
        #expect(effectsRevisionBeforeRetirement > 0)
        #expect(manager.effectsCoordinator.trackedWorkKeyCount(for: screen.id) == 0)
    }

    @Test("Runtime release terminally removes every effects WorkKey for the screen")
    func runtimeReleaseRetiresAllEffectsKeys() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for effects teardown test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let first = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/teardown-effects-first.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: first))
        defer {
            first.cleanup()
            screen.resetRuntimeSession()
        }

        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data()
        )
        configuration.effectConfig.blurRadius = 2
        manager.effectsCoordinator.applyVideoEffects(
            for: screen,
            config: configuration
        )
        #expect(manager.effectsCoordinator.trackedWorkKeyCount(for: screen.id) == 1)

        manager.releaseRuntimeSession(screen)

        #expect(manager.effectsCoordinator.trackedWorkKeyCount(for: screen.id) == 0)
    }

    @Test("Retry effects probes preserve lazy coordinator initialization")
    func retryEffectsProbesDoNotInitializeCoordinator() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for retry effects probe test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-effects-probe.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        defer { player.cleanup() }

        #expect(!manager.effectsCoordinatorWasInitialized)
        #expect(manager.playbackCoordinator.effectsWorkRevision(
            screen.id,
            player
        ) == nil)
        #expect(!manager.playbackCoordinator.effectsWorkIsActive(
            screen.id,
            player
        ))
        #expect(!manager.effectsCoordinatorWasInitialized)
    }

    // MARK: - ScreenManager → PlaybackCoordinator setter forwarding

    @Test("updatePlaybackSpeed mutates configuration and posts a change notification")
    func updatePlaybackSpeedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let target = Self.differentValue(
                from: manager.getConfiguration(for: screen)?.playbackSpeed,
                options: [0.5, 0.75, 1.0, 1.5]
            )
            try await Self.expectChange(notificationFor: screen) {
                manager.updatePlaybackSpeed(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == target)
        }
    }

    @Test("updateMuted mutates configuration and posts a change notification")
    func updateMutedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.muted ?? true
            let target = !current
            try await Self.expectChange(notificationFor: screen) {
                manager.updateMuted(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.muted == target)
        }
    }

    @Test("updateVideoVolume mutates configuration and posts a change notification")
    func updateVideoVolumeForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let target = 0.42
            try await Self.expectChange(notificationFor: screen) {
                manager.updateVideoVolume(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.videoVolume == target)
        }
    }

    @Test("updateFitMode mutates configuration and posts a change notification")
    func updateFitModeForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.fitMode ?? .aspectFill
            let target: VideoFitMode = current == .aspectFill ? .aspectFit : .aspectFill
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFitMode(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.fitMode == target)
        }
    }

    @Test("updateFrameRateLimit mutates configuration and posts a change notification")
    func updateFrameRateLimitForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.frameRateLimit ?? .matchDisplay
            let target: FrameRateLimit = current == .matchDisplay ? .fps30 : .matchDisplay
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFrameRateLimit(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.frameRateLimit == target)
        }
    }

    @Test("Re-applying the current playback speed is a no-op (no notification)")
    func updatePlaybackSpeedWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            guard let currentSpeed = manager.getConfiguration(for: screen)?.playbackSpeed else {
                Issue.record("Seeded configuration is missing playbackSpeed")
                return
            }
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updatePlaybackSpeed(currentSpeed, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == currentSpeed)
        }
    }

    @Test("Re-applying the current effect config is a no-op (no notification)")
    func updateEffectConfigWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentConfig = try #require(manager.getConfiguration(for: screen)?.effectConfig)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateEffectConfig(currentConfig, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.effectConfig == currentConfig)
        }
    }

    @Test("Re-applying the current particle effect is a no-op (no notification)")
    func updateParticleEffectWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentEffect = try #require(manager.getConfiguration(for: screen)?.particleEffect)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateParticleEffect(currentEffect, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.particleEffect == currentEffect)
        }
    }

    @Test("Re-applying the current weather-reactive setting is a no-op (no notification)")
    func setWeatherReactiveWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let currentValue = try #require(manager.getConfiguration(for: screen)?.effectConfig.weatherReactive as Bool?)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.setWeatherReactive(currentValue, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.effectConfig.weatherReactive == currentValue)
        }
    }

    // MARK: - Wallpaper type lifecycle regressions

    @Test("Switching to video without a saved video leaves the active HTML session intact")
    func switchToVideoWithoutSavedVideoIsNonDestructive() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToVideoWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
            #expect(capture.notifications.isEmpty)
        }
    }

    @Test("Updating video mode without a saved video leaves the active HTML session intact")
    func updateWallpaperModeWithoutSavedVideoIsIgnored() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateWallpaperMode(.playlist, for: screen)
            await Self.drainMainQueue()

            let config = try #require(manager.getConfiguration(for: screen))
            #expect(config.wallpaperType == .html)
            #expect(config.wallpaperMode == .playlist)
            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
        }
    }

    @Test("Switching to video while the same video wallpaper is already active keeps the live session")
    func switchToVideoWhenAlreadyActiveKeepsSession() async throws {
        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "switch-video")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try await Self.runWithVideoConfiguration(bookmarkData: fixture.bookmark) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .video)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToVideoWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .video)
        }
    }

    @Test("Re-applying the same scene wallpaper keeps the live session")
    func setSameSceneWallpaperKeepsSession() async throws {
        let descriptor = Self.makeSceneDescriptor()

        try await Self.runWithSceneConfiguration(descriptor: descriptor) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .scene)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.setSceneWallpaper(descriptor: descriptor, origin: nil, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .scene)
        }
    }

    @Test("Same-scene rebuild keeps the page mounted and failure details remain opt-in")
    func sameSceneRebuildDoesNotInspectAttempt() async throws {
        let original = Self.makeSceneDescriptor()
        try await Self.runWithSceneConfiguration(descriptor: original) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .scene)
            screen.installRuntimeSession(session)
            let replacement = original.withPropertyOverrides(["enabled": .bool(false)])

            await manager.updateSceneDescriptor(replacement, for: screen)

            let attempt = try #require(manager.wallpaperLoads.attempt(for: screen))
            #expect(!attempt.isInspecting)
            #expect(manager.inspectedWallpaperAttempt(for: screen) == nil)
            #expect(attempt.failure != nil)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.activeWallpaper == .scene(original))

            manager.inspectWallpaperAttempt(true, for: screen)
            #expect(manager.inspectedWallpaperAttempt(for: screen)?.id == attempt.id)
        }
    }

    @Test("An unavailable scene candidate keeps the live session and persisted descriptor")
    func unavailableSceneCandidateKeepsSessionAndConfiguration() async throws {
        let original = Self.makeSceneDescriptor()
        let replacement = Self.makeSceneDescriptor()

        try await Self.runWithSceneConfiguration(descriptor: original) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .scene)
            screen.installRuntimeSession(session)

            manager.setSceneWallpaper(descriptor: replacement, origin: nil, for: screen)
            #expect(manager.inspectedWallpaperAttempt(for: screen) != nil)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.activeWallpaper == .scene(original))
        }
    }

    @Test("A video candidate that has not produced a frame keeps the live player")
    func unreadyVideoCandidateKeepsLivePlayer() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for video replacement test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let first = try Self.makeTemporaryVideoBookmark(prefix: "old-video")
        let second = try Self.makeTemporaryVideoBookmark(prefix: "new-video")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
            screen.resetRuntimeSession()
        }

        let configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: second.bookmark)
        SettingsManager.shared.replaceAllConfigurations([configuration])
        let store = WallpaperConfigurationStore()
        _ = store.loadAll()

        let oldPlayer = WallpaperVideoPlayer(url: first.url, frame: screen.frame)
        screen.installRuntimeSession(VideoWallpaperSession(player: oldPlayer))

        var releaseCount = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { target in
                releaseCount += 1
                target.resetRuntimeSession()
            },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
        defer { coordinator.transition.cancelAssetReadiness(for: screen.id) }

        coordinator.applyConfiguration(configuration, to: screen, preservingState: false)
        await Self.drainMainQueue()

        let currentPlayer = try #require(screen.videoPlayer)
        #expect(releaseCount == 0)
        #expect(currentPlayer === oldPlayer)
        #expect(Self.canonicalFilePath(currentPlayer.videoURL) == Self.canonicalFilePath(first.url))
    }

    @Test("Applying a config to the existing video player syncs audio settings")
    func applyConfigurationSyncsAudioSettingsToExistingPlayer() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for PlaybackCoordinator audio sync test")
            return
        }

        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "audio-sync")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: fixture.bookmark)
        configuration.muted = true
        configuration.videoVolume = 0.35
        SettingsManager.shared.replaceAllConfigurations([configuration])
        let store = WallpaperConfigurationStore()
        _ = store.loadAll()

        let player = WallpaperVideoPlayer(url: fixture.url, frame: screen.frame, loadImmediately: false)
        player.setMuted(false)
        player.setVolume(0.9)
        screen.installRuntimeSession(VideoWallpaperSession(player: player))
        defer { screen.resetRuntimeSession() }

        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { target in target.resetRuntimeSession() },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
        defer { coordinator.transition.cancelAssetReadiness(for: screen.id) }

        coordinator.applyConfiguration(configuration, to: screen, preservingState: true)

        let currentPlayer = try #require(screen.videoPlayer)
        #expect(currentPlayer === player)
        #expect(currentPlayer.isMuted)
        #expect(currentPlayer.audioVolume == 0.35)
    }

    @Test("Duplicate video audio leadership keeps only the first unmuted screen audible")
    func duplicateVideoAudioLeadershipKeepsSingleAudibleScreen() {
        let entries = [
            VideoAudioLeadershipPolicy.Entry(screenID: 1, urlKey: "/wallpapers/shared.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 2, urlKey: "/wallpapers/shared.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 3, urlKey: "/wallpapers/other.mp4", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 4, urlKey: "/wallpapers/shared.mp4", userMuted: true)
        ]

        let effective = VideoAudioLeadershipPolicy.effectiveMutedStates(for: entries)

        #expect(effective[1] == false)
        #expect(effective[2] == true)
        #expect(effective[3] == false)
        #expect(effective[4] == true)
    }

    @Test("Two HTML screens sharing a source elect exactly one audio leader")
    func duplicateHTMLAudioLeadershipElectsSingleLeader() {
        // Descending order on purpose: the election must be deterministic on
        // screenID, not on screen enumeration order.
        let entries = [
            VideoAudioLeadershipPolicy.Entry(screenID: 2, urlKey: "html:same-source", userMuted: false),
            VideoAudioLeadershipPolicy.Entry(screenID: 1, urlKey: "html:same-source", userMuted: false)
        ]

        let effective = HTMLWallpaperCoordinator.effectiveAudioMutedStates(for: entries)

        #expect(effective[1] == false)
        #expect(effective[2] == true)
    }

    @Test("Package entries make distinct video audio URL keys for one pkg path")
    func videoAudioURLKeyDistinguishesPackageEntries() {
        let url = URL(fileURLWithPath: "/wallpapers/scene.pkg")

        let intro = PlaybackCoordinator.videoAudioURLKey(for: url, packageEntryName: "intro.mp4")
        let loop = PlaybackCoordinator.videoAudioURLKey(for: url, packageEntryName: "loop.mp4")
        let plain = PlaybackCoordinator.videoAudioURLKey(for: url)

        #expect(intro != loop)
        #expect(intro != plain)
        #expect(plain == "/wallpapers/scene.pkg")
        #expect(PlaybackCoordinator.videoAudioURLKey(for: nil, packageEntryName: "intro.mp4") == nil)
    }

    @Test("Video validation failure is surfaced as a runtime error for the screen")
    func setVideoValidationFailureSurfacesRuntimeError() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for video validation error test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let fixture = try Self.makeTemporaryVideoBookmark(prefix: "validation-error")
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            screen.resetRuntimeSession()
        }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(validationError: .validationFailed),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        manager.setVideo(url: fixture.url, bookmarkData: fixture.bookmark, for: screen)

        for _ in 0..<20 where manager.runtimeError(for: screen) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let error = try #require(manager.runtimeError(for: screen))
        guard case .mediaNotPlayable(let url, _) = error else {
            Issue.record("Expected mediaNotPlayable, got \(error)")
            return
        }
        #expect(url == fixture.url)
    }

    @Test("Updating live HTML config hot-applies ordinary toggles without rebuilding the session")
    func updateHTMLConfigHotAppliesWithoutRebuild() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.allowMouseInteraction = true
            updated.customCSS = "html { background: black; }"

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(session.appliedHTMLConfigs == [updated])
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Updating Wallpaper Engine project property overrides hot-applies without rebuilding the session")
    func updateHTMLConfigProjectPropertiesHotAppliesWithoutRebuild() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            var updated = HTMLConfig.default
            updated.wallpaperEngineProjectProperties = [
                "mouseactions": .bool(true),
                "bgmvolume": .number(35),
                "modelresolution": .string("4k")
            ]

            try await Self.expectChange(notificationFor: screen) {
                manager.updateHTMLConfig(updated, for: screen)
            }

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(session.appliedHTMLConfigs == [updated])
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == updated)
        }
    }

    @Test("Switching to HTML while the same HTML wallpaper is already active keeps the live session")
    func switchToHTMLWhenAlreadyActiveKeepsSession() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.switchToHTMLWallpaper(for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    @Test("Re-applying the current HTML config is a no-op (no notification)")
    func updateHTMLConfigWithSameValueIsNoOp() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let currentConfig = try #require(manager.getConfiguration(for: screen)?.htmlConfig)
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updateHTMLConfig(currentConfig, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(session.cleanupCount == 0)
            #expect(session.appliedHTMLConfigs.isEmpty)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == currentConfig)
        }
    }

    @Test("A failed remote reload after trusting an origin keeps the live page")
    func failedRemoteReloadAfterTrustKeepsSession() async throws {
        let originURL = try #require(URL(string: "https://html-refresh-\(UUID().uuidString).example.com/live"))
        let source = HTMLSource.url(originURL)
        let origin = try #require(TrustedHTMLOrigin(url: originURL))
        var config = HTMLConfig.default
        config.allowJavaScript = true

        try await Self.runWithHTMLConfiguration(source: source, config: config) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            defer { _ = TrustedHostStore.shared.revoke(origin) }

            #expect(TrustedHostStore.shared.trust(origin))
            manager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    @Test("A failed remote reload after revoking an origin keeps the live page")
    func failedRemoteReloadAfterRevokeKeepsSession() async throws {
        let originURL = try #require(URL(string: "https://html-revoke-\(UUID().uuidString).example.com/live"))
        let source = HTMLSource.url(originURL)
        let origin = try #require(TrustedHTMLOrigin(url: originURL))
        var config = HTMLConfig.default
        config.allowJavaScript = true

        #expect(TrustedHostStore.shared.trust(origin))
        defer { _ = TrustedHostStore.shared.revoke(origin) }

        try await Self.runWithHTMLConfiguration(source: source, config: config) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)

            #expect(TrustedHostStore.shared.revoke(origin))
            manager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
            await Self.drainMainQueue()

            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.wallpaperType == .html)
        }
    }

    // The candidate must be one that can never become ready: an inline source would commit
    // (`about:blank` is allowed), so this points at a port nothing listens on.
    static let unreachableSource = HTMLSource.url(URL(string: "http://127.0.0.1:1/")!)

    @Test("A rebuild-required JavaScript change stays uncommitted until the candidate is ready")
    func unreadyJavaScriptRebuildKeepsSessionAndConfiguration() async throws {
        try await Self.runWithHTMLConfiguration(source: Self.unreachableSource) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let previous = try #require(manager.getConfiguration(for: screen)?.htmlConfig)
            let capture = Self.attachConfigurationObserver()
            defer {
                capture.detach()
                _ = manager.bumpTransition(for: screen.id)
            }

            var updated = HTMLConfig.default
            updated.allowJavaScript = false

            manager.updateHTMLConfig(updated, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == previous)
        }
    }

    @Test("A rebuild-required tracker change stays uncommitted until the candidate is ready")
    func unreadyTrackerRebuildKeepsSessionAndConfiguration() async throws {
        try await Self.runWithHTMLConfiguration(source: Self.unreachableSource) { manager, screen in
            let session = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(session)
            let previous = try #require(manager.getConfiguration(for: screen)?.htmlConfig)
            let capture = Self.attachConfigurationObserver()
            defer {
                capture.detach()
                _ = manager.bumpTransition(for: screen.id)
            }

            var updated = HTMLConfig.default
            updated.blockTrackers = false

            manager.updateHTMLConfig(updated, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(session.cleanupCount == 0)
            #expect(Self.isSameSession(screen.runtimeSession, session))
            #expect(manager.getConfiguration(for: screen)?.htmlConfig == previous)
        }
    }

    @Test("Cancelled HTML navigations do not surface as runtime errors")
    func cancelledHTMLNavigationIsIgnored() {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { view.cleanup() }

        var errors: [WallpaperRuntimeError] = []
        view.onError = { errors.append($0) }

        view.webView(
            WKWebView(frame: .zero),
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )

        #expect(errors.isEmpty)
    }

    @Test("Late HTML navigation failures after cleanup do not surface as runtime errors")
    func lateHTMLNavigationFailureAfterCleanupIsIgnored() {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))

        var errors: [WallpaperRuntimeError] = []
        view.onError = { errors.append($0) }
        view.cleanup()

        view.webView(
            WKWebView(frame: .zero),
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        )

        #expect(errors.isEmpty)
    }

    @Test("Apply to All Displays commits every target inside one manual switch group", .timeLimit(.minutes(1)))
    func applyToAllDisplaysSharesOneSwitchGroup() async throws {
        guard let display = NSScreen.screens.first else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let source = UndoTestManager.makeScreen("Group Source", x: 0)
        let targets = [UndoTestManager.makeScreen("Group Target A", x: 800), UndoTestManager.makeScreen("Group Target B", x: 1600)]
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }
        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: source.id, wallpaper: .html(source: .inline("<p>all</p>"), config: .default)),
        ])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            // A real NSScreen for refresh-rate lookups: the stand-ins trap on `maximumFramesPerSecond`.
            displayRegistry: FakeDisplayRegistry(
                screens: [source] + targets,
                nsScreensByID: Dictionary(uniqueKeysWithValues: ([source] + targets).map { ($0.id, display) })
            ),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            for screen in [source] + targets {
                screen.resetRuntimeSession()
            }
        }
        @MainActor final class CommitGroups { var byScreen: [CGDirectDisplayID: WallpaperSwitchGroup?] = [:] }
        let commits = CommitGroups()
        // Queue nil: the commit's save posts from a task it spawned, which inherits the commit's task-locals.
        let observer = NotificationCenter.default.addObserver(
            forName: .wallpaperConfigurationDidChange, object: nil, queue: nil
        ) { notification in
            guard let id = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            MainActor.assumeIsolated { commits.byScreen[id] = WallpaperSwitchGroup.current }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.applyConfigurationToAllDisplays(from: source)
        try await Self.waitUntil(timeout: .seconds(20)) { targets.allSatisfy { commits.byScreen[$0.id] != nil } }

        let groups = targets.map { commits.byScreen[$0.id] ?? nil }
        let group = try #require(groups.first ?? nil, "the targets committed outside any switch group")
        #expect(group.pace == .manual)
        #expect(groups.allSatisfy { $0 === group })
    }

    @Test("Apply to All Displays releases its targets together", .timeLimit(.minutes(1)))
    func applyToAllDisplaysReleasesTargetsTogether() async throws {
        guard let display = NSScreen.screens.first else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let source = UndoTestManager.makeScreen("Barrier Source", x: 0)
        let targets = [UndoTestManager.makeScreen("Barrier Target A", x: 800), UndoTestManager.makeScreen("Barrier Target B", x: 1600)]
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }
        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: source.id, wallpaper: .html(source: .inline("<p>all</p>"), config: .default)),
        ])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            // A real NSScreen for refresh-rate lookups: the stand-ins trap on `maximumFramesPerSecond`.
            displayRegistry: FakeDisplayRegistry(
                screens: [source] + targets,
                nsScreensByID: Dictionary(uniqueKeysWithValues: ([source] + targets).map { ($0.id, display) })
            ),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            for screen in [source] + targets {
                screen.resetRuntimeSession()
            }
        }
        @MainActor final class CommitGroups { var byScreen: [CGDirectDisplayID: WallpaperSwitchGroup?] = [:] }
        let commits = CommitGroups()
        // Queue nil: the commit's save posts from a task it spawned, which inherits the commit's task-locals.
        let observer = NotificationCenter.default.addObserver(
            forName: .wallpaperConfigurationDidChange, object: nil, queue: nil
        ) { notification in
            guard let id = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            MainActor.assumeIsolated { commits.byScreen[id] = WallpaperSwitchGroup.current }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.applyConfigurationToAllDisplays(from: source)
        try await Self.waitUntil(timeout: .seconds(20)) { targets.allSatisfy { commits.byScreen[$0.id] != nil } }

        let group = try #require(commits.byScreen[targets[0].id] ?? nil, "the targets committed outside any switch group")
        let start = try #require(group.barrier.start(for: targets[0].id), "the first target was released alone")
        #expect(group.barrier.start(for: targets[1].id) == start)
    }

    // MARK: - Helpers

    @Test("Background automation failures preserve the desktop and never take over its inspector")
    func automationFailuresDoNotInspectCandidates() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            defer { manager.tearDownForTermination() }
            let original = try #require(manager.getConfiguration(for: screen))
            let runtime = TestRuntimeSession(wallpaperType: .html)
            screen.installRuntimeSession(runtime)
            var proposal = original
            proposal.activeWallpaper = .scene(SceneDescriptor(
                workshopID: "missing-automation-source", cacheRelativePath: "../invalid",
                entryFile: "scene.json", capabilityTier: .imageOnly
            ))
            let sceneResult = await manager.prepareAutomationWallpaper(proposal, for: screen, source: nil, isStillIntended: { true })
            #expect(sceneResult == .failed)
            #expect(manager.wallpaperLoads.attempt(for: screen)?.isInspecting == false)
            #expect(Self.isSameSession(screen.runtimeSession, runtime))
            #expect(manager.getConfiguration(for: screen) == original)

            proposal.activeWallpaper = .video(bookmarkData: Data([0xFF]))
            let videoResult = await manager.prepareAutomationWallpaper(proposal, for: screen, source: nil, isStillIntended: { true })
            #expect(videoResult == .failed)
            #expect(manager.wallpaperLoads.attempt(for: screen) == nil)
            #expect(Self.isSameSession(screen.runtimeSession, runtime))
            #expect(manager.getConfiguration(for: screen) == original)
        }
    }

    @Test("An automatic switch is marked before its commit announces the new configuration", .timeLimit(.minutes(1)))
    func automaticSwitchIsMarkedBeforeCommitNotification() async throws {
        try await Self.runWithHTMLConfiguration { manager, screen in
            defer { manager.tearDownForTermination() }
            var queued = try #require(manager.getConfiguration(for: screen))
            queued.wallpaperQueue = ["a", "b"].map {
                WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline("<p>\($0)</p>"), config: .default))
            }
            queued.playlistCursorIndex = 0
            manager.saveConfiguration(queued)
            await Self.drainMainQueue()
            @MainActor final class Serials { var seen: [Int?] = [] }
            let serials = Serials()
            let fingerprint = screen.displayFingerprint
            let screenID = screen.id
            let observer = NotificationCenter.default.addObserver(
                forName: .wallpaperConfigurationDidChange, object: nil, queue: .main
            ) { notification in
                guard notification.userInfo?["screenID"] as? CGDirectDisplayID == screenID else { return }
                MainActor.assumeIsolated {
                    serials.seen.append(manager.automaticSwitchMark(for: fingerprint)?.serial)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            manager.advancePlaylist(for: screen)
            try await Self.waitUntil(timeout: .seconds(20)) { manager.automaticSwitchMark(for: fingerprint) != nil }
            await Self.drainMainQueue()

            #expect(serials.seen == [1], "the panel read the switch serial before the switch was marked, so an open trial survives it")
        }
    }

    private static func makeSuspendedTask() -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private static func makeWork(task: Task<Void, Never>) -> AssetReadinessWork {
        let work = AssetReadinessWork()
        work.fallbackTask = task
        return work
    }

    private static func differentValue<T: Equatable>(from current: T?, options: [T]) -> T {
        precondition(!options.isEmpty, "differentValue requires a non-empty option set")
        if let current, let next = options.first(where: { $0 != current }) {
            return next
        }
        return options[0]
    }

    private static func canonicalFilePath(_ url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private static func runWithSeededConfiguration(
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        if !originalConfigurations.contains(where: { $0.screenID == screen.id }) {
            SettingsManager.shared.saveConfiguration(
                ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>x</p>"), config: .default))
            )
        }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        guard manager.getConfiguration(for: screen) != nil else {
            Issue.record("Could not seed a ScreenConfiguration for the host screen")
            return
        }

        try await body(manager, screen)
    }

    private static func runWithHTMLConfiguration(
        source: HTMLSource = .inline("<html><body></body></html>"),
        config: HTMLConfig = .default,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screen.id,
                wallpaper: .html(source: source, config: config),
                savedVideoBookmarkData: nil
            )
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func runWithVideoConfiguration(
        bookmarkData: Data,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmarkData)
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func runWithSceneConfiguration(
        descriptor: SceneDescriptor,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        defer { screen.resetRuntimeSession() }
        try await body(manager, screen)
    }

    private static func makeTemporaryVideoBookmark(prefix: String) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-\(prefix)-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, bookmark)
    }

    private static func makeSceneDescriptor() -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "scene-refresh-\(UUID().uuidString)",
            cacheRelativePath: "wpe-cache/scene-refresh",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }

    private static func isSameSession(
        _ lhs: (any WallpaperRuntimeSession)?,
        _ rhs: TestRuntimeSession
    ) -> Bool {
        guard let lhs else { return false }
        return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs)
    }

    private static func expectChange(
        notificationFor screen: Screen,
        _ mutation: () -> Void
    ) async throws {
        let capture = attachConfigurationObserver()
        defer { capture.detach() }

        mutation()
        try await capture.waitForNotifications(count: 1, timeout: .seconds(3))

        #expect(capture.notifications.count == 1)
        #expect(capture.notifications.first?.screenID == screen.id)
    }

    private static func attachConfigurationObserver() -> ConfigurationNotificationCapture {
        ConfigurationNotificationCapture(name: .wallpaperConfigurationDidChange)
    }

    private static func drainMainQueue() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        await Task.yield()
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for deferred asset configuration")
    }
}

@MainActor
private final class AssetReadinessConfigurationPersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.screenID, $0) }
        )
    }
}

private final class ConfigurationNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScreenChangeRecord] = []
    private var observer: NSObjectProtocol?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let record = ScreenChangeRecord(
                screenID: ConfigurationNotificationCapture.screenID(from: notification)
            )
            self?.append(record)
        }
    }

    deinit {
        detach()
    }

    var notifications: [ScreenChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func waitForNotifications(count: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if notifications.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func append(_ record: ScreenChangeRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }

    private static func screenID(from notification: Notification) -> CGDirectDisplayID? {
        let raw = notification.userInfo?["screenID"]
        if let direct = raw as? CGDirectDisplayID { return direct }
        if let number = raw as? NSNumber { return CGDirectDisplayID(number.uint32Value) }
        return nil
    }
}

private struct ScreenChangeRecord: Sendable {
    let screenID: CGDirectDisplayID?
}

@MainActor
private final class TestRuntimeSession: WallpaperRuntimeSession, HTMLWallpaperConfigApplying {
    let wallpaperType: WallpaperType
    private(set) var cleanupCount = 0
    private(set) var appliedHTMLConfigs: [HTMLConfig] = []
    var prepareAction: (@MainActor () async -> WallpaperPreparationResult)?

    init(wallpaperType: WallpaperType) {
        self.wallpaperType = wallpaperType
    }

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: .active,
            supportsPlaybackControl: false,
            subtitle: nil
        )
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func updateFrame(to frame: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        await prepareAction?() ?? .ready
    }

    func cleanup() { cleanupCount += 1 }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        appliedHTMLConfigs.append(config)
        return true
    }
}
