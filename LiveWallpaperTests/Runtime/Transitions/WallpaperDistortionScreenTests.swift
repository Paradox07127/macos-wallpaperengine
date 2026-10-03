import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
private final class DistortionScreenClock: WallpaperTransitionClock {
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

/// Every clock a screen asked for, oldest first.
@MainActor
private final class DistortionClockFactory {
    private(set) var clocks: [DistortionScreenClock] = []

    func make() -> DistortionScreenClock {
        let clock = DistortionScreenClock()
        clocks.append(clock)
        return clock
    }
}

/// Calls from all sessions of one test, in order.
@MainActor
private final class DistortionEventLog {
    var entries: [String] = []
}

@MainActor
private final class DistortionTestSession: WallpaperRuntimeSession {
    struct CaptureRequest: Equatable {
        let pixelFormat: MTLPixelFormat
        let colorSpace: String?
    }

    let name: String
    let wallpaperType: WallpaperType
    let wallpaperWindow: NSWindow?
    let videoPlayer: WallpaperVideoPlayer? = nil
    var summary: WallpaperSessionSummary {
        .notConfigured
    }

    /// nil = the session has no frame to give.
    var capture: WallpaperFrameCapture?
    /// Capture waits until `releaseCapture()`; a release that comes first lets every later capture through.
    var holdsCapture = false
    var onProfile: ((WallpaperPerformanceProfile) -> Void)?
    private let log: DistortionEventLog
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private(set) var holds: [Bool] = []
    private(set) var profiles: [WallpaperPerformanceProfile] = []
    private(set) var captureRequests: [CaptureRequest] = []
    private(set) var cleanupCallCount = 0
    private(set) var alphaAtCleanup: CGFloat?

    init(_ name: String, type: WallpaperType = .scene, capture: WallpaperFrameCapture?, log: DistortionEventLog) {
        self.name = name
        wallpaperType = type
        self.capture = capture
        self.log = log
        wallpaperWindow = VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
    }

    func show() {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        profiles.append(profile)
        log.entries.append("\(name).profile(\(profile))")
        onProfile?(profile)
    }

    func setTransitionHold(_ held: Bool) {
        holds.append(held)
        log.entries.append("\(name).hold(\(held))")
    }

    func captureDisplayedFrame(device _: any MTLDevice, pixelFormat: MTLPixelFormat, colorSpace: CGColorSpace) async -> WallpaperFrameCapture? {
        captureRequests.append(CaptureRequest(pixelFormat: pixelFormat, colorSpace: colorSpace.name as String?))
        log.entries.append("\(name).capture")
        if holdsCapture {
            await withCheckedContinuation { waiting.append($0) }
        }
        return capture
    }

    func releaseCapture() {
        holdsCapture = false
        let waiting = waiting
        self.waiting.removeAll()
        waiting.forEach { $0.resume() }
    }

    func cleanup() {
        cleanupCallCount += 1
        alphaAtCleanup = wallpaperWindow?.alphaValue
        log.entries.append("\(name).cleanup")
        wallpaperWindow?.close()
    }
}

@Suite("Wallpaper distortion on Screen", .serialized)
@MainActor
struct WallpaperDistortionScreenTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let sRGBName = CGColorSpace.sRGB as String

    private func makeCapture(
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        color: MTLClearColor = MTLClearColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1),
        colorSpace: CGColorSpace? = WallpaperDistortionScreenTests.sRGB
    ) throws -> WallpaperFrameCapture {
        let device = try #require(WallpaperDistortionRenderer.shared?.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: 96, height: 54, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = color
        pass.colorAttachments[0].storeAction = .store
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return WallpaperFrameCapture(texture: texture, colorSpace: colorSpace, isEDR: false)
    }

    private func makeScreen(
        plan: WallpaperTransitionPlan = .distortion(.ripple),
        clocks: DistortionClockFactory,
        lowPower: Bool = false
    ) throws -> Screen {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        screen.transitionEnvironment = WallpaperTransitionEnvironment(
            lowPowerMode: { lowPower }, plan: { _, _ in plan }, makeClock: { _ in clocks.make() }
        )
        return screen
    }

    /// Polls; `Issue.record`s and returns false after `timeout`.
    @discardableResult
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                return false
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Lets every task queued on the main actor run a few turns.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func incomingCapture() throws -> WallpaperFrameCapture {
        try makeCapture(color: MTLClearColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    }

    @Test("Before the frames arrive the old window is click-through, both sessions are held and nothing is drawn")
    func synchronousPhase() throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        #expect(old.wallpaperWindow?.ignoresMouseEvents == true)
        #expect(old.holds == [true] && new.holds == [true])
        #expect(old.profiles.isEmpty, "the old session must not be suspended before its frame is captured")
        #expect(screen.retiringSessions[ObjectIdentifier(old)] != nil)
        #expect(screen.pendingDistortions.count == 1)
        #expect(screen.distortionTransitions.isEmpty && clocks.clocks.isEmpty)
        #expect(old.cleanupCallCount == 0)
    }

    @Test("The distortion plays over both wallpapers, then hides and cleans up the old session once",
          .timeLimit(.minutes(1)))
    func successfulDistortion() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        defer { screen.resetRuntimeSession() }
        var compositeVisibleAtSuspend: Bool?
        old.onProfile = { _ in
            compositeVisibleAtSuspend = screen.distortionTransitions.values.first?.compositeWindow?.isVisible
        }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        try await waitUntil("the composite") { screen.distortionTransitions.values.first?.compositeWindow != nil }
        let transition = try #require(screen.distortionTransitions.values.first)
        let composite = try #require(transition.compositeWindow)
        #expect(screen.pendingDistortions.isEmpty)
        #expect(old.profiles == [.suspended] && compositeVisibleAtSuspend == true)
        #expect(old.captureRequests.count == 1 && new.captureRequests.count == 1)
        let clock = try #require(clocks.clocks.last)

        clock.fire(100)
        clock.fire(100 + transition.duration / 2)
        #expect(old.cleanupCallCount == 0)
        clock.fire(100 + transition.duration)

        #expect(old.cleanupCallCount == 1 && old.alphaAtCleanup == 0)
        #expect(!composite.isVisible && transition.compositeWindow == nil)
        #expect(screen.distortionTransitions.isEmpty && screen.retiringSessions.isEmpty)
        #expect(new.holds == [true, false])
        #expect(new.cleanupCallCount == 0 && new.profiles.isEmpty)
        #expect(!clock.isRunning)
    }

    @Test("A side with no frame falls back to the crossfade after releasing the incoming hold",
          .timeLimit(.minutes(1)), arguments: [true, false])
    func missingFrameCrossfades(oldMissing: Bool) async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks, lowPower: true)
        let old = try DistortionTestSession("old", capture: oldMissing ? nil : makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: oldMissing ? incomingCapture() : nil, log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        try await waitUntil("the fallback") { screen.pendingDistortions.isEmpty }
        #expect(new.holds == [true, false])
        #expect(old.profiles == [.suspended])
        let release = try #require(log.entries.firstIndex(of: "new.hold(false)"))
        let suspend = try #require(log.entries.firstIndex(of: "old.profile(suspended)"))
        #expect(release < suspend)
        #expect(screen.distortionTransitions.isEmpty && clocks.clocks.isEmpty)
        #expect(old.cleanupCallCount == 0 && screen.retiringSessions[ObjectIdentifier(old)] != nil)

        try await waitUntil("the crossfade to end") { old.cleanupCallCount > 0 }
        try await settle()
        #expect(old.cleanupCallCount == 1 && screen.retiringSessions.isEmpty)
        #expect(new.cleanupCallCount == 0)
    }

    @Test("Frames in different formats fall back to the crossfade", .timeLimit(.minutes(1)))
    func incompatibleFramesCrossfade() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks, lowPower: true)
        let old = try DistortionTestSession("old", capture: makeCapture(pixelFormat: .bgra8Unorm), log: log)
        let new = try DistortionTestSession("new", capture: makeCapture(pixelFormat: .rgba16Float), log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        try await waitUntil("the fallback") { screen.pendingDistortions.isEmpty }
        #expect(old.captureRequests.count == 1 && new.captureRequests.count == 1)
        #expect(new.holds == [true, false] && old.profiles == [.suspended])
        let release = try #require(log.entries.firstIndex(of: "new.hold(false)"))
        let suspend = try #require(log.entries.firstIndex(of: "old.profile(suspended)"))
        #expect(release < suspend)
        #expect(screen.distortionTransitions.isEmpty && clocks.clocks.isEmpty)

        try await waitUntil("the crossfade to end") { old.cleanupCallCount > 0 }
        try await settle()
        #expect(old.cleanupCallCount == 1 && screen.retiringSessions.isEmpty)
    }

    @Test("A second swap while frames are captured ends the first distortion and its late frames change nothing",
          .timeLimit(.minutes(1)))
    func swapDuringCapture() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let first = try DistortionTestSession("first", capture: makeCapture(), log: log)
        let second = try DistortionTestSession("second", capture: incomingCapture(), log: log)
        let third = try DistortionTestSession("third", capture: makeCapture(), log: log)
        first.holdsCapture = true
        defer {
            first.releaseCapture()
            screen.resetRuntimeSession()
        }
        screen.installRuntimeSession(first)
        screen.installRuntimeSession(second)
        try await waitUntil("the first capture") { !first.captureRequests.isEmpty }

        screen.installRuntimeSession(third)

        #expect(first.cleanupCallCount == 1)
        #expect(Array(second.holds.prefix(2)) == [true, false])
        #expect(screen.retiringSessions[ObjectIdentifier(first)] == nil)

        first.releaseCapture()
        try await settle()
        #expect(first.cleanupCallCount == 1)
        #expect(first.profiles.isEmpty, "a late fallback would fade out a session that is already gone")
        #expect(!screen.distortionTransitions.keys.contains(ObjectIdentifier(first)))
        #expect(screen.pendingDistortions[ObjectIdentifier(first)] == nil)
    }

    @Test("Removing the display while frames are captured tears down both sessions; late frames change nothing",
          .timeLimit(.minutes(1)))
    func resetDuringCapture() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        old.holdsCapture = true
        defer {
            old.releaseCapture()
            screen.resetRuntimeSession()
        }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        try await waitUntil("the old capture") { !old.captureRequests.isEmpty }

        screen.resetRuntimeSession()

        #expect(old.cleanupCallCount == 1)
        #expect(new.holds == [true, false] && new.cleanupCallCount == 1)
        let release = try #require(log.entries.firstIndex(of: "new.hold(false)"))
        let cleanup = try #require(log.entries.firstIndex(of: "new.cleanup"))
        #expect(release < cleanup)
        #expect(screen.pendingDistortions.isEmpty && screen.retiringSessions.isEmpty)

        let settledLog = log.entries
        old.releaseCapture()
        try await settle()
        #expect(screen.distortionTransitions.isEmpty && clocks.clocks.isEmpty)
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 1)
        #expect(old.profiles.isEmpty)
        #expect(log.entries.dropFirst(settledLog.count).allSatisfy { $0.hasSuffix(".capture") })
    }

    @Test("A refreshed screen adopting the session mid-capture ends the old screen's distortion",
          .timeLimit(.minutes(1)))
    func adoptionDuringCapture() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let original = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        old.holdsCapture = true
        let refreshed = try Screen(nsScreen: #require(NSScreen.screens.first))
        defer {
            old.releaseCapture()
            original.resetRuntimeSession()
            refreshed.resetRuntimeSession()
        }
        original.installRuntimeSession(old)
        original.installRuntimeSession(new)
        try await waitUntil("the old capture") { !old.captureRequests.isEmpty }

        refreshed.adoptRuntimeSession(from: original)

        #expect(old.cleanupCallCount == 1)
        #expect(new.holds == [true, false] && new.cleanupCallCount == 0)
        #expect((refreshed.runtimeSession as AnyObject?) === new)
        #expect(original.pendingDistortions.isEmpty && original.retiringSessions.isEmpty)

        let settledLog = log.entries
        old.releaseCapture()
        try await settle()
        #expect(original.distortionTransitions.isEmpty && clocks.clocks.isEmpty)
        #expect(old.cleanupCallCount == 1 && old.profiles.isEmpty)
        #expect(log.entries.dropFirst(settledLog.count).allSatisfy { $0.hasSuffix(".capture") })
    }

    @Test("A second swap mid-distortion ends the first one and starts the next", .timeLimit(.minutes(1)))
    func swapDuringPlayback() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let first = try DistortionTestSession("first", capture: makeCapture(), log: log)
        let second = try DistortionTestSession("second", capture: incomingCapture(), log: log)
        let third = try DistortionTestSession("third", capture: makeCapture(), log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(first)
        screen.installRuntimeSession(second)
        try await waitUntil("the first composite") { screen.distortionTransitions[ObjectIdentifier(first)] != nil }
        let firstTransition = try #require(screen.distortionTransitions[ObjectIdentifier(first)])
        let firstComposite = try #require(firstTransition.compositeWindow)
        let firstClock = try #require(clocks.clocks.last)
        firstClock.fire(0)
        firstClock.fire(firstTransition.duration / 3)

        screen.installRuntimeSession(third)

        #expect(firstTransition.isFinished && !firstClock.isRunning)
        #expect(first.cleanupCallCount == 1 && first.alphaAtCleanup == 0)
        #expect(!firstComposite.isVisible)
        #expect(second.holds == [true, false, true])
        #expect(third.holds == [true])
        #expect(screen.pendingDistortions.keys.contains(ObjectIdentifier(second)))

        try await waitUntil("the second composite") {
            screen.distortionTransitions[ObjectIdentifier(second)]?.compositeWindow != nil
        }
        #expect(second.profiles == [.suspended] && second.cleanupCallCount == 0)
        #expect(clocks.clocks.count == 2)
    }

    @Test("Removing the display mid-distortion tears everything down at once", .timeLimit(.minutes(1)))
    func resetDuringPlayback() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        try await waitUntil("the composite") { screen.distortionTransitions.values.first?.compositeWindow != nil }
        let transition = try #require(screen.distortionTransitions.values.first)
        let composite = try #require(transition.compositeWindow)
        let clock = try #require(clocks.clocks.last)
        clock.fire(0)
        clock.fire(0.3)

        screen.resetRuntimeSession()

        #expect(transition.isFinished && !clock.isRunning)
        #expect(!composite.isVisible && transition.compositeWindow == nil)
        #expect(old.cleanupCallCount == 1 && old.alphaAtCleanup == 0)
        #expect(new.holds == [true, false] && new.cleanupCallCount == 1)
        #expect(screen.distortionTransitions.isEmpty && screen.retiringSessions.isEmpty)
    }

    @Test("A capture policy change mid-distortion reaches the composite window", .timeLimit(.minutes(1)))
    func capturePolicyDuringPlayback() async throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        try await waitUntil("the composite") { screen.distortionTransitions.values.first?.compositeWindow != nil }
        let composite = try #require(screen.distortionTransitions.values.first?.compositeWindow)
        let flipped: NSWindow.SharingType = composite.sharingType == .none ? .readOnly : .none

        screen.applyCapturePolicy(flipped)

        #expect(composite.sharingType == flipped)
    }

    @Test("Frames are captured scene side first, and the other side is asked to match", .timeLimit(.minutes(1)))
    func captureOrder() async throws {
        let device = try #require(WallpaperDistortionRenderer.shared?.device)
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        let videoToScene = DistortionEventLog()
        let video = try DistortionTestSession("old", type: .video, capture: makeCapture(), log: videoToScene)
        let scene = try DistortionTestSession(
            "new", capture: makeCapture(pixelFormat: .rgba16Float, colorSpace: displayP3), log: videoToScene
        )
        let frames = await WallpaperDistortionTransition.captureFrames(old: video, incoming: scene, device: device)
        #expect(videoToScene.entries == ["new.capture", "old.capture"])
        #expect(scene.captureRequests == [.init(pixelFormat: .bgra8Unorm, colorSpace: Self.sRGBName)])
        #expect(video.captureRequests == [.init(pixelFormat: .rgba16Float, colorSpace: displayP3.name as String?)])
        #expect(frames?.from.texture === video.capture?.texture && frames?.to.texture === scene.capture?.texture)

        let sceneToVideo = DistortionEventLog()
        let oldScene = try DistortionTestSession("old", capture: makeCapture(colorSpace: nil), log: sceneToVideo)
        let newVideo = try DistortionTestSession("new", type: .video, capture: makeCapture(), log: sceneToVideo)
        _ = await WallpaperDistortionTransition.captureFrames(old: oldScene, incoming: newVideo, device: device)
        #expect(sceneToVideo.entries == ["old.capture", "new.capture"])
        #expect(newVideo.captureRequests == [.init(pixelFormat: .bgra8Unorm, colorSpace: Self.sRGBName)],
                "a frame without a colour space must be matched as sRGB")

        let neither = DistortionEventLog()
        let oldVideo = try DistortionTestSession(
            "old", type: .video, capture: makeCapture(pixelFormat: .bgra8Unorm), log: neither
        )
        let newWeb = try DistortionTestSession("new", type: .html, capture: makeCapture(), log: neither)
        _ = await WallpaperDistortionTransition.captureFrames(old: oldVideo, incoming: newWeb, device: device)
        #expect(neither.entries == ["old.capture", "new.capture"])
        let request = DistortionTestSession.CaptureRequest(pixelFormat: .bgra8Unorm, colorSpace: Self.sRGBName)
        #expect(oldVideo.captureRequests == [request] && newWeb.captureRequests == [request])

        let missing = DistortionEventLog()
        let emptyScene = DistortionTestSession("new", capture: nil, log: missing)
        let otherVideo = try DistortionTestSession("old", type: .video, capture: makeCapture(), log: missing)
        let none = await WallpaperDistortionTransition.captureFrames(old: otherVideo, incoming: emptyScene, device: device)
        #expect(none == nil)
        #expect(missing.entries == ["new.capture"], "the other side must not be captured after a miss")

        for session in [video, scene, oldScene, newVideo, oldVideo, newWeb, emptyScene, otherVideo] {
            session.cleanup()
        }
    }

    @Test("Without a distortion renderer the swap crossfades at once and holds nothing")
    func noRendererCrossfades() throws {
        let log = DistortionEventLog()
        let clocks = DistortionClockFactory()
        let screen = try makeScreen(clocks: clocks)
        screen.transitionEnvironment.distortionRenderer = { nil }
        let old = try DistortionTestSession("old", capture: makeCapture(), log: log)
        let new = try DistortionTestSession("new", capture: incomingCapture(), log: log)
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        #expect(old.profiles == [.suspended])
        #expect(old.wallpaperWindow?.ignoresMouseEvents == true)
        #expect(screen.pendingDistortions.isEmpty && screen.distortionTransitions.isEmpty)
        #expect(old.holds.isEmpty && new.holds.isEmpty)
        #expect(old.captureRequests.isEmpty && new.captureRequests.isEmpty)
        #expect(screen.retiringSessions[ObjectIdentifier(old)] != nil)
    }
}
