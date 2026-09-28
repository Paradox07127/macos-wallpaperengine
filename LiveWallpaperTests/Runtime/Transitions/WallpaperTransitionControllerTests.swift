import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
private final class ManualTransitionClock: WallpaperTransitionClock {
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
private final class TransitionTestSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene
    let wallpaperWindow: NSWindow?
    let videoPlayer: WallpaperVideoPlayer? = nil
    var summary: WallpaperSessionSummary {
        .notConfigured
    }

    private(set) var cleanupCallCount = 0

    init(window: NSWindow?) {
        wallpaperWindow = window
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {
        cleanupCallCount += 1
        wallpaperWindow?.close()
    }
}

@MainActor
private final class FailingTransitionRenderer: WallpaperTransitionRendering {
    let device: MTLDevice
    var isPrepared = true
    var submissions: [Bool] = []
    private(set) var drawCount = 0
    private(set) var failures: [@MainActor @Sendable () -> Void] = []

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    func prepare(_: WallpaperRevealEffect) -> Bool {
        isPrepared
    }

    func draw(_: WallpaperTransitionRenderer.Pass, effect _: WallpaperRevealEffect,
              uniforms _: WallpaperTransitionUniforms, in _: CAMetalLayer,
              onFailure: @escaping @MainActor @Sendable () -> Void) -> Bool {
        drawCount += 1
        failures.append(onFailure)
        return submissions.isEmpty ? true : submissions.removeFirst()
    }
}

@Suite("Wallpaper reveal transition controller", .serialized)
@MainActor
struct WallpaperTransitionControllerTests {
    private static let interactiveLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    @Test("Missing effect or first draw leaves no mask, light, clock or reveal owner", arguments: [0, 1, 2])
    func rejectedStartLeavesNothingAttached(failure: Int) throws {
        let renderer = try FailingTransitionRenderer()
        renderer.isPrepared = failure != 0
        renderer.submissions = failure == 1 ? [false] : [true, false]
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualTransitionClock()
        var finished = 0
        let candidate = WallpaperRevealTransition(
            effect: .meteor, oldWindow: old, newWindow: nil, renderer: renderer,
            makeClock: { _ in clock }, onFinish: { finished += 1 }
        )
        let transition = try #require(candidate)
        #expect(!transition.start())
        #expect(old.contentView?.layer?.mask == nil)
        #expect(transition.maskLayer == nil && transition.lightWindow == nil)
        #expect(!clock.isRunning && finished == 0)
        renderer.failures.forEach { $0() }
        #expect(old.alphaValue == 1 && finished == 0)
    }

    @Test("A host disappearing before start declines without taking retirement ownership")
    func missingHostDeclinesStart() throws {
        let renderer = try FailingTransitionRenderer()
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualTransitionClock()
        let candidate = WallpaperRevealTransition(
            effect: .ink, oldWindow: old, newWindow: nil, renderer: renderer,
            makeClock: { _ in clock }, onFinish: { Issue.record("Rejected start must not finish") }
        )
        let transition = try #require(candidate)
        old.contentView = nil
        #expect(!transition.start())
        #expect(renderer.drawCount == 0 && !clock.isRunning)
    }

    @Test("A display that never ticks still retires once; late GPU failure is harmless")
    func noTickDeadlineAndLateFailure() async throws {
        let renderer = try FailingTransitionRenderer()
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualTransitionClock()
        var finished = 0
        let candidate = WallpaperRevealTransition(
            effect: .meteor, oldWindow: old, newWindow: nil, renderer: renderer,
            makeClock: { _ in clock }, finishDeadline: .milliseconds(30), onFinish: { finished += 1 }
        )
        let transition = try #require(candidate)
        #expect(transition.start())
        let timeout = ContinuousClock.now.advanced(by: .seconds(1))
        while !transition.isFinished, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transition.isFinished && finished == 1 && !clock.isRunning)
        #expect(old.contentView?.layer?.mask == nil && transition.lightWindow == nil)
        renderer.failures.forEach { $0() }
        clock.fire(100)
        transition.finish()
        #expect(finished == 1)
    }

    @Test("GPU failure finishes promptly and cancels the later deadline")
    func gpuFailureFinishesOnce() async throws {
        let renderer = try FailingTransitionRenderer()
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualTransitionClock()
        var finished = 0
        let candidate = WallpaperRevealTransition(
            effect: .meteor, oldWindow: old, newWindow: nil, renderer: renderer,
            makeClock: { _ in clock }, finishDeadline: .milliseconds(50), onFinish: { finished += 1 }
        )
        let transition = try #require(candidate)
        #expect(transition.start())
        let failure = try #require(renderer.failures.first)
        failure()
        #expect(transition.isFinished && finished == 1 && !clock.isRunning)
        renderer.failures.forEach { $0() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished == 1)
    }

    @Test("Later mask or light submission failure retires resources and session once", arguments: [false, true])
    func laterSubmissionFailureRetiresOnce(lightFails: Bool) throws {
        let renderer = try FailingTransitionRenderer()
        renderer.submissions = lightFails ? [true, true, true, false] : [true, true, false]
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.meteor), clock: clock)
        screen.transitionEnvironment.renderer = { renderer }
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        let transition = try #require(screen.revealTransitions.values.first)
        let light = try #require(transition.lightWindow)
        #expect(clock.isRunning && old.cleanupCallCount == 0)

        clock.fire(100)

        #expect(renderer.drawCount == (lightFails ? 4 : 3))
        #expect(transition.isFinished && !clock.isRunning)
        #expect(transition.maskLayer == nil && transition.lightWindow == nil)
        #expect(old.wallpaperWindow?.contentView?.layer?.mask == nil && !light.isVisible)
        #expect(screen.revealTransitions.isEmpty)
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 0)
        renderer.failures.forEach { $0() }
        clock.fire(101)
        transition.finish()
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 0)
    }

    @Test("Screen retires a no-tick display once and closes its light window")
    func screenNoTickDeadlineRetiresOnce() async throws {
        let renderer = try FailingTransitionRenderer()
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.meteor), clock: clock)
        screen.transitionEnvironment.renderer = { renderer }
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        let transition = try #require(screen.revealTransitions.values.first)
        let light = try #require(transition.lightWindow)
        let wallClock = ContinuousClock()
        let deadline = wallClock.now.advanced(by: .seconds(4))
        while old.cleanupCallCount == 0, wallClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 0)
        #expect(screen.revealTransitions.isEmpty && !clock.isRunning)
        #expect(transition.isFinished && transition.maskLayer == nil)
        #expect(transition.lightWindow == nil && !light.isVisible)
        renderer.failures.forEach { $0() }
        clock.fire(100)
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 0)
    }

    @Test("Screen sends a rejected first draw to its existing crossfade cleanup")
    func screenRejectedStartUsesCrossfade() async throws {
        let renderer = try FailingTransitionRenderer()
        renderer.submissions = [false]
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.meteor), clock: clock)
        screen.transitionEnvironment.renderer = { renderer }
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        #expect(screen.revealTransitions.isEmpty && !clock.isRunning)
        #expect(old.wallpaperWindow?.contentView?.layer?.mask == nil)
        try await Task.sleep(for: .seconds(DesignTokens.Motion.wallpaperCrossfadeDuration + 0.15))
        #expect(old.cleanupCallCount == 1 && new.cleanupCallCount == 0)
    }

    /// Parks itself off every display in the test host.
    private func makeWallpaperWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
    }

    private func makeTransition(
        _ effect: WallpaperRevealEffect,
        old: NSWindow,
        new: NSWindow?,
        clock: ManualTransitionClock,
        onFinish: @escaping @MainActor () -> Void = {}
    ) throws -> WallpaperRevealTransition {
        let transition = WallpaperRevealTransition(
            effect: effect,
            oldWindow: old,
            newWindow: new,
            makeClock: { _ in clock },
            onFinish: onFinish
        )
        return try #require(transition)
    }

    private func makeScreen(plan: WallpaperTransitionPlan, clock: ManualTransitionClock) throws -> Screen {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        screen.transitionEnvironment = WallpaperTransitionEnvironment(plan: { plan }, makeClock: { _ in clock })
        return screen
    }

    @Test("Starting a reveal masks the old window and puts the light overlay above it")
    func startAttachesMaskAndLight() throws {
        let old = makeWallpaperWindow()
        let new = makeWallpaperWindow()
        defer { old.close(); new.close() }
        let clock = ManualTransitionClock()
        let transition = try makeTransition(.meteor, old: old, new: new, clock: clock)
        defer { transition.finish() }

        transition.start()

        let mask = try #require(transition.maskLayer)
        #expect(old.contentView?.layer?.mask === mask)
        let light = try #require(transition.lightWindow)
        #expect(light.isVisible)
        #expect(light.level.rawValue > old.level.rawValue)
        #expect(light.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)), "the overlay would cover desktop icons")
        #expect(light.ignoresMouseEvents)
        #expect(clock.isRunning)
    }

    @Test("A reveal runs for its duration, then removes mask and overlay and hands the old session back")
    func revealFinishesAtItsDuration() throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualTransitionClock()
        var finished = 0
        let transition = try makeTransition(.meteor, old: old, new: nil, clock: clock) { finished += 1 }
        transition.start()
        let light = try #require(transition.lightWindow)

        clock.fire(100)
        clock.fire(100 + WallpaperRevealEffect.meteor.duration / 2)
        #expect(finished == 0)
        #expect(old.contentView?.layer?.mask != nil)

        clock.fire(100 + WallpaperRevealEffect.meteor.duration)
        #expect(finished == 1)
        #expect(transition.isFinished)
        #expect(old.contentView?.layer?.mask == nil)
        #expect(transition.lightWindow == nil)
        #expect(!light.isVisible)
        #expect(!clock.isRunning)
        #expect(old.alphaValue == 0, "the old frame would flash back between mask removal and close")

        transition.finish()
        #expect(finished == 1)
    }

    @Test("Ink draws no light overlay")
    func inkHasNoOverlay() throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        let transition = try makeTransition(.ink, old: old, new: nil, clock: ManualTransitionClock())
        defer { transition.finish() }
        transition.start()
        #expect(transition.maskLayer != nil)
        #expect(transition.lightWindow == nil)
    }

    @Test("Over an interactive wallpaper the overlay shares its level and returns on top after it orders front")
    func overlayRestacksAboveInteractiveWallpaper() throws {
        let old = makeWallpaperWindow()
        let new = makeWallpaperWindow()
        defer { old.close(); new.close() }
        new.level = Self.interactiveLevel
        let transition = try makeTransition(.leak, old: old, new: new, clock: ManualTransitionClock())
        defer { transition.finish() }
        transition.start()
        let light = try #require(transition.lightWindow)
        #expect(light.level == Self.interactiveLevel)

        new.orderFrontRegardless()
        // Control: without the notification the wallpaper now sits above the overlay.
        #expect(new.orderedIndex < light.orderedIndex)
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: new)
        #expect(light.orderedIndex < new.orderedIndex)
    }

    @Test("The masked old content stays above incoming content across wallpaper levels, including Ink",
          arguments: [WallpaperRevealEffect.ink, .meteor], [false, true])
    func contentOrderAcrossLevels(effect: WallpaperRevealEffect, oldIsInteractive: Bool) throws {
        try #require(TestHostWindowParking.isEnabled, "Window-order fixtures must never appear on the user's desktop")
        let old = makeWallpaperWindow()
        let new = makeWallpaperWindow()
        let passiveLevel = old.level
        old.level = oldIsInteractive ? Self.interactiveLevel : passiveLevel
        new.level = oldIsInteractive ? passiveLevel : Self.interactiveLevel
        let originalOldLevel = old.level
        old.orderFrontRegardless()
        new.orderFrontRegardless()
        if !oldIsInteractive {
            // Control: this is why a mask alone cannot reveal the incoming wallpaper.
            #expect(new.orderedIndex < old.orderedIndex)
        }
        let widget = NSWindow(contentRect: old.frame, styleMask: .borderless, backing: .buffered, defer: false)
        widget.isReleasedWhenClosed = false
        widget.level = NSWindow.Level(rawValue: Self.interactiveLevel.rawValue + 1)
        widget.ignoresMouseEvents = true
        widget.orderFrontRegardless()
        defer { old.close(); new.close(); widget.close() }
        let keyWindow = NSApp.keyWindow
        let wasActive = NSApp.isActive
        let clock = ManualTransitionClock()
        var finished = 0
        let transition = try makeTransition(effect, old: old, new: new, clock: clock) { finished += 1 }
        defer { transition.finish() }
        transition.start()

        #expect(old.level == Self.interactiveLevel)
        #expect(old.orderedIndex < new.orderedIndex)
        #expect(old.contentView?.layer?.mask === transition.maskLayer)
        #expect(transition.maskLayer != nil)
        #expect(old.ignoresMouseEvents)
        #expect(!old.acceptsMouseMovedEvents)
        #expect(widget.orderedIndex < old.orderedIndex)
        let light = transition.lightWindow
        if effect == .ink {
            #expect(light == nil)
        } else {
            let light = try #require(light)
            #expect(light.orderedIndex < old.orderedIndex)
            #expect(widget.orderedIndex < light.orderedIndex)
        }
        for window in [old, new, widget] + [light].compactMap(\.self) {
            #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        }

        // Real Window Server reordering, without makeKeyAndOrderFront (which
        // would take focus even though a test's interactive window is parked).
        // Post the product notification explicitly after that real reorder.
        new.level = Self.interactiveLevel
        new.orderFrontRegardless()
        #expect(new.orderedIndex < old.orderedIndex)
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: widget)
        #expect(new.orderedIndex < old.orderedIndex, "Unrelated windows must not reorder this display's transition")
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: new)
        #expect(old.orderedIndex < new.orderedIndex)
        if let light {
            #expect(light.orderedIndex < old.orderedIndex)
            #expect(widget.orderedIndex < light.orderedIndex)
        }
        clock.fire(0)
        clock.fire(effect.duration / 2)
        #expect(!transition.isFinished)
        #expect(old.contentView?.layer?.mask === transition.maskLayer)
        #expect(old.orderedIndex < new.orderedIndex)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(NSApp.isActive == wasActive)

        transition.finish() // The same path used by cancellation and a replacement transition.
        transition.finish()
        #expect(finished == 1)
        #expect(!clock.isRunning)
        #expect(old.alphaValue == 0)
        #expect(old.level == originalOldLevel)
        #expect(old.contentView?.layer?.mask == nil)
        #expect(transition.lightWindow == nil)
        #expect(light?.isVisible != true)
        let sentinelLevel = NSWindow.Level(rawValue: originalOldLevel.rawValue - 2)
        old.level = sentinelLevel
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: new)
        #expect(old.level == sentinelLevel, "Finished transitions must not retake window ordering")
    }

    @Test("Screen: a reveal keeps the old session until it ends, then cleans it up")
    func screenRevealCleansUpAtTheEnd() throws {
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.weave), clock: clock)
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        #expect(old.cleanupCallCount == 0)
        #expect(screen.revealTransitions.count == 1)
        #expect(old.wallpaperWindow?.contentView?.layer?.mask != nil)

        clock.fire(0)
        clock.fire(WallpaperRevealEffect.weave.duration)
        #expect(old.cleanupCallCount == 1)
        #expect(screen.revealTransitions.isEmpty)
        #expect(new.cleanupCallCount == 0)
    }

    @Test("Screen: removing the display mid-reveal tears everything down at once")
    func screenResetFlushesReveal() throws {
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.aurora), clock: clock)
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)
        let transition = try #require(screen.revealTransitions.values.first)
        let light = try #require(transition.lightWindow)
        clock.fire(0)
        clock.fire(0.3)

        screen.resetRuntimeSession()

        #expect(old.cleanupCallCount == 1)
        #expect(new.cleanupCallCount == 1)
        #expect(screen.revealTransitions.isEmpty)
        #expect(transition.isFinished)
        #expect(!light.isVisible)
        #expect(!clock.isRunning)
    }

    @Test("Screen: a refreshed screen adopting the session ends the old screen's reveal")
    func screenAdoptionFlushesReveal() throws {
        let clock = ManualTransitionClock()
        let original = try makeScreen(plan: .reveal(.meteor), clock: clock)
        let old = TransitionTestSession(window: makeWallpaperWindow())
        let new = TransitionTestSession(window: makeWallpaperWindow())
        original.installRuntimeSession(old)
        original.installRuntimeSession(new)
        let refreshed = try Screen(nsScreen: #require(NSScreen.screens.first))
        defer { refreshed.resetRuntimeSession() }

        refreshed.adoptRuntimeSession(from: original)

        #expect(old.cleanupCallCount == 1)
        #expect(original.revealTransitions.isEmpty)
        #expect((refreshed.runtimeSession as AnyObject?) === new)
    }

    @Test("Screen: a second swap mid-reveal ends the first reveal before starting the next")
    func screenSecondSwapInterruptsReveal() throws {
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .reveal(.meteor), clock: clock)
        let first = TransitionTestSession(window: makeWallpaperWindow())
        let second = TransitionTestSession(window: makeWallpaperWindow())
        let third = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(first)
        screen.installRuntimeSession(second)
        clock.fire(0)
        clock.fire(0.2)

        screen.installRuntimeSession(third)

        #expect(first.cleanupCallCount == 1)
        #expect(first.wallpaperWindow?.contentView?.layer?.mask == nil)
        #expect(second.cleanupCallCount == 0)
        #expect(screen.revealTransitions.count == 1)
        #expect(second.wallpaperWindow?.contentView?.layer?.mask != nil)
    }

    @Test("Screen: None attaches nothing and closes the old wallpaper at once")
    func screenNoneClosesImmediately() throws {
        let clock = ManualTransitionClock()
        let screen = try makeScreen(plan: .none, clock: clock)
        let oldWindow = makeWallpaperWindow()
        let old = TransitionTestSession(window: oldWindow)
        let new = TransitionTestSession(window: makeWallpaperWindow())
        defer { screen.resetRuntimeSession() }
        screen.installRuntimeSession(old)
        screen.installRuntimeSession(new)

        #expect(old.cleanupCallCount == 1)
        #expect(!oldWindow.isVisible)
        #expect(oldWindow.contentView?.layer?.mask == nil)
        #expect(screen.revealTransitions.isEmpty)
        #expect(!clock.isRunning)
    }

    @Test("Reduce Motion turns every animated choice into the crossfade and leaves None alone")
    func reduceMotionFallsBackToCrossfade() {
        var generator = SystemRandomNumberGenerator()
        for choice in WallpaperTransitionChoice.allCases {
            let plan = WallpaperTransitionPlan.resolve(choice, reduceMotion: true, using: &generator)
            #expect(plan == (choice == .none ? .none : .crossfade), "\(choice.rawValue) → \(plan)")
        }
        #expect(WallpaperTransitionPlan.resolve(.meteor, reduceMotion: false, using: &generator) == .reveal(.meteor))
        #expect(WallpaperTransitionPlan.resolve(.crossfade, reduceMotion: false, using: &generator) == .crossfade)
    }

    @Test("Random draws only from the crossfade and the five reveals, and reaches each of them")
    func randomStaysInsideItsPool() {
        var generator = SystemRandomNumberGenerator()
        var seen: [WallpaperTransitionPlan] = []
        for _ in 0 ..< 300 {
            let plan = WallpaperTransitionPlan.resolve(.random, reduceMotion: false, using: &generator)
            #expect(WallpaperTransitionPlan.randomPool.contains(plan), "\(plan) is outside the random pool")
            if !seen.contains(plan) {
                seen.append(plan)
            }
        }
        #expect(seen.count == 6)
        #expect(WallpaperTransitionPlan.randomPool.count == 6)
        #expect(!WallpaperTransitionPlan.randomPool.contains(.none))
    }
}

@Suite("Wallpaper transition setting")
@MainActor
struct WallpaperTransitionSettingTests {
    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "WallpaperTransitionSettingTests.\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: name)), name)
    }

    @Test("An unset or unknown value reads as the crossfade")
    func defaultIsCrossfade() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WallpaperTransitionChoice.defaultChoice == .crossfade)
        #expect(WallpaperTransitionChoice.stored(in: defaults) == .crossfade)
        defaults.set("cover-flow", forKey: WallpaperTransitionChoice.defaultsKey)
        #expect(WallpaperTransitionChoice.stored(in: defaults) == .crossfade)
    }

    @Test("Every choice round-trips through the stored key", arguments: WallpaperTransitionChoice.allCases)
    func choicePersists(choice: WallpaperTransitionChoice) throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(choice.rawValue, forKey: WallpaperTransitionChoice.defaultsKey)
        #expect(WallpaperTransitionChoice.stored(in: defaults) == choice)
    }

    @Test("Settings search finds the row in Chinese and English", arguments: ["换壁纸动画", "Wallpaper transition", "transition"])
    func searchFindsTheRow(query: String) {
        let result = SettingsNavigation.filteredResults(matching: query, capabilities: .pro)
            .first { $0.destination == .general }
        #expect(result?.anchor == .generalWallpaper, "`\(query)` lands on \(result?.anchor?.rawValue ?? "nothing")")
    }
}
