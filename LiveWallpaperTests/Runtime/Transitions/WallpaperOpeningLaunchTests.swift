import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
private final class ManualLaunchClock: WallpaperTransitionClock {
    private var tick: (@MainActor (CFTimeInterval) -> Void)?
    private(set) var isRunning = false

    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.tick = tick
        isRunning = true
    }

    func stop() {
        tick = nil
        isRunning = false
    }

    func fire(_ time: CFTimeInterval) {
        tick?(time)
    }
}

@MainActor
private final class LaunchClockFactory {
    private(set) var made: [ManualLaunchClock] = []

    func make() -> any WallpaperTransitionClock {
        let clock = ManualLaunchClock()
        made.append(clock)
        return clock
    }
}

@MainActor
private final class OpeningTestSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene
    let wallpaperWindow: NSWindow?
    let videoPlayer: WallpaperVideoPlayer? = nil
    var summary: WallpaperSessionSummary {
        .notConfigured
    }

    private(set) var cleanupCallCount = 0
    private(set) var holds: [Bool] = []
    var isHeld: Bool {
        holds.last ?? false
    }

    init(window: NSWindow?) {
        wallpaperWindow = window
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func setTransitionHold(_ held: Bool) {
        holds.append(held)
    }

    func cleanup() {
        cleanupCallCount += 1
        wallpaperWindow?.close()
    }
}

private final class OpeningLaunchTestNSScreen: NSScreen {
    var displayID: UInt32 = 1
    override var frame: NSRect {
        NSRect(x: CGFloat(displayID) * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Opening Launch Test"
    }
}

@MainActor
private final class DecliningRenderer: WallpaperTransitionRendering {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    func prepare(_: WallpaperMaskShaders) -> Bool {
        false
    }

    func draw(_: WallpaperTransitionRenderer.Pass, shaders _: WallpaperMaskShaders,
              uniforms _: WallpaperTransitionUniforms, in _: CAMetalLayer,
              onFailure _: @escaping @MainActor @Sendable () -> Void) -> Bool {
        true
    }
}

@Suite("Wallpaper opening at launch", .serialized)
@MainActor
struct WallpaperOpeningLaunchTests {
    /// Parks itself off every display in the test host.
    private func makeWallpaperWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
    }

    private func makeScreen(_ clocks: LaunchClockFactory, plan: WallpaperTransitionPlan = .crossfade) throws -> Screen {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        screen.transitionEnvironment = WallpaperTransitionEnvironment(
            reduceMotion: { false }, lowPowerMode: { false }, plan: { _, _ in plan }, makeClock: { _ in clocks.make() }
        )
        return screen
    }

    private func makeScreen(id: UInt32, _ clocks: LaunchClockFactory, plan: WallpaperTransitionPlan = .crossfade) -> Screen {
        let nsScreen = OpeningLaunchTestNSScreen()
        nsScreen.displayID = id
        let screen = Screen(nsScreen: nsScreen)
        screen.transitionEnvironment = WallpaperTransitionEnvironment(
            reduceMotion: { false }, lowPowerMode: { false }, plan: { _, _ in plan }, makeClock: { _ in clocks.make() }
        )
        return screen
    }

    private func commitTask(
        _ candidate: any WallpaperRuntimeSession,
        to screen: Screen,
        replacing expected: (any WallpaperRuntimeSession)? = nil,
        claim: @escaping @MainActor () -> WallpaperOpeningClaim? = { nil }
    ) -> Task<WallpaperPreparationResult, Never> {
        Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: expected,
                timeout: .seconds(5),
                isStillCurrent: { true },
                claimOpening: claim
            )
        }
    }

    private func makeVideoPlayer() -> WallpaperVideoPlayer {
        WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/opening-launch-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 64, height: 36),
            loadImmediately: false
        )
    }

    @discardableResult
    private func commit(
        _ candidate: any WallpaperRuntimeSession,
        to screen: Screen,
        replacing expected: (any WallpaperRuntimeSession)? = nil,
        opening: WallpaperOpeningEffect?,
        prepare: (@MainActor (any WallpaperRuntimeSession, Duration) async -> WallpaperPreparationResult)? = nil,
        beforeCommit: @MainActor () -> Bool = { true },
        afterCommit: @MainActor () -> Void = {}
    ) async -> (result: WallpaperPreparationResult, claims: Int) {
        var claims = 0
        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate,
            to: screen,
            replacing: expected,
            timeout: .seconds(5),
            isStillCurrent: { true },
            prepare: prepare,
            claimOpening: {
                claims += 1
                return opening.map { WallpaperOpeningClaim(effect: $0, barrier: WallpaperStartBarrier()) }
            },
            beforeCommit: beforeCommit,
            afterCommit: afterCommit
        )
        return (result, claims)
    }

    @Test("A claimed opening keeps the candidate hidden until install, then uncovers it under a mask",
          .timeLimit(.minutes(1)))
    func claimedOpeningUncoversCandidate() async throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let window = makeWallpaperWindow()
        let candidate = OpeningTestSession(window: window)
        defer { screen.resetRuntimeSession() }
        var alphaAtInstall: CGFloat?

        let (result, claims) = await commit(candidate, to: screen, opening: .frame, beforeCommit: {
            alphaAtInstall = window.alphaValue
            return true
        })

        #expect(result == .ready && claims == 1)
        #expect(alphaAtInstall == 0)
        let opening = try #require(screen.openingTransition)
        let mask = try #require(opening.maskLayer)
        #expect(window.contentView?.layer?.mask === mask)
        #expect(window.alphaValue == 1)
        let clock = try #require(clocks.made.last)
        clock.fire(0)
        clock.fire(WallpaperOpeningEffect.frame.duration)
        #expect(opening.isFinished && screen.openingTransition == nil)
        #expect(window.contentView?.layer?.mask == nil && window.alphaValue == 1)
    }

    @Test("A video window created during prepare is hidden before it is first shown", .timeLimit(.minutes(1)))
    func videoWindowFromPrepareStartsHidden() async throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let player = makeVideoPlayer()
        let session = VideoWallpaperSession(player: player)
        let window = makeWallpaperWindow()
        defer { screen.resetRuntimeSession() }
        var alphaAtInstall: CGFloat?

        let (result, claims) = await commit(session, to: screen, opening: .dawn, prepare: { _, _ in
            player.installPlaybackWindowForTesting(window)
            return .ready
        }, beforeCommit: {
            alphaAtInstall = window.alphaValue
            return true
        })

        #expect(result == .ready && claims == 1)
        #expect(alphaAtInstall == 0)
        let opening = try #require(screen.openingTransition)
        #expect(opening.maskLayer != nil && window.contentView?.layer?.mask === opening.maskLayer)
        #expect(window.alphaValue == 1)
    }

    @Test("Replacing a live wallpaper never asks for the opening", .timeLimit(.minutes(1)))
    func replacementDoesNotClaim() async throws {
        let screen = try makeScreen(LaunchClockFactory(), plan: .none)
        let live = OpeningTestSession(window: makeWallpaperWindow())
        screen.installRuntimeSession(live)
        let window = makeWallpaperWindow()
        let candidate = OpeningTestSession(window: window)
        defer { screen.resetRuntimeSession() }

        let (result, claims) = await commit(candidate, to: screen, replacing: live, opening: .loom)

        #expect(result == .ready && claims == 0)
        #expect(screen.openingTransition == nil && candidate.holds.isEmpty)
        #expect(window.alphaValue == 1)
    }

    @Test("A candidate that loses the install CAS is cleaned up and gets no opening", .timeLimit(.minutes(1)))
    func lostCASLeavesNoOpening() async throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks, plan: .none)
        let live = OpeningTestSession(window: makeWallpaperWindow())
        screen.installRuntimeSession(live)
        defer { screen.resetRuntimeSession() }
        let candidate = OpeningTestSession(window: makeWallpaperWindow())

        let (result, claims) = await commit(candidate, to: screen, replacing: nil, opening: .loom)

        #expect(result == .cancelled && claims == 1)
        #expect(candidate.cleanupCallCount == 1 && candidate.holds.isEmpty)
        #expect(screen.openingTransition == nil && clocks.made.isEmpty)
        #expect((screen.runtimeSession as AnyObject?) === live)
    }

    @Test("Reduce Motion, Low Power Mode, no renderer or a declined start fade the window in instead",
          .timeLimit(.minutes(1)), arguments: [0, 1, 2, 3])
    func fallbackFadesIn(fallback: Int) async throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        switch fallback {
        case 0: screen.transitionEnvironment.reduceMotion = { true }
        case 1: screen.transitionEnvironment.lowPowerMode = { true }
        case 2: screen.transitionEnvironment.renderer = { nil }
        default:
            let renderer = try DecliningRenderer()
            screen.transitionEnvironment.renderer = { renderer }
        }
        let window = makeWallpaperWindow()
        let candidate = OpeningTestSession(window: window)
        defer { screen.resetRuntimeSession() }
        var alphaAtInstall: CGFloat?

        let (result, claims) = await commit(candidate, to: screen, opening: .loom, beforeCommit: {
            alphaAtInstall = window.alphaValue
            return true
        })

        #expect(result == .ready && claims == 1 && alphaAtInstall == 0)
        #expect(screen.openingTransition == nil && clocks.made.isEmpty)
        #expect(window.contentView?.layer?.mask == nil)
        #expect(candidate.holds == (fallback == 3 ? [true, false] : []))
        try await Task.sleep(for: .seconds(DesignTokens.Motion.wallpaperCrossfadeReducedMotionDuration + 0.3))
        #expect(window.alphaValue == 1)
    }

    @Test("Loom holds the new wallpaper from before the commit's policy refresh until the opening ends",
          .timeLimit(.minutes(1)))
    func loomHoldsUntilTheEnd() async throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let candidate = OpeningTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        var heldAtCommit: Bool?

        await commit(candidate, to: screen, opening: .loom, afterCommit: { heldAtCommit = candidate.isHeld })

        #expect(heldAtCommit == true)
        let clock = try #require(clocks.made.last)
        clock.fire(0)
        clock.fire(WallpaperOpeningEffect.loom.duration / 2)
        #expect(candidate.holds == [true])
        clock.fire(WallpaperOpeningEffect.loom.duration)
        #expect(candidate.holds == [true, false] && screen.openingTransition == nil)
    }

    @Test("Frame and Dawn never hold the new wallpaper", arguments: [WallpaperOpeningEffect.frame, .dawn])
    func frameAndDawnNeverHold(effect: WallpaperOpeningEffect) throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let window = makeWallpaperWindow()
        let session = OpeningTestSession(window: window)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(session)
        window.alphaValue = 0

        screen.startOpening(effect)

        let opening = try #require(screen.openingTransition)
        let clock = try #require(clocks.made.last)
        clock.fire(0)
        clock.fire(effect.duration)
        #expect(opening.isFinished && session.holds.isEmpty)
    }

    @Test("A video the user paused is still paused after Loom releases its hold", arguments: [true, false])
    func loomReleaseKeepsUserPause(paused: Bool) throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let player = makeVideoPlayer()
        let window = makeWallpaperWindow()
        player.installPlaybackWindowForTesting(window)
        let session = VideoWallpaperSession(player: player)
        defer { screen.resetRuntimeSession() }
        session.applyPerformanceProfile(.quality)
        if paused {
            session.pause()
        }
        screen.installRuntimeSession(session)
        window.alphaValue = 0

        screen.startOpening(.loom)

        #expect(screen.openingTransition != nil)
        #expect(!player.shouldAutoplayWhenReady)
        let clock = try #require(clocks.made.last)
        clock.fire(0)
        clock.fire(WallpaperOpeningEffect.loom.duration)
        #expect(screen.openingTransition == nil)
        #expect(player.shouldAutoplayWhenReady == !paused)
        #expect(session.userIntendsToPlay == !paused)
        if paused {
            #expect(session.summary.activity == .paused)
        }
    }

    @Test("Installing a new wallpaper mid-opening ends the opening, then runs the switch transition")
    func installMidOpeningEndsItFirst() throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks, plan: .reveal(.meteor))
        let firstWindow = makeWallpaperWindow()
        let first = OpeningTestSession(window: firstWindow)
        let second = OpeningTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(first)
        firstWindow.alphaValue = 0
        screen.startOpening(.loom)
        let opening = try #require(screen.openingTransition)
        let openingMask = try #require(opening.maskLayer)
        let clock = try #require(clocks.made.last)
        clock.fire(0)
        clock.fire(0.5)

        screen.installRuntimeSession(second)

        #expect(opening.isFinished && screen.openingTransition == nil)
        #expect(first.holds == [true, false])
        let reveal = try #require(screen.revealTransitions.values.first)
        let revealMask = try #require(reveal.maskLayer)
        #expect(revealMask !== openingMask)
        #expect(firstWindow.contentView?.layer?.mask === revealMask)
        #expect(first.cleanupCallCount == 0)
    }

    @Test("Resetting the screen or adopting its session on a refreshed screen ends the opening",
          arguments: [false, true])
    func resetAndAdoptionEndTheOpening(adopt: Bool) throws {
        let clocks = LaunchClockFactory()
        let screen = try makeScreen(clocks)
        let window = makeWallpaperWindow()
        let session = OpeningTestSession(window: window)
        screen.installRuntimeSession(session)
        window.alphaValue = 0
        screen.startOpening(.loom)
        let opening = try #require(screen.openingTransition)
        let refreshed = try Screen(nsScreen: #require(NSScreen.screens.first))
        defer {
            refreshed.resetRuntimeSession()
            screen.resetRuntimeSession()
        }

        if adopt {
            refreshed.adoptRuntimeSession(from: screen)
        } else {
            screen.resetRuntimeSession()
        }

        #expect(opening.isFinished && screen.openingTransition == nil)
        #expect(window.contentView?.layer?.mask == nil && opening.lightWindow == nil)
        #expect(window.alphaValue == 1)
        #expect(session.holds == [true, false])
    }

    /// Commits a fresh candidate on every display at once, each claiming from the batch at the same index.
    private func commitOpenings(on screens: [Screen], from batches: [WallpaperOpeningBatch]) async throws
        -> [WallpaperOpeningTransition] {
        var tasks: [Task<WallpaperPreparationResult, Never>] = []
        for (screen, batch) in zip(screens, batches) {
            batch.barrier.expect(screen.id)
            tasks.append(commitTask(OpeningTestSession(window: makeWallpaperWindow()), to: screen) { batch.claim(screen.id) })
        }
        for task in tasks {
            #expect(await task.value == .ready)
        }
        return try screens.map { try #require($0.openingTransition) }
    }

    @Test("Displays opening from one launch batch share the seed, the start time and the canvas",
          .timeLimit(.minutes(1)))
    func batchOpeningsStartTogether() async throws {
        let clocks = [LaunchClockFactory(), LaunchClockFactory()]
        let screens = [makeScreen(id: 81, clocks[0]), makeScreen(id: 82, clocks[1])]
        defer { screens.forEach { $0.resetRuntimeSession() } }
        let batch = WallpaperOpeningBatch(displayIDs: Set(screens.map(\.id)), effect: .loom)

        let openings = try await commitOpenings(on: screens, from: [batch, batch])

        #expect(openings[0].uniforms.seed == openings[1].uniforms.seed)
        let time = CACurrentMediaTime() + 0.2
        for factory in clocks {
            try #require(factory.made.last).fire(time)
        }
        let progress = openings.map(\.uniforms.progress)
        #expect(progress[0] == progress[1] && progress[0] > 0)
        let canvas = screens[0].frame.union(screens[1].frame)
        for (opening, screen) in zip(openings, screens) {
            let region = WallpaperCanvasRegion(frame: screen.frame, canvas: canvas)
            #expect(opening.uniforms.regionOrigin == region.origin && opening.uniforms.regionSize == region.size)
            #expect(opening.uniforms.canvasAspect == region.canvasAspect)
        }
    }

    @Test("Displays switched by one group start the reveal together with one seed", .timeLimit(.minutes(1)))
    func groupedRevealsStartTogether() async throws {
        let clocks = [LaunchClockFactory(), LaunchClockFactory()]
        let screens = [makeScreen(id: 83, clocks[0], plan: .reveal(.meteor)),
                       makeScreen(id: 84, clocks[1], plan: .reveal(.meteor))]
        defer { screens.forEach { $0.resetRuntimeSession() } }
        let olds = screens.map { _ in OpeningTestSession(window: makeWallpaperWindow()) }
        for (screen, old) in zip(screens, olds) {
            screen.installRuntimeSession(old)
        }
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        var tasks: [Task<WallpaperPreparationResult, Never>] = []
        for (screen, old) in zip(screens, olds) {
            group.barrier.expect(screen.id)
            let candidate = OpeningTestSession(window: makeWallpaperWindow())
            tasks.append(WallpaperSwitchGroup.$current.withValue(group) { commitTask(candidate, to: screen, replacing: old) })
        }
        for task in tasks {
            #expect(await task.value == .ready)
        }

        let reveals = try screens.map { try #require($0.revealTransitions.values.first) }
        #expect(reveals[0].uniforms.seed == reveals[1].uniforms.seed)
        let time = CACurrentMediaTime() + 0.2
        for factory in clocks {
            try #require(factory.made.last).fire(time)
        }
        let progress = reveals.map(\.uniforms.progress)
        #expect(progress[0] == progress[1] && progress[0] > 0)
    }

    @Test("Openings claimed from separate batches each start on their first tick", .timeLimit(.minutes(1)))
    func separateBatchesStartOnFirstTick() async throws {
        let clocks = [LaunchClockFactory(), LaunchClockFactory()]
        let screens = [makeScreen(id: 85, clocks[0]), makeScreen(id: 86, clocks[1])]
        defer { screens.forEach { $0.resetRuntimeSession() } }
        let batches = screens.map { WallpaperOpeningBatch(displayIDs: [$0.id], effect: .loom) }

        let openings = try await commitOpenings(on: screens, from: batches)

        let time = CACurrentMediaTime() + 0.2
        for factory in clocks {
            try #require(factory.made.last).fire(time)
        }
        #expect(openings.map(\.uniforms.progress) == [0, 0])
    }
}
