import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
private final class ManualDistortionClock: WallpaperTransitionClock {
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

/// The window `makeClock` was handed.
@MainActor
private final class ClockWindowRecorder {
    var window: NSWindow?
}

/// Prepares through the real renderer (`Prepared` cannot be built outside it) and scripts each draw's result.
@MainActor
private final class ScriptedDistortionRenderer: WallpaperDistortionRendering {
    let real: WallpaperDistortionRenderer
    var draws: [Bool] = []
    private(set) var failures: [@MainActor @Sendable () -> Void] = []

    var device: MTLDevice {
        real.device
    }

    init() throws {
        real = try #require(WallpaperDistortionRenderer.shared)
    }

    func prepare(
        _ effect: WallpaperDistortionEffect,
        from: MTLTexture,
        to: MTLTexture,
        seed: Float,
        origin: SIMD2<Float>,
        pixelFormat: MTLPixelFormat
    ) -> WallpaperDistortionRenderer.Prepared? {
        real.prepare(effect, from: from, to: to, seed: seed, origin: origin, pixelFormat: pixelFormat)
    }

    func draw(_: WallpaperDistortionRenderer.Prepared, progress _: Float, time _: Float, in _: CAMetalLayer,
              onFailure: @escaping @MainActor @Sendable () -> Void) -> Bool {
        failures.append(onFailure)
        return draws.isEmpty ? true : draws.removeFirst()
    }
}

@Suite("Wallpaper distortion transition", .serialized)
@MainActor
struct WallpaperDistortionTransitionTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeCapture(
        width: Int = 96,
        height: Int = 54,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        color: MTLClearColor = MTLClearColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1),
        colorSpace: CGColorSpace? = WallpaperDistortionTransitionTests.sRGB,
        isEDR: Bool = false
    ) throws -> WallpaperFrameCapture {
        let device = try #require(WallpaperDistortionRenderer.shared?.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
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
        return WallpaperFrameCapture(texture: texture, colorSpace: colorSpace, isEDR: isEDR)
    }

    /// Parks itself off every display in the test host.
    private func makeWallpaperWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
    }

    private func makeTransition(
        _ effect: WallpaperDistortionEffect = .ripple,
        pace: WallpaperTransitionPace = .manual,
        from: WallpaperFrameCapture? = nil,
        to: WallpaperFrameCapture? = nil,
        oldWindow: NSWindow,
        newWindow: NSWindow? = nil,
        renderer: (any WallpaperDistortionRendering)? = WallpaperDistortionRenderer.shared,
        clock: ManualDistortionClock = ManualDistortionClock(),
        clockWindow: ClockWindowRecorder? = nil,
        finishDeadline: Duration? = nil,
        onFinish: @escaping @MainActor () -> Void = {}
    ) throws -> WallpaperDistortionTransition? {
        let from = try from ?? makeCapture()
        let to = try to ?? makeCapture(color: MTLClearColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        return WallpaperDistortionTransition(
            effect: effect, pace: pace, from: from, to: to, oldWindow: oldWindow, newWindow: newWindow,
            renderer: renderer,
            makeClock: { window in
                clockWindow?.window = window
                return clock
            },
            finishDeadline: finishDeadline, onFinish: onFinish
        )
    }

    @Test("Init declines without a renderer or with frames the composite cannot draw")
    func initDeclines() throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        #expect(try makeTransition(oldWindow: old) != nil, "control: matching frames must be accepted")
        #expect(try makeTransition(oldWindow: old, renderer: nil) == nil)
        #expect(try makeTransition(from: makeCapture(width: 96), to: makeCapture(width: 64), oldWindow: old) == nil)
        #expect(try makeTransition(
            from: makeCapture(pixelFormat: .bgra8Unorm), to: makeCapture(pixelFormat: .rgba16Float), oldWindow: old
        ) == nil)
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        #expect(try makeTransition(from: makeCapture(), to: makeCapture(colorSpace: displayP3), oldWindow: old) == nil)
        #expect(try makeTransition(from: makeCapture(), to: makeCapture(colorSpace: nil), oldWindow: old) == nil)
        #expect(try makeTransition(
            from: makeCapture(pixelFormat: .rgba8Unorm), to: makeCapture(pixelFormat: .rgba8Unorm), oldWindow: old
        ) == nil)
        #expect(old.alphaValue == 1)
    }

    @Test("Starting shows a click-through composite over both wallpapers that matches the frames")
    func startShowsComposite() throws {
        let old = makeWallpaperWindow()
        let new = makeWallpaperWindow()
        defer {
            old.close()
            new.close()
        }
        new.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let from = try makeCapture(pixelFormat: .rgba16Float, colorSpace: space, isEDR: false)
        let to = try makeCapture(pixelFormat: .rgba16Float, colorSpace: space, isEDR: true)
        let clock = ManualDistortionClock()
        let clockWindow = ClockWindowRecorder()
        let transition = try #require(try makeTransition(
            from: from, to: to, oldWindow: old, newWindow: new, clock: clock, clockWindow: clockWindow
        ))
        defer { transition.finish() }

        #expect(transition.start())

        let window = try #require(transition.compositeWindow)
        #expect(window.isVisible && window.ignoresMouseEvents)
        #expect(window.level.rawValue >= old.level.rawValue && window.level.rawValue >= new.level.rawValue)
        #expect(window.frame == old.frame)
        #expect(!window.isOpaque)
        let layer = try #require(window.contentView?.layer as? CAMetalLayer)
        #expect(layer.isOpaque)
        #expect(layer.pixelFormat == .rgba16Float)
        #expect(layer.colorspace?.name == space.name)
        #expect(layer.drawableSize == CGSize(width: 96, height: 54))
        #expect(layer.wantsExtendedDynamicRangeContent)
        #expect(clockWindow.window === window && clock.isRunning)
        #expect(!transition.start(), "a second start must be refused")
    }

    @Test("Each effect draws with the real renderer and finishes once at its duration",
          arguments: WallpaperDistortionEffect.allCases)
    func effectRunsToItsEnd(effect: WallpaperDistortionEffect) throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualDistortionClock()
        var finished = 0
        var composite: NSWindow?
        var oldAlphaAtFinish: CGFloat?
        var compositeVisibleAtFinish: Bool?
        let transition = try #require(try makeTransition(effect, oldWindow: old, clock: clock) {
            finished += 1
            oldAlphaAtFinish = old.alphaValue
            compositeVisibleAtFinish = composite?.isVisible
        })
        #expect(transition.start())
        composite = transition.compositeWindow
        #expect(composite?.isVisible == true)

        clock.fire(100)
        clock.fire(100 + transition.duration / 2)
        #expect(finished == 0 && old.alphaValue == 1)

        clock.fire(100 + transition.duration)
        #expect(finished == 1 && transition.isFinished && !clock.isRunning)
        #expect(oldAlphaAtFinish == 0 && compositeVisibleAtFinish == false)
        #expect(transition.compositeWindow == nil)

        transition.finish()
        clock.fire(200)
        #expect(finished == 1)
    }

    @Test("A display that never ticks still finishes at the deadline", .timeLimit(.minutes(1)))
    func deadlineFinishesWithoutTicks() async throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualDistortionClock()
        var finished = 0
        let transition = try #require(try makeTransition(
            oldWindow: old, clock: clock, finishDeadline: .milliseconds(30)
        ) { finished += 1 })
        #expect(transition.start())
        let timeout = ContinuousClock.now.advanced(by: .seconds(1))
        while !transition.isFinished, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transition.isFinished && finished == 1 && !clock.isRunning)
        #expect(transition.compositeWindow == nil && old.alphaValue == 0)
    }

    @Test("A failed first frame starts nothing and leaves the old wallpaper as it was")
    func failedFirstDrawStartsNothing() throws {
        let renderer = try ScriptedDistortionRenderer()
        renderer.draws = [false]
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualDistortionClock()
        let transition = try #require(try makeTransition(oldWindow: old, renderer: renderer, clock: clock) {
            Issue.record("A rejected start must not finish")
        })
        #expect(!transition.start())
        #expect(transition.compositeWindow == nil && !clock.isRunning && !transition.isFinished)
        #expect(old.alphaValue == 1)
        renderer.failures.forEach { $0() }
        #expect(!transition.isFinished && old.alphaValue == 1)
    }

    @Test("A failed later frame finishes once")
    func failedLaterDrawFinishesOnce() throws {
        let renderer = try ScriptedDistortionRenderer()
        renderer.draws = [true, false]
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualDistortionClock()
        var finished = 0
        let transition = try #require(try makeTransition(oldWindow: old, renderer: renderer, clock: clock) {
            finished += 1
        })
        #expect(transition.start())
        clock.fire(100)
        #expect(finished == 1 && transition.isFinished && transition.compositeWindow == nil && old.alphaValue == 0)
        clock.fire(101)
        #expect(finished == 1)
    }

    @Test("A GPU failure reported after submission finishes once")
    func gpuFailureFinishesOnce() throws {
        let renderer = try ScriptedDistortionRenderer()
        let old = makeWallpaperWindow()
        defer { old.close() }
        let clock = ManualDistortionClock()
        var finished = 0
        let transition = try #require(try makeTransition(oldWindow: old, renderer: renderer, clock: clock) {
            finished += 1
        })
        #expect(transition.start())
        let failure = try #require(renderer.failures.first)
        failure()
        #expect(finished == 1 && transition.isFinished && !clock.isRunning && transition.compositeWindow == nil)
        renderer.failures.forEach { $0() }
        #expect(finished == 1)
    }

    @Test("The composite returns on top after either wallpaper orders front", arguments: [true, false])
    func compositeRestacksAboveWallpapers(raiseOld: Bool) throws {
        let old = makeWallpaperWindow()
        let new = makeWallpaperWindow()
        defer {
            old.close()
            new.close()
        }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        old.level = level
        new.level = level
        old.orderFrontRegardless()
        new.orderFrontRegardless()
        let transition = try #require(try makeTransition(oldWindow: old, newWindow: new))
        defer { transition.finish() }
        #expect(transition.start())
        let composite = try #require(transition.compositeWindow)
        let raised = raiseOld ? old : new

        raised.orderFrontRegardless()
        // Control: without the notification the wallpaper now sits above the composite.
        #expect(raised.orderedIndex < composite.orderedIndex)
        NotificationCenter.default.post(name: VideoWallpaperWindow.didOrderFrontNotification, object: raised)
        #expect(composite.orderedIndex < raised.orderedIndex)
        #expect(composite.level.rawValue >= level.rawValue)
    }

    @Test("Finishing before start still reports once")
    func finishBeforeStartReportsOnce() throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        var finished = 0
        let transition = try #require(try makeTransition(oldWindow: old) { finished += 1 })
        transition.finish()
        transition.finish()
        #expect(finished == 1 && !transition.start())
    }

    @Test("The automatic pace stretches the duration by half")
    func automaticPaceStretchesDuration() throws {
        let old = makeWallpaperWindow()
        defer { old.close() }
        for effect in WallpaperDistortionEffect.allCases {
            let transition = try #require(try makeTransition(effect, pace: .automatic, oldWindow: old))
            #expect(abs(transition.duration - effect.duration * 1.5) < 1e-9)
        }
    }
}
