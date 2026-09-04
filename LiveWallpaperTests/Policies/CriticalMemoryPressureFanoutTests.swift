import AppKit
@preconcurrency import AVFoundation
import Foundation
import LiveWallpaperCore
import os
import Testing
@testable import LiveWallpaper

/// W2: critical system memory pressure is a resource-depth signal every session
/// kind has to receive, not a scene-only one. Before this it was dispatched by
/// casting to `SceneWallpaperSession` at both dispatch points, so on a Lite
/// install — where that type is not even compiled — the deepest signal the
/// system emits reached nobody, and AVFoundation's player/looper/item/decode
/// pool stayed resident through the exact moment the machine had no memory.
@MainActor
@Suite("Critical memory pressure fan-out", .serialized)
struct CriticalMemoryPressureFanoutTests {

    // MARK: - Video session behaviour

    /// The player's own absence dwell is set to a value no test could wait out,
    /// so only the immediate handover can make this pass.
    @Test("Critical pressure deep-hibernates a suspended video, bypassing every dwell")
    func criticalPressureHibernatesSuspendedVideo() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }
        #expect(harness.player.hasInMemoryAssetLoaderForTesting)

        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setCriticalMemoryPressureActive(true)

        try await Harness.poll("critical pressure hibernates the video") {
            harness.player.isHibernated
        }
        #expect(harness.player.player == nil)
        #expect(!harness.player.hasInMemoryAssetLoaderForTesting)
        #expect(harness.player.boundVideoOutputCountForTesting == 0)
        // Released behind the path's own width-capped still, not to a black desktop.
        #expect(harness.player.isShowingHibernationStillFrameForTesting)
        // Resource depth only: the emergency must not rewrite user play intent.
        #expect(harness.session.userIntendsToPlay)
    }

    /// Control group for the test above: without the pressure signal the same
    /// suspended player stays warm, so the assertions there are pinned to the
    /// new signal rather than to the suspend that precedes it.
    @Test("A suspended video with no pressure signal stays warm")
    func suspendedVideoWithoutPressureStaysWarm() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)

        try await Task.sleep(for: .milliseconds(400))
        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
    }

    /// The signal only deepens an already-suspended session. `critical` is
    /// graded as a hard safety suspend by `WallpaperPolicyEngine`, so the
    /// profile always lands first; a session still at `.quality` when this
    /// arrives is one the profile has not reached yet, and tearing it down here
    /// would be this signal overriding the profile instead of layering on it.
    @Test("Critical pressure does not deepen a session the profile still has at quality")
    func criticalPressureDoesNotDeepenAQualityProfile() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.quality)
        harness.session.setCriticalMemoryPressureActive(true)

        try await Task.sleep(for: .milliseconds(400))
        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
        #expect(!harness.player.isSuspended)
    }

    @Test("Clearing the pressure and restoring quality rebuilds the video")
    func clearingPressureRestoresTheVideo() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setCriticalMemoryPressureActive(true)
        try await Harness.poll("critical pressure hibernates the video") {
            harness.player.isHibernated
        }

        // `ScreenManager.applyMemoryPressureLevel` order: the policy refresh
        // first, the fan-out after it.
        harness.session.applyPerformanceProfile(.quality)
        harness.session.setCriticalMemoryPressureActive(false)

        #expect(!harness.player.isHibernated)
        try await Harness.poll("the wake rebuilds the player") {
            harness.player.player?.currentItem != nil
        }
        #expect(harness.player.hasInMemoryAssetLoaderForTesting)
        try await Harness.poll("the still frame is retired after the wake") {
            !harness.player.isShowingHibernationStillFrameForTesting
        }
    }

    /// Fall-back race, dispatch-order half: the dwell is armed with a zero
    /// initial delay but still runs as a task, so a clear landing in the same
    /// MainActor turn must revoke it. Without the fold in
    /// `setCriticalMemoryPressureActive(false)` the armed attempt survives the
    /// clear and tears the player down for an emergency that is already over.
    @Test("A clear that lands before the teardown starts revokes it")
    func clearBeforeTeardownStartsRevokesIt() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setCriticalMemoryPressureActive(true)
        harness.session.setCriticalMemoryPressureActive(false)

        try await Task.sleep(for: .milliseconds(500))
        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
        #expect(harness.player.hasInMemoryAssetLoaderForTesting)
    }

    /// The player owns one eligibility flag shared by absence, manual pause and
    /// pressure. `ScreenManager` pushes absence ineligibility on every policy
    /// refresh, so a pressure teardown only survives if every push site OR-folds
    /// all three triggers. This is the fold's regression test.
    @Test("Routine absence and profile pushes never cancel a pressure teardown")
    func pressureTeardownSurvivesRoutinePushes() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setCriticalMemoryPressureActive(true)
        // The exact pair a refresh for an unrelated reason emits while the
        // emergency is still on.
        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setHibernationEligible(false)

        try await Harness.poll("the pressure teardown still lands") {
            harness.player.isHibernated
        }
        #expect(harness.player.player == nil)
        #expect(!harness.player.hasInMemoryAssetLoaderForTesting)
    }

    /// `retry()` swaps in a fresh player while the emergency is still on — the
    /// scenario the doc comment on `setCriticalMemoryPressureActive` calls out
    /// by name. Before the fix, `retry()` only pushed the routine dwelled
    /// eligibility, so the replacement rode out a full `hibernationDelay` in
    /// the middle of a critical-pressure emergency instead of going down
    /// immediately like the player it replaced.
    @Test("A player installed by retry() while critical pressure is active deep-hibernates immediately")
    func retryPlayerUnderCriticalPressureHibernatesImmediately() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setCriticalMemoryPressureActive(true)
        try await Harness.poll("critical pressure hibernates the original video") {
            harness.player.isHibernated
        }

        var replacement: WallpaperVideoPlayer?
        harness.session.onVideoPlayerReplacement = { _, newPlayer in
            replacement = newPlayer
        }

        await harness.session.retry()

        let installed = try #require(replacement)
        #expect(installed !== harness.player)
        // The replacement's own dwell is the default 20s — a poll this short
        // only passes if the immediate path fired, not the routine dwell.
        try await Harness.poll(
            "the replacement deep-hibernates immediately, bypassing its own dwell",
            timeout: .seconds(3)
        ) {
            installed.isHibernated
        }
        #expect(installed.player == nil)
    }

    /// Control group for the test above: with no pressure signal active,
    /// `retry()`'s player swap must keep behaving exactly as before this fix —
    /// the routine dwelled push, not an immediate teardown.
    @Test("A player installed by retry() with no pressure signal keeps the normal dwell")
    func retryPlayerWithoutPressureKeepsNormalDwell() async throws {
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        defer { harness.teardown() }

        harness.session.applyPerformanceProfile(.suspended)

        var replacement: WallpaperVideoPlayer?
        harness.session.onVideoPlayerReplacement = { _, newPlayer in
            replacement = newPlayer
        }

        await harness.session.retry()

        let installed = try #require(replacement)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!installed.isHibernated)
        #expect(installed.player != nil)
    }

    // MARK: - ScreenManager fan-out (both dispatch points)

    /// Dispatch point 1, `ScreenManager+MemoryPressure.applyMemoryPressureLevel`,
    /// driven end to end from a fake watcher through the real policy engine.
    @Test("The watcher's critical level reaches an installed video session")
    func watcherCriticalReachesInstalledVideoSession() async throws {
        let nsScreen = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: nsScreen)
        let watcher = FanoutFakePressureWatcher()
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            memoryPressureWatcher: watcher,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            harness.removeFixture()
        }
        let liveScreen = try #require(manager.screens.first(where: { $0.id == screen.id }))
        liveScreen.installRuntimeSession(harness.session)

        watcher.emit(.critical)

        try await Harness.poll("watcher-driven video hibernate") {
            harness.player.isHibernated
        }
        #expect(manager.isUnderMemoryPressure)
        #expect(harness.player.player == nil)
        #expect(!harness.player.hasInMemoryAssetLoaderForTesting)
    }

    /// Dispatch point 2, the reconcile inside
    /// `ScreenManager+Observers.resolveAndApplyPerformanceState`. The level
    /// change is fully applied before the session exists, so only the
    /// per-refresh reconcile can reach it — the restore-at-launch and swap-in
    /// case. Point 1 cannot pass this test.
    @Test("A video installed while pressure is already critical still hibernates")
    func videoInstalledUnderCriticalPressureHibernates() async throws {
        let nsScreen = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: nsScreen)
        let watcher = FanoutFakePressureWatcher()
        let harness = try await Harness.make(
            playerHibernationDelay: .seconds(30),
            userPauseHibernationDelay: .seconds(30)
        )
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            memoryPressureWatcher: watcher,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            harness.removeFixture()
        }

        watcher.emit(.critical)
        // The watcher hop is a MainActor Task — drain it so the level change is
        // fully applied BEFORE the session exists, or this degenerates into the
        // ordering the test above already covers.
        try await Harness.poll("pressure applied before install") {
            manager.isUnderMemoryPressure
        }
        let liveScreen = try #require(manager.screens.first(where: { $0.id == screen.id }))
        liveScreen.installRuntimeSession(harness.session)
        manager.refreshPerformancePolicyForAllScreens()

        try await Harness.poll("reconcile-driven video hibernate") {
            harness.player.isHibernated
        }
        #expect(harness.player.player == nil)
    }

    // MARK: - Source contracts

    /// Both dispatch points must select sessions by capability, not by concrete
    /// type, and must agree on who receives the signal. A cast narrowed back to
    /// one session kind at either point compiles clean and silently drops the
    /// feature for the others.
    @Test("Both dispatch points fan out over the capability protocol")
    func bothDispatchPointsUseTheCapabilityFanOut() throws {
        let pressure = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+MemoryPressure.swift"
        )
        #expect(pressure.contains("as? WallpaperCriticalMemoryPressureResponding"))
        #expect(!pressure.contains("as? SceneWallpaperSession"))

        let observers = try Self.resolveAndApplyPerformanceStateBody()
        #expect(observers.contains("as? WallpaperCriticalMemoryPressureResponding"))
        // The scene cast may still appear — it owns the Pro-only dwell wiring —
        // but it must no longer be the thing carrying the pressure signal.
        #expect(!observers.contains("scene.setCriticalMemoryPressureActive"))
    }

    /// Video and HTML ship in both SKUs. A `#if !LITE_BUILD` around the pressure
    /// fan-out compiles clean and drops it from Loomscreen entirely, which is
    /// exactly the bug this window closed.
    @Test("The pressure fan-out sits outside the Pro-only block")
    func fanOutIsNotGatedOnProOnlyBuilds() throws {
        let body = try Self.resolveAndApplyPerformanceStateBody()
        let gate = try #require(
            body.range(of: "#if !LITE_BUILD"),
            "the Pro-only block moved — re-point this contract"
        )
        let gated = body[gate.lowerBound...]
        let endif = try #require(gated.range(of: "#endif"))
        let insideGate = gated[..<endif.lowerBound]
        #expect(!insideGate.contains("WallpaperCriticalMemoryPressureResponding"))
        // Control: the scene's own dwell call genuinely is inside that block, so
        // the assertion above cannot pass on a file that simply lost the gate.
        #expect(insideGate.contains("as? SceneWallpaperSession"))
    }

    /// The video implementation deliberately owns no teardown of its own: it
    /// hands the player into the path the manual-pause dwell already uses, whose
    /// post-await revalidation (`lifecycleGeneration` plus a re-read of
    /// eligibility and suspension) is what makes a clear landing mid-teardown
    /// win. Pin those guards — the fall-back correctness of this window depends
    /// on them, and they live in a file this window does not own.
    @Test("The reused teardown keeps its post-await generation and eligibility guards")
    func reusedTeardownKeepsItsGenerationGuard() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Video/WallpaperVideoPlayer.swift"
        )
        let start = try #require(source.range(of: "private func hibernateNow() async -> Bool {"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    private func resumeFromHibernationIfNeeded()"))
        let body = String(rest[..<end.lowerBound])

        let afterCapture = try #require(body.range(of: "await captureStillFrame()"))
        let revalidation = body[afterCapture.upperBound...]
        #expect(revalidation.contains("lifecycleGeneration == generation"))
        #expect(revalidation.contains("isHibernationEligible"))
        #expect(revalidation.contains("isSuspended"))
    }

    #if !LITE_BUILD
    /// Scene behaviour is unchanged by construction — `SceneWallpaperSession.swift`
    /// is untouched and only gained a conformance declared elsewhere. This pins
    /// that it is still reached by the widened fan-out.
    @Test("The scene session still satisfies the capability the fan-out selects on")
    func sceneSessionStillReceivesTheSignal() {
        #expect(
            (SceneWallpaperSession.self as Any) is WallpaperCriticalMemoryPressureResponding.Type
        )
    }
    #endif

    private static func resolveAndApplyPerformanceStateBody() throws -> String {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Observers.swift"
        )
        let start = try #require(
            source.range(of: "private func resolveAndApplyPerformanceState"),
            "resolveAndApplyPerformanceState was renamed — re-point this contract"
        )
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    /// Layers the adaptive background") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let session: VideoWallpaperSession
        let player: WallpaperVideoPlayer
        let url: URL

        static func make(
            playerHibernationDelay: Duration,
            userPauseHibernationDelay: Duration
        ) async throws -> Harness {
            let url = try await PressureVideoFixture.writeMP4()
            let player = WallpaperVideoPlayer(
                url: url,
                frame: CGRect(x: 0, y: 0, width: 128, height: 128),
                hibernationDelay: playerHibernationDelay
            )
            let session = VideoWallpaperSession(
                player: player,
                userPauseHibernationDelay: userPauseHibernationDelay
            )
            let harness = Harness(session: session, player: player, url: url)
            do {
                try await poll("player enqueues its first item") {
                    player.player?.currentItem != nil
                }
            } catch {
                harness.teardown()
                throw error
            }
            return harness
        }

        func teardown() {
            session.cleanup()
            removeFixture()
        }

        func removeFixture() {
            try? FileManager.default.removeItem(at: url)
        }

        static func poll(
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
            throw PressureVideoFixture.FixtureError.setupFailed(description)
        }
    }
}

private final class FanoutFakePressureWatcher: MemoryPressureWatching {
    private struct State {
        var level = SystemMemoryPressureLevel.normal
        var handler: SystemMemoryPressureChangeHandler?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(onChange: SystemMemoryPressureChangeHandler?) {
        state.withLock { $0.handler = onChange }
    }

    func stop() {
        state.withLock { $0.handler = nil }
    }

    func currentLevel() -> SystemMemoryPressureLevel {
        state.withLock { $0.level }
    }

    func emit(_ level: SystemMemoryPressureLevel) {
        let handler = state.withLock { state -> SystemMemoryPressureChangeHandler? in
            state.level = level
            return state.handler
        }
        handler?(level)
    }
}

/// A tiny real MP4: the deep-hibernation path needs a live `AVQueuePlayer` and a
/// still-frame capture, so a nonexistent URL cannot exercise it.
private enum PressureVideoFixture {
    static func writeMP4(durationSeconds: TimeInterval = 1.5) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("critical-pressure-fanout-\(UUID().uuidString).mp4")
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
