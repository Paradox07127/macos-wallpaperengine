import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
private final class ManualOpeningClock: WallpaperTransitionClock {
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
private final class ScriptedOpeningRenderer: WallpaperTransitionRendering {
    let device: MTLDevice
    var isPrepared = true
    var submissions: [Bool] = []
    private(set) var failures: [@MainActor @Sendable () -> Void] = []

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    func prepare(_: WallpaperMaskShaders) -> Bool {
        isPrepared
    }

    func draw(_: WallpaperTransitionRenderer.Pass, shaders _: WallpaperMaskShaders,
              uniforms _: WallpaperTransitionUniforms, in _: CAMetalLayer,
              onFailure: @escaping @MainActor @Sendable () -> Void) -> Bool {
        failures.append(onFailure)
        return submissions.isEmpty ? true : submissions.removeFirst()
    }
}

@Suite("Wallpaper opening transition", .serialized)
@MainActor
struct WallpaperOpeningTransitionTests {
    enum Opening: String, CaseIterable, Sendable {
        case loom = "Loom"
        case frame = "Frame"
        case dawn = "Dawn"

        var shaders: WallpaperMaskShaders {
            WallpaperMaskShaders(mask: "wallpaperOpening\(rawValue)Mask", light: "wallpaperOpening\(rawValue)Light")
        }

        var duration: TimeInterval {
            switch self {
            case .loom: 2.6
            case .frame: 2.4
            case .dawn: 2.8
            }
        }
    }

    /// Parks itself off every display in the test host; starts hidden like a freshly prepared wallpaper.
    private func makeWallpaperWindow() -> VideoWallpaperWindow {
        let window = VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        window.alphaValue = 0
        return window
    }

    private func makeOpening(
        _ opening: Opening = .loom,
        window: NSWindow,
        renderer: (any WallpaperTransitionRendering)?,
        clock: ManualOpeningClock,
        finishDeadline: Duration? = nil,
        onFinish: @escaping @MainActor () -> Void = {}
    ) -> WallpaperOpeningTransition? {
        WallpaperOpeningTransition(
            shaders: opening.shaders, duration: opening.duration, window: window, renderer: renderer,
            makeClock: { _ in clock }, finishDeadline: finishDeadline, onFinish: onFinish
        )
    }

    @Test("Starting masks the new window, shows it, and puts the light overlay at or above its level")
    func startAttachesMaskAndLight() throws {
        let window = makeWallpaperWindow()
        defer { window.close() }
        let clock = ManualOpeningClock()
        let opening = try #require(makeOpening(window: window, renderer: WallpaperTransitionRenderer.shared, clock: clock))
        defer { opening.finish() }

        #expect(opening.start())

        let mask = try #require(opening.maskLayer)
        #expect(window.contentView?.layer?.mask === mask)
        let light = try #require(opening.lightWindow)
        #expect(light.isVisible && light.ignoresMouseEvents)
        #expect(light.level.rawValue >= window.level.rawValue)
        #expect(window.alphaValue == 1)
        #expect(clock.isRunning)
    }

    @Test("Each opening starts with the real shaders and finishes once at its duration", arguments: Opening.allCases)
    func openingRunsToItsEnd(opening: Opening) throws {
        let window = makeWallpaperWindow()
        defer { window.close() }
        let clock = ManualOpeningClock()
        var finished = 0
        let transition = try #require(makeOpening(
            opening, window: window, renderer: WallpaperTransitionRenderer.shared, clock: clock
        ) { finished += 1 })
        #expect(transition.start())
        let light = try #require(transition.lightWindow)

        clock.fire(100)
        clock.fire(100 + opening.duration / 2)
        #expect(finished == 0 && window.contentView?.layer?.mask != nil)

        clock.fire(100 + opening.duration)
        #expect(finished == 1 && transition.isFinished && !clock.isRunning)
        #expect(window.contentView?.layer?.mask == nil && transition.maskLayer == nil)
        #expect(transition.lightWindow == nil && !light.isVisible)
        #expect(window.alphaValue == 1)

        transition.finish()
        clock.fire(200)
        #expect(finished == 1 && window.alphaValue == 1 && window.contentView?.layer?.mask == nil)
    }

    @Test("A display that never ticks still finishes at the deadline", .timeLimit(.minutes(1)))
    func deadlineFinishesWithoutTicks() async throws {
        let renderer = try ScriptedOpeningRenderer()
        let window = makeWallpaperWindow()
        defer { window.close() }
        let clock = ManualOpeningClock()
        var finished = 0
        let opening = try #require(makeOpening(
            window: window, renderer: renderer, clock: clock, finishDeadline: .milliseconds(30)
        ) { finished += 1 })
        #expect(opening.start())
        let timeout = ContinuousClock.now.advanced(by: .seconds(1))
        while !opening.isFinished, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opening.isFinished && finished == 1 && !clock.isRunning)
        #expect(window.contentView?.layer?.mask == nil && opening.lightWindow == nil && window.alphaValue == 1)
    }

    @Test("A GPU failure finishes once and shows the wallpaper whole")
    func gpuFailureFinishesOnce() throws {
        let renderer = try ScriptedOpeningRenderer()
        let window = makeWallpaperWindow()
        defer { window.close() }
        let clock = ManualOpeningClock()
        var finished = 0
        let opening = try #require(makeOpening(window: window, renderer: renderer, clock: clock) { finished += 1 })
        #expect(opening.start())
        let failure = try #require(renderer.failures.first)
        failure()
        #expect(opening.isFinished && finished == 1 && !clock.isRunning)
        #expect(window.contentView?.layer?.mask == nil && opening.lightWindow == nil && window.alphaValue == 1)
        renderer.failures.forEach { $0() }
        #expect(finished == 1)
    }

    @Test("A failed prepare, mask draw or light draw leaves the window hidden and attaches nothing",
          arguments: [0, 1, 2])
    func rejectedStartLeavesNothingAttached(failure: Int) throws {
        let renderer = try ScriptedOpeningRenderer()
        renderer.isPrepared = failure != 0
        renderer.submissions = failure == 1 ? [false] : [true, false]
        let window = makeWallpaperWindow()
        defer { window.close() }
        let clock = ManualOpeningClock()
        let opening = try #require(makeOpening(window: window, renderer: renderer, clock: clock) {
            Issue.record("A rejected start must not finish")
        })
        #expect(!opening.start())
        #expect(window.alphaValue == 0)
        #expect(window.contentView?.layer?.mask == nil)
        #expect(opening.maskLayer == nil && opening.lightWindow == nil && !clock.isRunning)
        renderer.failures.forEach { $0() }
        #expect(window.alphaValue == 0)
    }

    @Test("No renderer or an empty content view declines at init")
    func initDeclines() throws {
        let window = makeWallpaperWindow()
        defer { window.close() }
        #expect(makeOpening(window: window, renderer: nil, clock: ManualOpeningClock()) == nil)
        let empty = ParkedTestWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        empty.isReleasedWhenClosed = false
        empty.alphaValue = 0
        defer { empty.close() }
        let renderer = try ScriptedOpeningRenderer()
        #expect(makeOpening(window: empty, renderer: renderer, clock: ManualOpeningClock()) == nil)
        #expect(window.alphaValue == 0 && empty.alphaValue == 0)
    }

    @Test("Over an interactive wallpaper the light overlay returns on top after it orders front")
    func overlayRestacksAboveWallpaper() throws {
        let window = makeWallpaperWindow()
        defer { window.close() }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        let opening = try #require(makeOpening(
            window: window, renderer: WallpaperTransitionRenderer.shared, clock: ManualOpeningClock()
        ))
        defer { opening.finish() }
        #expect(opening.start())
        let light = try #require(opening.lightWindow)
        let level = window.level

        window.orderFrontRegardless()
        // Control: without the notification the wallpaper now sits above the overlay.
        #expect(window.orderedIndex < light.orderedIndex)
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: window)
        #expect(light.orderedIndex < window.orderedIndex)
        #expect(window.level == level)
    }
}
