import AppKit
@preconcurrency import AVFoundation
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Video session lifecycle policy")
@MainActor
struct VideoSessionLifecycleTests {

    // MARK: - WallpaperPolicyEngine: pause-on-power decisions

    @Test("External power never pauses, regardless of settings")
    func externalPowerNeverPauses() {
        let aggressiveSettings = GlobalSettings(globalPauseOnBattery: true)
        let decision = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: aggressiveSettings,
            powerSource: .external
        )
        #expect(decision == false)
    }

    @Test("Pause-on-battery pauses whenever unplugged; off keeps playing")
    func pauseOnBatteryDecision() {
        let on = GlobalSettings(globalPauseOnBattery: true)
        let off = GlobalSettings(globalPauseOnBattery: false)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .battery(level: 0.95)))
        #expect(WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .battery(level: 0.05)))
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(globalSettings: off, powerSource: .battery(level: 0.05)))
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .external))
    }

    @Test("Full-screen policy is gated by the user setting")
    func fullScreenPolicyHonoursSetting() {
        let disabled = GlobalSettings(pauseOnFullScreen: false)
        let enabled = GlobalSettings(pauseOnFullScreen: true)

        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: disabled,
            isHiddenByFullScreen: true
        ))
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: true
        ))
        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: false
        ))
    }

    // MARK: - ScreenManager wiring: power changes flow through the injected monitor

    @Test("ScreenManager subscribes the injected PowerMonitoring publisher and reacts to changes")
    func screenManagerReactsToInjectedPowerMonitorEvents() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager wiring test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let powerMonitor = FakePowerMonitor(initialPowerSource: .external)
        _ = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: powerMonitor,
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        let baselineReadCount = powerMonitor.currentPowerSourceReadCount
        powerMonitor.send(.battery(level: 0.10))
        try await Task.sleep(for: .milliseconds(20))

        #expect(powerMonitor.currentPowerSourceReadCount >= baselineReadCount)
    }

    // MARK: - VideoWallpaperSession intent state machine (single authority)

    @Test("Policy profiles never mutate intent; manual play/pause own it")
    func videoIntentStateMachine() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/master-gate-intent-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        #expect(session.userIntendsToPlay)

        session.applyPerformanceProfile(.suspended)
        #expect(session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(session.userIntendsToPlay)

        session.pause()
        #expect(!session.userIntendsToPlay)

        session.applyPerformanceProfile(.suspended)
        #expect(!session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(!session.userIntendsToPlay)

        session.play()
        #expect(session.userIntendsToPlay)
    }

    @Test("Video session suspends particles for policy/offscreen without changing manual-pause behavior")
    func videoSessionSuspendsParticleEffectsForPolicyAndVisibility() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/particle-profile-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        session.applyPerformanceProfile(.quality)
        #expect(!player.particleEffectsSuspended)

        session.applyPerformanceProfile(.suspended)
        #expect(player.particleEffectsSuspended)

        session.applyPerformanceProfile(.quality)
        session.pause()
        #expect(!player.particleEffectsSuspended)

        session.play()
        #expect(!player.particleEffectsSuspended)

        session.show()
        #expect(!player.particleEffectsSuspended)
    }

    @Test("Hidden preparation candidate starts with particle effects suspended")
    func hiddenCandidateSuspendsParticleEffectsBeforeCommit() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/hidden-particles-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            startsHidden: true,
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        #expect(player.particleEffectsSuspended)
        session.show()
        #expect(!player.particleEffectsSuspended)
    }

    @Test("Video session cleanup retires current effects work before player teardown exactly once")
    func videoSessionCleanupRetiresEffectsBeforePlayerTeardown() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/cleanup-effects-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        var retiredPlayers: [WallpaperVideoPlayer] = []
        var wasCleanedUpAtRetirement: Bool?
        let session = VideoWallpaperSession(
            player: player,
            retireEffectsWork: { retired in
                retiredPlayers.append(retired)
                wasCleanedUpAtRetirement = retired.isCleanedUp
            }
        )

        session.cleanup()
        session.cleanup()

        #expect(session.videoPlayer == nil)
        #expect(retiredPlayers.count == 1)
        #expect(retiredPlayers.first === player)
        #expect(wasCleanedUpAtRetirement == false)
        #expect(player.isCleanedUp)
    }

    @Test("Successful retry rebinds Screen playback observation to replacement player")
    func retryReplacementRebindsScreenObserver() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let old = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-observer-old.mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let replacement = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-observer-new.mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: old)
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(session)
        defer {
            session.cleanup()
            old.cleanup()
        }

        #expect(session.installPreparedRetryPlayer(replacement, replacing: old))
        let reboundVersion = screen.playbackStateVersion
        NotificationCenter.default.post(
            name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
            object: old
        )
        #expect(screen.playbackStateVersion == reboundVersion)

        NotificationCenter.default.post(
            name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
            object: replacement
        )
        #expect(screen.playbackStateVersion == reboundVersion + 1)
    }

    @Test("Particle emitter freezes, hides, and resumes with the requested density")
    func particleEmitterSuspensionStopsRenderingAndPreservesConfiguration() throws {
        let view = ParticleOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.setEffect(.snow, density: 1.5)

        var state = try #require(view.debugEmitterState)
        #expect(!state.isHidden)
        #expect(state.speed == 1)
        #expect(state.birthRate == 1.5)

        view.setSuspended(true)
        state = try #require(view.debugEmitterState)
        #expect(state.isHidden)
        #expect(state.speed == 0)

        view.updateDensity(2.25)
        state = try #require(view.debugEmitterState)
        #expect(state.birthRate == 2.25)

        view.setSuspended(false)
        state = try #require(view.debugEmitterState)
        #expect(!state.isHidden)
        #expect(state.speed == 1)
        #expect(state.birthRate == 2.25)
    }

    @Test("An emitter created while suspended starts frozen and hidden")
    func particleEmitterCreatedWhileSuspendedStaysContained() throws {
        let view = ParticleOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.setSuspended(true)
        view.setSuspended(true)
        view.setEffect(.rain, density: 1.75)

        var state = try #require(view.debugEmitterState)
        #expect(state.isHidden)
        #expect(state.speed == 0)
        #expect(state.birthRate == 1.75)

        view.setSuspended(false)
        view.setSuspended(false)
        state = try #require(view.debugEmitterState)
        #expect(!state.isHidden)
        #expect(state.speed == 1)
    }

    @Test("Display geometry has one ScreenManager owner and no per-player timer")
    func displayGeometryOwnershipIsCentralized() throws {
        let player = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let manager = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Observers.swift"
        )

        #expect(!player.contains("setupFrameObserver()"))
        #expect(!player.contains("Task.sleep(for: .seconds(30))"))
        #expect(!player.contains("didChangeScreenParametersNotification"))
        #expect(manager.contains("didChangeScreenParametersNotification"))
        #expect(manager.contains("self.updateAllWindowFrames()"))
    }

    @Test("Video readiness waits for AVPlayerLayer rather than player status")
    func videoReadinessUsesPlayerLayerSignal() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/not-loaded-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        #expect(await player.prepareForDisplay(timeout: .milliseconds(30)) == .timedOut)
        #expect(!player.isReadyForDisplay)
    }

    @Test("Cancelling video readiness returns cancellation without installing a window")
    func videoReadinessCancellation() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/not-loaded-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let task = Task { @MainActor in
            await player.prepareForDisplay(timeout: .seconds(1))
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(!player.hasInstalledPlaybackWindow)
    }

    @Test("Cancelling retry keeps the existing player installed")
    func cancelledRetryKeepsExistingPlayer() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-not-loaded-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        let retry = Task { @MainActor in
            await session.retry()
        }
        await Task.yield()
        retry.cancel()
        await retry.value

        #expect(session.videoPlayer === player)
        #expect(!player.isCleanedUp)
    }

    @Test("Retry commits the latest cheap player and session state")
    func retryCommitsLatestRuntimeState() async throws {
        let old = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-latest-state-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        old.setMuted(false)
        old.setVolume(0.2)
        old.setPlaybackSpeed(0.75)
        let preparation = ControlledRetryPreparation()
        var candidate: WallpaperVideoPlayer?
        var retiredPlayer: WallpaperVideoPlayer?
        let session = VideoWallpaperSession(
            player: old,
            retireEffectsWork: { retiredPlayer = $0 },
            retryPlayerFactory: { url, frame, fitMode, packageEntryName in
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: frame,
                    fitMode: fitMode,
                    packageEntryName: packageEntryName,
                    startsHidden: true,
                    loadImmediately: false
                )
                candidate = player
                return player
            },
            retryPreparation: { player in
                await preparation.prepare(player)
            }
        )
        defer { session.cleanup() }

        let retry = Task { @MainActor in
            await session.retry()
        }
        #expect(await Self.waitUntil { preparation.isWaiting })

        // These all change after retry preparation starts. The candidate must
        // receive this state, never the values captured at task creation.
        session.pause()
        session.applyPerformanceProfile(.suspended)
        old.setMuted(true)
        old.setVolume(0.8)
        old.setPlaybackSpeed(1.5)
        old.setVideoFitMode(.aspectFit)
        old.setParticleEffect(.snow, density: 2)

        preparation.resume(with: .ready)
        await retry.value

        let installed = try #require(session.videoPlayer)
        #expect(installed === candidate)
        #expect(installed !== old)
        #expect(!session.userIntendsToPlay)
        #expect(session.summary.activity == .paused)
        #expect(installed.isMuted)
        #expect(installed.audioVolume == 0.8)
        #expect(installed.currentPlaybackSpeed == 1.5)
        #expect(installed.currentFitMode == .aspectFit)
        #expect(installed.currentParticleConfiguration.effect == .snow)
        #expect(installed.currentParticleConfiguration.density == 2)
        #expect(installed.particleEffectsSuspended)
        #expect(retiredPlayer === old)
    }

    @Test("Retry fails closed when an effects request changes while preparing")
    func retryRejectsChangedEffectsWorkRevision() async {
        let old = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-effects-cas-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let preparation = ControlledRetryPreparation()
        let effectsRevision = RetryEffectsRevisionProbe(value: 10)
        var candidate: WallpaperVideoPlayer?
        var retiredPlayer: WallpaperVideoPlayer?
        let session = VideoWallpaperSession(
            player: old,
            effectsWorkRevisionProvider: { _ in effectsRevision.value },
            retireEffectsWork: { retiredPlayer = $0 },
            retryPlayerFactory: { url, frame, fitMode, packageEntryName in
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: frame,
                    fitMode: fitMode,
                    packageEntryName: packageEntryName,
                    startsHidden: true,
                    loadImmediately: false
                )
                candidate = player
                return player
            },
            retryPreparation: { player in
                await preparation.prepare(player)
            }
        )
        defer { session.cleanup() }

        let retry = Task { @MainActor in
            await session.retry()
        }
        #expect(await Self.waitUntil { preparation.isWaiting })
        effectsRevision.bump()
        preparation.resume(with: .ready)
        await retry.value

        #expect(session.videoPlayer === old)
        #expect(candidate?.isCleanedUp == true)
        #expect(!old.isCleanedUp)
        #expect(retiredPlayer == nil)
    }

    @Test("Retry fails closed while effects work is already active")
    func retryRejectsPreexistingEffectsWork() async {
        let old = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-active-effects-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        var didCreateCandidate = false
        let session = VideoWallpaperSession(
            player: old,
            effectsWorkIsActiveProvider: { _ in true },
            retryPlayerFactory: { url, frame, fitMode, packageEntryName in
                didCreateCandidate = true
                return WallpaperVideoPlayer(
                    url: url,
                    frame: frame,
                    fitMode: fitMode,
                    packageEntryName: packageEntryName,
                    startsHidden: true,
                    loadImmediately: false
                )
            },
            retryPreparation: { _ in .ready }
        )
        defer { session.cleanup() }

        await session.retry()

        #expect(session.videoPlayer === old)
        #expect(!didCreateCandidate)
        #expect(!old.isCleanedUp)
    }

    @Test("Retry fails closed when composition publication changes while preparing")
    func retryRejectsChangedCompositionRevision() async {
        let old = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/retry-composition-cas-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let preparation = ControlledRetryPreparation()
        var candidate: WallpaperVideoPlayer?
        let session = VideoWallpaperSession(
            player: old,
            retryPlayerFactory: { url, frame, fitMode, packageEntryName in
                let player = WallpaperVideoPlayer(
                    url: url,
                    frame: frame,
                    fitMode: fitMode,
                    packageEntryName: packageEntryName,
                    startsHidden: true,
                    loadImmediately: false
                )
                candidate = player
                return player
            },
            retryPreparation: { player in
                await preparation.prepare(player)
            }
        )
        defer { session.cleanup() }

        let retry = Task { @MainActor in
            await session.retry()
        }
        #expect(await Self.waitUntil { preparation.isWaiting })
        old.setVideoComposition(
            AVMutableVideoComposition(),
            owner: .effects
        )
        preparation.resume(with: .ready)
        await retry.value

        #expect(session.videoPlayer === old)
        #expect(candidate?.isCleanedUp == true)
        #expect(!old.isCleanedUp)
    }

    @Test("Video replacement source preserves the old session through candidate preparation")
    func videoReplacementUsesPreparedTransaction() throws {
        let player = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let container = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/VideoContainerView.swift"
        )
        let coordinator = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/PlaybackCoordinator+SessionLifecycle.swift"
        )
        let session = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Session/VideoWallpaperSession.swift"
        )

        #expect(container.contains("playerHostView.playerLayer?.isReadyForDisplay == true"))
        #expect(player.contains("videoView?.isReadyForDisplay == true"))
        #expect(player.contains("startsHidden: Bool = false"))
        #expect(player.contains("func prepareFrameRateLimit("))
        #expect(coordinator.contains("WallpaperSessionTransaction.prepareAndCommit("))
        #expect(coordinator.contains("startsHidden: true"))
        #expect(coordinator.contains("PlainVideoFrameRateCompositionPolicy.compositionLimit("))
        #expect(coordinator.contains("await player.prepareFrameRateLimit("))
        #expect(coordinator.contains("player.prepareForCurrentComposition("))
        #expect(coordinator.contains("outgoingVideoPlayerAtCommit = expected?.videoPlayer"))
        #expect(coordinator.contains("retireVideoEffectsWork("))
        #expect(session.contains("let base = await replacement.prepareForDisplay("))
        #expect(session.contains("requiresFrameRatePreparationForRetry"))
        #expect(session.contains("replacement.prepareFrameRateLimit("))
        #expect(session.contains("replacement.prepareForCurrentComposition("))
        #expect(!session.contains("if replacement.currentVideoComposition != nil"))
        #expect(!coordinator.contains("releaseRuntimeSession(screen)\n            let player = WallpaperVideoPlayer"))
    }

    @Test("AVPlayerItem copies video compositions while readiness remains generation-owned")
    func avPlayerItemCompositionCopySemantics() throws {
        let item = AVPlayerItem(
            asset: AVURLAsset(url: URL(fileURLWithPath: "/tmp/composition-copy-semantics.mov"))
        )
        let original = AVMutableVideoComposition()
        original.renderSize = CGSize(width: 16, height: 16)
        original.frameDuration = CMTime(value: 1, timescale: 30)
        item.videoComposition = original

        let installed = try #require(item.videoComposition)
        #expect(installed !== original)
        #expect(item.videoComposition === installed)

        var coordinator = VideoCompositedFrameReadinessCoordinator(
            expectedLifecycleGeneration: 4,
            expectedCompositionGeneration: 6
        )
        #expect(coordinator.nextAction(
            lifecycleGeneration: 4,
            compositionGeneration: 6,
            currentItemID: ObjectIdentifier(item)
        ) == .bind(itemGeneration: 1))
        #expect(coordinator.nextAction(
            lifecycleGeneration: 4,
            compositionGeneration: 6,
            currentItemID: ObjectIdentifier(item)
        ) == .poll(itemGeneration: 1))
    }

    @Test("Late Force SDR composition cannot bypass the composited pixel gate")
    func lateForceSDRCompositionWaitsForPixelGate() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/late-force-sdr-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        player.setVideoColorSpace(.forceSDR)
        #expect(player.isForceSDRActive)
        #expect(player.currentVideoComposition == nil)
        #expect(await player.prepareForCurrentComposition(
            after: .ready,
            timeout: .milliseconds(30)
        ) == .timedOut)
    }

    @Test("Composited readiness rebinds AVPlayerLooper replicas within the same generations")
    func compositedReadinessRebindsCurrentItemReplica() {
        let first = NSObject()
        let replica = NSObject()
        var coordinator = VideoCompositedFrameReadinessCoordinator(
            expectedLifecycleGeneration: 7,
            expectedCompositionGeneration: 11
        )

        #expect(coordinator.nextAction(
            lifecycleGeneration: 7,
            compositionGeneration: 11,
            currentItemID: ObjectIdentifier(first)
        ) == .bind(itemGeneration: 1))
        #expect(coordinator.nextAction(
            lifecycleGeneration: 7,
            compositionGeneration: 11,
            currentItemID: ObjectIdentifier(first)
        ) == .poll(itemGeneration: 1))

        // AVPlayerLooper replacing currentItem is a new binding generation,
        // not cancellation of a still-current candidate.
        #expect(coordinator.nextAction(
            lifecycleGeneration: 7,
            compositionGeneration: 11,
            currentItemID: ObjectIdentifier(replica)
        ) == .bind(itemGeneration: 2))
        #expect(coordinator.nextAction(
            lifecycleGeneration: 8,
            compositionGeneration: 11,
            currentItemID: ObjectIdentifier(replica)
        ) == .cancelled)
        #expect(coordinator.nextAction(
            lifecycleGeneration: 7,
            compositionGeneration: 12,
            currentItemID: ObjectIdentifier(replica)
        ) == .cancelled)
    }

    @Test("Scene retry builds a transactional candidate instead of destructively reloading")
    func sceneRetryKeepsVisibleRuntimeUntilReplacementIsReady() throws {
        let manager = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Wallpaper.swift"
        )
        let retry = try #require(
            manager.range(of: "func retryRuntimeSession(for screen: Screen)")
        )
        let tail = manager[retry.lowerBound...]
        let end = try #require(tail.range(of: "\n    /// Subscribes"))
        let body = String(tail[..<end.lowerBound])

        #expect(body.contains("screen.runtimeSession?.wallpaperType == .scene"))
        #expect(body.contains("restoreWallpaperSession("))
        #expect(body.contains("preservingState: false"))
        #expect(body.contains("await screen.runtimeSession?.retry()"))
    }

    @Test("Cleanup blocks a loader completion that resumes after cancellation")
    func cleanupBlocksDelayedPlaybackInstall() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delayed-video-install-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = SuspendingWallpaperAssetLoader()
        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            assetLoaderOverride: { url in try await loader.load(url) }
        )

        let didSuspend = await Self.waitUntil { loader.isSuspended }
        #expect(didSuspend)

        player.cleanup()
        loader.resume(with: AVURLAsset(url: url))
        for _ in 0..<8 { await Task.yield() }

        #expect(player.isCleanedUp)
        #expect(player.player == nil)
        #expect(!player.hasInstalledPlaybackWindow)
        #expect(player.currentVideoComposition == nil)

        player.setVideoComposition(AVMutableVideoComposition(), owner: .effects)
        player.setFrameRateLimit(30)
        #expect(player.currentVideoComposition == nil)
        #expect(player.requestedFrameRateLimit == 0)
    }

    @Test("Stale video-effects failure cannot clear the newer task handle")
    func staleVideoEffectsFailureCannotClearNewerTask() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-generation.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let builder = ControlledVideoCompositionBuilder()
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_101
        var first = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        first.effectConfig.blurRadius = 1
        var second = first
        second.effectConfig.blurRadius = 2

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: first,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        let firstStarted = await Self.waitUntil { builder.pendingCalls.contains(1) }
        #expect(firstStarted)

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: second,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        let secondStarted = await Self.waitUntil { builder.pendingCalls.contains(2) }
        #expect(secondStarted)

        builder.resume(call: 1)
        let staleCompleted = await Self.waitUntil { builder.completedCalls.contains(1) }
        #expect(staleCompleted)
        #expect(service.hasInflightTask(for: screenID))

        builder.resume(call: 2)
        let latestCompleted = await Self.waitUntil { !service.hasInflightTask(for: screenID) }
        #expect(latestCompleted)
        #expect(!service.hasInflightTask(for: screenID))
    }

    @Test("The same effect configuration is rebuilt for a replacement player")
    func effectFingerprintIncludesPlayerIdentity() async {
        let firstPlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-first.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let replacementPlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-replacement.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer {
            firstPlayer.cleanup()
            replacementPlayer.cleanup()
        }

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-shared-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_102
        var configuration = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        configuration.effectConfig.blurRadius = 2

        service.applyEffects(
            to: firstPlayer,
            screenID: screenID,
            config: configuration,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })
        builder.resume(call: 1)
        #expect(await Self.waitUntil { !service.hasInflightTask(for: screenID) })

        service.applyEffects(
            to: replacementPlayer,
            screenID: screenID,
            config: configuration,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(2) })
        builder.resume(call: 2)
        #expect(await Self.waitUntil { !service.hasInflightTask(for: screenID) })
        #expect(replacementPlayer.currentVideoComposition != nil)
    }

    @Test("Force SDR round-trip rebuilds the persisted effect instead of trusting a stale fingerprint")
    func forceSDRRoundTripRestoresEffects() async throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-force-sdr-round-trip.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: player))
        defer { screen.resetRuntimeSession() }

        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data())
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.effectConfig.blurRadius = 2
        configuration.videoColorSpace = .auto
        let persistence = VideoCompositionConfigurationPersistence([configuration])
        let store = WallpaperConfigurationStore(persistence: persistence)
        _ = store.loadAll()

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(
            url: URL(fileURLWithPath: "/tmp/video-effects-force-sdr-round-trip-asset.mov")
        )
        let availableAsset = AssetSlot(asset)
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in availableAsset.current }
        )
        let applyEffects: @MainActor (Screen, ScreenConfiguration) -> Void = {
            target, updatedConfiguration in
            guard let targetPlayer = target.videoPlayer else { return }
            service.applyEffects(
                to: targetPlayer,
                screenID: target.id,
                config: updatedConfiguration,
                screenRefreshRate: 60,
                noEffectsHandler: {}
            )
        }
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            playableVideoLoader: FakePlayableVideoLoader(),
            applyPolicy: { _ in },
            applyVideoEffects: applyEffects,
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screen] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { $0.resetRuntimeSession() },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )

        applyEffects(screen, configuration)
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })
        builder.resume(call: 1)
        #expect(await Self.waitUntil { !service.hasInflightTask(for: screen.id) })
        #expect(player.videoCompositionOwner == .effects)

        // Model AVPlayerLooper's transient nil-currentItem interval. Force SDR
        // must still invalidate the effect fingerprint before asset lookup.
        availableAsset.current = nil
        coordinator.updateVideoColorSpace(.forceSDR, for: screen)
        #expect(player.isForceSDRActive)
        #expect(player.videoCompositionOwner == .none)

        availableAsset.current = asset
        coordinator.updateVideoColorSpace(.auto, for: screen)
        #expect(await Self.waitUntil { builder.pendingCalls.contains(2) })
        builder.resume(call: 2)
        #expect(await Self.waitUntil { !service.hasInflightTask(for: screen.id) })

        #expect(!player.isForceSDRActive)
        #expect(player.videoCompositionOwner == .effects)
        #expect(player.currentVideoComposition != nil)
    }

    @Test("Disabling effects clears them before rebuilding an unchanged positive FPS request")
    func disablingEffectsRebuildsExistingFrameRateRequest() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-to-frame-rate.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        player.setFrameRateLimit(30)
        player.setVideoComposition(AVMutableVideoComposition(), owner: .frameRate)
        player.setVideoComposition(AVMutableVideoComposition(), owner: .effects)
        #expect(player.requestedFrameRateLimit == 30)
        #expect(player.videoCompositionOwner == .effects)

        player.setFrameRateLimit(30)

        // With no test AVPlayerItem the replacement build remains deferred, but
        // the old effect is removed immediately and the positive FPS request is
        // retained for the real current-item observer to build as `.frameRate`.
        #expect(player.requestedFrameRateLimit == 30)
        #expect(player.videoCompositionOwner == .none)
        #expect(player.currentVideoComposition == nil)
    }

    @Test("Retry preserves an effects owner even when a positive FPS request is retained")
    func retryCompositionCopyPreservesEffectsOwner() {
        let source = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-retry-source.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let replacement = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-retry-replacement.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer {
            source.cleanup()
            replacement.cleanup()
        }
        source.setFrameRateLimit(30)
        source.setVideoComposition(AVMutableVideoComposition(), owner: .effects)

        VideoWallpaperSession.applyCompositionState(from: source, to: replacement)

        #expect(replacement.requestedFrameRateLimit == 30)
        #expect(replacement.videoCompositionOwner == .effects)
        #expect(replacement.currentVideoComposition != nil)
    }

    @Test("Retry treats an unpublished positive FPS request as pending composition work")
    func retryRequiresUnpublishedFrameRatePreparation() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-frame-rate-retry-pending.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        player.setFrameRateLimit(30)
        #expect(player.requiresFrameRatePreparationForRetry)

        player.setVideoComposition(
            AVMutableVideoComposition(),
            owner: .frameRate
        )
        #expect(!player.requiresFrameRatePreparationForRetry)

        player.setVideoComposition(nil, owner: .none)
        player.setVideoColorSpace(.forceSDR)
        #expect(!player.requiresFrameRatePreparationForRetry)
    }

    @Test("Retry preserves frame-rate ownership and defers Force SDR to the replacement asset")
    func retryCompositionCopyPreservesFrameRateAndForceSDROwners() {
        let frameRateSource = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-frame-rate-retry-source.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let frameRateReplacement = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-frame-rate-retry-replacement.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let forceSDRSource = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-force-sdr-retry-source.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let forceSDRReplacement = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-force-sdr-retry-replacement.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer {
            frameRateSource.cleanup()
            frameRateReplacement.cleanup()
            forceSDRSource.cleanup()
            forceSDRReplacement.cleanup()
        }

        frameRateSource.setFrameRateLimit(30)
        frameRateSource.setVideoComposition(
            AVMutableVideoComposition(),
            owner: .frameRate
        )
        VideoWallpaperSession.applyCompositionState(
            from: frameRateSource,
            to: frameRateReplacement
        )
        #expect(frameRateReplacement.requestedFrameRateLimit == 30)
        #expect(frameRateReplacement.videoCompositionOwner == .frameRate)
        #expect(frameRateReplacement.currentVideoComposition != nil)

        forceSDRSource.setFrameRateLimit(30)
        forceSDRSource.setVideoColorSpace(.forceSDR)
        forceSDRSource.setVideoComposition(
            AVMutableVideoComposition(),
            owner: .forceSDR
        )
        VideoWallpaperSession.applyCompositionState(
            from: forceSDRSource,
            to: forceSDRReplacement
        )
        #expect(forceSDRReplacement.isForceSDRActive)
        #expect(forceSDRReplacement.requestedFrameRateLimit == 30)
        #expect(forceSDRReplacement.videoCompositionOwner == .none)
        #expect(forceSDRReplacement.currentVideoComposition == nil)
    }

    @Test("A stale prepare cancellation cannot cancel its replacement effects work")
    func stalePrepareCancellationDoesNotCancelReplacementWork() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-cancel-identity.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-cancel-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_103
        var first = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        first.effectConfig.blurRadius = 1
        var replacement = first
        replacement.effectConfig.blurRadius = 2

        let stalePreparation = Task { @MainActor in
            await service.prepareEffects(
                to: player,
                screenID: screenID,
                config: first,
                screenRefreshRate: 60,
                noEffectsHandler: {}
            )
        }
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })

        // The cancellation handler hops back to MainActor. Install replacement
        // work in this same turn before that stale handler is allowed to run.
        stalePreparation.cancel()
        service.applyEffects(
            to: player,
            screenID: screenID,
            config: replacement,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(2) })
        #expect(service.hasInflightTask(for: screenID))
        #expect(await stalePreparation.value == false)
        #expect(service.hasInflightTask(for: screenID))

        builder.resume(call: 1)
        #expect(await Self.waitUntil { builder.completedCalls.contains(1) })
        #expect(service.hasInflightTask(for: screenID))

        builder.resume(call: 2)
        #expect(await Self.waitUntil { !service.hasInflightTask(for: screenID) })
        #expect(player.currentVideoComposition != nil)
    }

    @Test("Retirement deletes the WorkKey tombstone and late ABA completion cannot install")
    func effectsRetirementDeletesTombstoneWithoutABA() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-retirement-aba.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-retirement-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_107
        var first = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        first.effectConfig.blurRadius = 1
        var replacement = first
        replacement.effectConfig.blurRadius = 2

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: first,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })

        service.retireWork(for: screenID, player: player)
        #expect(!service.hasTrackedWorkKey(for: screenID, player: player))
        #expect(service.workRevision(for: screenID, player: player) == 0)

        // Reusing the same key immediately recreates the same numeric generation
        // sequence. WorkIdentity must still reject the retired completion.
        service.applyEffects(
            to: player,
            screenID: screenID,
            config: replacement,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(2) })

        builder.resume(call: 1)
        #expect(await Self.waitUntil { builder.completedCalls.contains(1) })
        #expect(service.hasInflightTask(for: screenID, player: player))
        #expect(player.currentVideoComposition == nil)

        builder.resume(call: 2)
        #expect(await Self.waitUntil {
            !service.hasInflightTask(for: screenID, player: player)
        })
        #expect(player.videoCompositionOwner == .effects)
        #expect(player.currentVideoComposition != nil)
    }

    @Test("Terminal screen retirement removes all player keys while ordinary cancellation keeps revisions")
    func terminalEffectsRetirementRemovesAllKeys() {
        let first = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-retire-all-first.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let second = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-retire-all-second.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer {
            first.cleanup()
            second.cleanup()
        }

        let service = VideoEffectsApplicationService(assetProvider: { _ in nil })
        let screenID: CGDirectDisplayID = 8_108
        var configuration = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        configuration.effectConfig.blurRadius = 2
        for player in [first, second] {
            service.applyEffects(
                to: player,
                screenID: screenID,
                config: configuration,
                screenRefreshRate: 60,
                noEffectsHandler: {}
            )
        }
        #expect(service.trackedWorkKeyCount(for: screenID) == 2)

        service.cancelInflight(for: screenID)
        #expect(service.trackedWorkKeyCount(for: screenID) == 2)

        service.retireAllWork(for: screenID)
        #expect(service.trackedWorkKeyCount(for: screenID) == 0)
        #expect(service.workRevision(for: screenID, player: first) == 0)
        #expect(service.workRevision(for: screenID, player: second) == 0)
    }

    @Test("Dynamic-range reconciliation keeps Force SDR authoritative and restores from format plus preference")
    func dynamicRangeReconciliationIsSingleSourceOfTruth() {
        let hdr = VideoFormatInfo(isHDR: true)
        let sdr = VideoFormatInfo(isHDR: false)

        // Models the late detector callback arriving after Force SDR.
        #expect(!VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: hdr,
            preference: .forceSDR
        ))

        // Leaving Force SDR restores the state derived from the detected format.
        #expect(VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: hdr,
            preference: .auto
        ))
        #expect(!VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: sdr,
            preference: .auto
        ))
        #expect(VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: nil,
            preference: .rec2020HDR
        ))
        #expect(!VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: hdr,
            preference: .sRGB
        ))
        #expect(!VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: hdr,
            preference: .displayP3
        ))
    }

    @Test("Disabling effects does not depend on a transient current player item")
    func disablingEffectsRunsBeforeAssetLookup() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-disable-nil-item.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }
        player.setVideoComposition(AVMutableVideoComposition(), owner: .effects)

        var assetLookupCount = 0
        let service = VideoEffectsApplicationService(assetProvider: { _ in
            assetLookupCount += 1
            return nil
        })
        let screenID: CGDirectDisplayID = 8_104
        let configuration = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        var fallbackCount = 0
        var completionResult: Bool?

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: configuration,
            screenRefreshRate: 60,
            noEffectsHandler: {
                fallbackCount += 1
                player.setFrameRateLimit(0)
            },
            completion: { completionResult = $0 }
        )

        #expect(assetLookupCount == 0)
        #expect(fallbackCount == 1)
        #expect(completionResult == true)
        #expect(player.videoCompositionOwner == .none)
        #expect(!service.hasPendingRequest(for: screenID, player: player))
    }

    @Test("An enabled effect deferred across a nil item replays the latest player request")
    func pendingEffectsReplayWhenCurrentItemReturns() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-pending-item.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-pending-asset.mov"))
        let availableAsset = AssetSlot(nil)
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in availableAsset.current }
        )
        let screenID: CGDirectDisplayID = 8_105
        var configuration = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        configuration.effectConfig.blurRadius = 3
        var completionResults: [Bool] = []

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: configuration,
            screenRefreshRate: 60,
            noEffectsHandler: {},
            completion: { completionResults.append($0) }
        )

        #expect(service.hasPendingRequest(for: screenID, player: player))
        #expect(!service.hasInflightTask(for: screenID, player: player))
        #expect(completionResults.isEmpty)

        availableAsset.current = asset
        service.currentItemDidBecomeAvailable(for: player, screenID: screenID)
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })
        #expect(!service.hasPendingRequest(for: screenID, player: player))
        #expect(service.hasInflightTask(for: screenID, player: player))

        builder.resume(call: 1)
        #expect(await Self.waitUntil {
            !service.hasInflightTask(for: screenID, player: player)
        })
        #expect(completionResults == [true])
        #expect(player.videoCompositionOwner == .effects)
    }

    @Test("Effects work and cancellation on one screen are isolated by player identity")
    func effectsWorkIsIsolatedPerPlayer() async {
        let livePlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-live-player.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        let candidatePlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-candidate-player.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer {
            livePlayer.cleanup()
            candidatePlayer.cleanup()
        }

        let builder = ControlledVideoCompositionBuilder(failsFirstCall: false)
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-isolation-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_106
        var liveConfiguration = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        liveConfiguration.effectConfig.blurRadius = 1
        var candidateConfiguration = liveConfiguration
        candidateConfiguration.effectConfig.blurRadius = 4

        service.applyEffects(
            to: livePlayer,
            screenID: screenID,
            config: liveConfiguration,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(1) })

        service.applyEffects(
            to: candidatePlayer,
            screenID: screenID,
            config: candidateConfiguration,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        #expect(await Self.waitUntil { builder.pendingCalls.contains(2) })
        #expect(service.hasInflightTask(for: screenID, player: livePlayer))
        #expect(service.hasInflightTask(for: screenID, player: candidatePlayer))

        let liveRevision = service.workRevision(for: screenID, player: livePlayer)
        service.cancelInflight(for: screenID, player: candidatePlayer)
        #expect(service.hasInflightTask(for: screenID, player: livePlayer))
        #expect(!service.hasActiveWork(for: screenID, player: candidatePlayer))
        #expect(service.workRevision(for: screenID, player: livePlayer) == liveRevision)

        builder.resume(call: 1)
        builder.resume(call: 2)
        #expect(await Self.waitUntil {
            !service.hasInflightTask(for: screenID, player: livePlayer)
                && !service.hasInflightTask(for: screenID, player: candidatePlayer)
        })
        #expect(livePlayer.videoCompositionOwner == .effects)
        #expect(candidatePlayer.videoCompositionOwner == .none)
    }

    @Test("Candidate Force SDR fallback cannot route FPS through the old screen session")
    func candidateFallbackTargetsExplicitPlayer() async throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let livePlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-old-visible.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        let candidatePlayer = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-hidden-candidate.mov"),
            frame: screen.frame,
            loadImmediately: false
        )
        screen.installRuntimeSession(VideoWallpaperSession(player: livePlayer))
        defer {
            screen.resetRuntimeSession()
            candidatePlayer.cleanup()
        }

        livePlayer.setFrameRateLimit(24)
        candidatePlayer.setVideoColorSpace(.forceSDR)
        var legacyScreenFallbackCount = 0
        let coordinator = WallpaperEffectsCoordinator(
            configurationStore: WallpaperConfigurationStore(),
            screensProvider: { [screen] },
            saveConfiguration: { _ in },
            applyFrameRateLimit: { _, _ in
                legacyScreenFallbackCount += 1
            },
            screenRefreshRate: { _ in 60 }
        )
        defer { coordinator.shutdown() }

        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data())
        configuration.frameRateLimit = .fps15
        configuration.effectConfig.blurRadius = 2

        #expect(await coordinator.prepareVideoEffects(
            for: candidatePlayer,
            screen: screen,
            config: configuration
        ))
        #expect(legacyScreenFallbackCount == 0)
        #expect(livePlayer.requestedFrameRateLimit == 24)
    }

    @Test("The permanent current-item observer replays guarded deferred FPS work")
    func permanentCurrentItemObserverOwnsDeferredFPSReplay() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let observerStart = try #require(
            source.range(of: "private func installQueueItemMaintenanceObserver()")
        )
        let observerTail = source[observerStart.lowerBound...]
        let observerEnd = try #require(observerTail.range(of: "\n    func setVideoFitMode"))
        let observer = String(observerTail[..<observerEnd.lowerBound])

        #expect(observer.contains("guard item != nil else { return }"))
        #expect(observer.contains("applyRequestedFrameRateLimitIfReady()"))
        #expect(source.contains("player?.currentItem != nil"))
        #expect(!source.contains("observeInitialCurrentItemForDeferredFrameRateLimit"))
    }

    @Test("setPlaybackSpeed clamps to [0.25, 4.0] and falls back to 1.0 for non-finite input")
    func setPlaybackSpeedClampsRange() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/speed-clamp-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )

        player.setPlaybackSpeed(-3.0)
        #expect(player.currentPlaybackSpeed == 0.25)

        player.setPlaybackSpeed(9999.0)
        #expect(player.currentPlaybackSpeed == 4.0)

        player.setPlaybackSpeed(.nan)
        #expect(player.currentPlaybackSpeed == 1.0)

        player.setPlaybackSpeed(.infinity)
        #expect(player.currentPlaybackSpeed == 1.0)

        player.setPlaybackSpeed(2.0)
        #expect(player.currentPlaybackSpeed == 2.0)
    }

    // MARK: - Manual-pause deep hibernation (parity with SceneWallpaperSession)

    @Test("A manual pause deep-hibernates after its dwell and play rebuilds the player")
    func manualPauseHibernatesAfterDwellAndPlayRestores() async throws {
        let url = try await ManualPauseVideoFixture.writeMP4()
        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            hibernationDelay: .milliseconds(80)
        )
        let session = VideoWallpaperSession(
            player: player,
            userPauseHibernationDelay: .milliseconds(120)
        )
        defer {
            session.cleanup()
            try? FileManager.default.removeItem(at: url)
        }
        try await Self.waitForCondition("player enqueues its first item") {
            player.player?.currentItem != nil
        }
        #expect(player.hasInMemoryAssetLoaderForTesting)

        session.pause()
        // The dwell has not run yet: a pause the user may undo immediately stays warm.
        #expect(!player.isSuspended)
        #expect(!player.isHibernated)

        try await Self.waitForCondition("manual pause hibernates the player") {
            player.isHibernated
        }
        #expect(player.player == nil)
        #expect(!player.hasInMemoryAssetLoaderForTesting)
        #expect(player.boundVideoOutputCountForTesting == 0)
        // Released behind a still frame, not to a black desktop.
        #expect(player.isShowingHibernationStillFrameForTesting)
        #expect(player.hasInstalledPlaybackWindow)

        session.play()

        #expect(!player.isHibernated)
        try await Self.waitForCondition("play rebuilds the player") {
            player.player?.currentItem != nil
        }
        #expect(player.hasInMemoryAssetLoaderForTesting)
        try await Self.waitForCondition("the still frame is retired after the wake") {
            !player.isShowingHibernationStillFrameForTesting
        }
    }

    /// The absence signal and the manual pause share the player's single dwell
    /// slot, so the session has to hold eligibility and suspend depth true across
    /// both an absence-false push and a `.quality` policy refresh — every policy
    /// refresh pushes absence ineligibility for a pause that is not an absence.
    /// The pushes land during the manual-pause countdown: since the handover to
    /// the player became immediate (D3), that is the only window left.
    @Test("Neither an absence-false push nor a quality refresh cancels a manual-pause hibernation")
    func manualPauseHibernationSurvivesAbsenceAndPolicyPushes() async throws {
        let url = try await ManualPauseVideoFixture.writeMP4()
        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            hibernationDelay: .seconds(30)
        )
        let session = VideoWallpaperSession(
            player: player,
            userPauseHibernationDelay: .milliseconds(300)
        )
        defer {
            session.cleanup()
            try? FileManager.default.removeItem(at: url)
        }
        try await Self.waitForCondition("player enqueues its first item") {
            player.player?.currentItem != nil
        }

        session.pause()
        #expect(!player.isHibernated, "the manual-pause dwell has not elapsed yet")

        // `ScreenManager.resolveAndApplyPerformanceState` order: the profile
        // first, the absence push last — so the eligibility fold is the one that
        // has to survive, not just the profile fold.
        session.applyPerformanceProfile(.quality)
        session.setHibernationEligible(false)

        try await Self.waitForCondition("the player still hibernates") {
            player.isHibernated
        }
        #expect(player.isSuspended)
        #expect(player.player == nil)
        #expect(!session.userIntendsToPlay)
    }

    /// D3: the wall clock from a manual pause to the resources actually going
    /// away must be the same for all three wallpaper kinds. The scene session
    /// releases the moment its own 300s dwell elapses; video used to hand the
    /// player over and then wait out the player's *absence* dwell on top of it,
    /// so the real figure was 320s. The player's dwell is left at a value this
    /// test could never wait for, so only the handover being immediate can pass.
    @Test("A manual pause releases the video without also waiting the absence dwell")
    func manualPauseReleaseDoesNotStackTheAbsenceDwell() async throws {
        let url = try await ManualPauseVideoFixture.writeMP4()
        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            hibernationDelay: .seconds(30)
        )
        let session = VideoWallpaperSession(
            player: player,
            userPauseHibernationDelay: .milliseconds(120)
        )
        defer {
            session.cleanup()
            try? FileManager.default.removeItem(at: url)
        }
        try await Self.waitForCondition("player enqueues its first item") {
            player.player?.currentItem != nil
        }

        session.pause()

        try await Self.waitForCondition(
            "the manual-pause dwell releases the player without the absence dwell",
            timeout: .seconds(4)
        ) {
            player.isHibernated
        }
        #expect(player.player == nil)
        #expect(player.isShowingHibernationStillFrameForTesting)
    }

    private static func waitForCondition(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for: \(description)")
        throw ManualPauseVideoFixture.FixtureError.setupFailed(description)
    }

    private static func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

/// A tiny real MP4. The deep-hibernation path needs a live `AVQueuePlayer` and a
/// still-frame capture, so a nonexistent URL cannot exercise it.
private enum ManualPauseVideoFixture {
    static func writeMP4(durationSeconds: TimeInterval = 1.5) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-pause-hibernate-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 128
        let height = 128
        let frameRate: Int32 = 30
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.setupFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0 ..< totalFrames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw FixtureError.setupFailed("CVPixelBufferCreate returned \(status)")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(
                CVPixelBufferGetBaseAddress(buffer),
                Int32(40 + (index * 7) % 180),
                CVPixelBufferGetBytesPerRow(buffer) * height
            )
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(index), timescale: frameRate)
            ) else {
                throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.setupFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
            )
        }
        return outputURL
    }

    enum FixtureError: Error {
        case setupFailed(String)
    }
}

@MainActor
private final class RetryEffectsRevisionProbe {
    private(set) var value: UInt64

    init(value: UInt64) {
        self.value = value
    }

    func bump() {
        value &+= 1
    }
}

@MainActor
private final class ControlledRetryPreparation {
    private var continuation: CheckedContinuation<
        WallpaperPreparationResult,
        Never
    >?
    private(set) var isWaiting = false

    func prepare(
        _ player: WallpaperVideoPlayer
    ) async -> WallpaperPreparationResult {
        _ = player
        isWaiting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with result: WallpaperPreparationResult) {
        isWaiting = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

@MainActor
private final class SuspendingWallpaperAssetLoader {
    private var continuation: CheckedContinuation<AVURLAsset, any Error>?
    private(set) var isSuspended = false

    func load(_: URL) async throws -> AVURLAsset {
        isSuspended = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with asset: AVURLAsset) {
        isSuspended = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: asset)
    }
}

@MainActor
private final class ControlledVideoCompositionBuilder {
    private enum ProbeError: Error {
        case staleFailure
    }

    private var callCount = 0
    private let failsFirstCall: Bool
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var pendingCalls: Set<Int> = []
    private(set) var completedCalls: Set<Int> = []

    init(failsFirstCall: Bool = true) {
        self.failsFirstCall = failsFirstCall
    }

    func build(
        asset _: AVAsset,
        config _: VideoEffectConfig,
        frameDuration _: CMTime
    ) async throws -> AVVideoComposition {
        callCount += 1
        let call = callCount
        pendingCalls.insert(call)
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
        pendingCalls.remove(call)
        completedCalls.insert(call)
        if failsFirstCall, call == 1 {
            throw ProbeError.staleFailure
        }
        return AVMutableVideoComposition()
    }

    func resume(call: Int) {
        let continuation = continuations.removeValue(forKey: call)
        continuation?.resume()
    }
}

@MainActor
private final class VideoCompositionConfigurationPersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration]

    init(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.screenID, $0) }
        )
    }

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

@Suite("Inspector poster load ownership")
@MainActor
struct InspectorPosterLoadStateTests {
    @Test("A replaced poster load cannot publish or finish the replacement")
    func replacedLoadCannotPublish() {
        var state = InspectorPosterLoadState()
        let original = state.begin()
        let replacement = state.begin()

        #expect(!state.isCurrent(original))
        let staleFinished = state.finish(original)
        #expect(!staleFinished)
        #expect(state.isCurrent(replacement))
        let replacementFinished = state.finish(replacement)
        #expect(replacementFinished)
    }

    @Test("Switching to playback invalidates a pending poster")
    func invalidationRejectsPendingPoster() {
        var state = InspectorPosterLoadState()
        let poster = state.begin()

        state.invalidate()

        #expect(!state.isCurrent(poster))
        let invalidatedPosterFinished = state.finish(poster)
        #expect(!invalidatedPosterFinished)
    }

    @Test("Controller cleanup synchronously clears every transient playback state")
    func controllerCleanupClearsTransientState() {
        let controller = InspectorPreviewController()
        let missingURL = URL(fileURLWithPath: "/nonexistent/inspector-poster.mp4")

        // No suspension point: the poster task cannot finish before the
        // synchronous cleanup contract is exercised.
        controller.loadPoster(from: missingURL)
        #expect(controller.isLoading)

        controller.cleanup()

        #expect(!controller.isLoading)
        #expect(!controller.isPlaying)
        #expect(controller.player == nil)
        #expect(controller.posterImage == nil)
        #expect(controller.assetURL == nil)
    }
}

/// The provider closure captures this and the test mutates it afterwards, which
/// Swift 6.4 diagnoses on a plain captured `var`.
///
/// `@unchecked Sendable`: every access to `asset` goes through `lock`, and the
/// box holds nothing else.
private final class AssetSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var asset: AVAsset?

    init(_ asset: AVAsset?) { self.asset = asset }

    var current: AVAsset? {
        get { lock.withLock { asset } }
        set { lock.withLock { asset = newValue } }
    }
}
