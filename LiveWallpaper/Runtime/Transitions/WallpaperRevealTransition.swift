import AppKit
import LiveWallpaperCore
import QuartzCore

@MainActor
protocol WallpaperTransitionClock: AnyObject {
    /// `tick` receives the time, in seconds, the next frame will reach the display.
    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void)
    func stop()
}

@MainActor
final class DisplayLinkTransitionClock: WallpaperTransitionClock {
    private let window: NSWindow
    private var link: CADisplayLink?
    private var target: Target?

    init(window: NSWindow) {
        self.window = window
    }

    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        let target = Target(tick: tick)
        let link = window.displayLink(target: target, selector: #selector(Target.step(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        target = nil
    }

    @MainActor
    private final class Target: NSObject {
        private let tick: @MainActor (CFTimeInterval) -> Void

        init(tick: @escaping @MainActor (CFTimeInterval) -> Void) {
            self.tick = tick
        }

        @objc nonisolated func step(_ link: CADisplayLink) {
            let timestamp = link.targetTimestamp
            MainActor.assumeIsolated { tick(timestamp) }
        }
    }
}

/// What `Screen` needs to run a transition; tests replace both parts.
struct WallpaperTransitionEnvironment {
    var plan: @MainActor () -> WallpaperTransitionPlan = { WallpaperTransitionPlan.current() }
    var makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock = { DisplayLinkTransitionClock(window: $0) }
}

/// Cuts the outgoing wallpaper window away with a Metal-drawn layer mask while an overlay window
/// draws the effect's light on top. The incoming wallpaper is already live underneath.
@MainActor
final class WallpaperRevealTransition {
    let effect: WallpaperRevealEffect
    private let oldWindow: NSWindow
    private weak var newWindow: NSWindow?
    private let renderer: WallpaperTransitionRenderer
    private let clock: any WallpaperTransitionClock
    private let onFinish: @MainActor () -> Void
    private var uniforms: WallpaperTransitionUniforms
    private var startTime: CFTimeInterval?
    private var orderFrontObserver: NSObjectProtocol?

    private(set) var maskLayer: CAMetalLayer?
    private(set) var lightWindow: NSWindow?
    private var lightLayer: CAMetalLayer?
    private(set) var isFinished = false

    /// nil when there is nothing to mask or no Metal renderer; the caller falls back to the crossfade.
    init?(
        effect: WallpaperRevealEffect,
        oldWindow: NSWindow,
        newWindow: NSWindow?,
        renderer: WallpaperTransitionRenderer? = .shared,
        makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock,
        onFinish: @escaping @MainActor () -> Void
    ) {
        guard let renderer, let contentView = oldWindow.contentView, contentView.bounds.height > 0 else {
            return nil
        }
        self.effect = effect
        self.oldWindow = oldWindow
        self.newWindow = newWindow
        self.renderer = renderer
        clock = makeClock(oldWindow)
        self.onFinish = onFinish
        uniforms = WallpaperTransitionUniforms(
            progress: 0,
            time: 0,
            aspect: Float(contentView.bounds.width / contentView.bounds.height),
            seed: Float.random(in: 0 ..< 1),
            origin: SIMD2(Float.random(in: 0.15 ... 0.85), Float.random(in: 0.15 ... 0.85))
        )
    }

    func start() {
        guard let contentView = oldWindow.contentView else { return }
        contentView.wantsLayer = true
        guard let host = contentView.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Soft-edged, so half resolution is enough; Core Animation scales it back up.
        let mask = makeMetalLayer(size: host.bounds.size, scale: oldWindow.backingScaleFactor * 0.5)
        mask.presentsWithTransaction = true
        mask.frame = host.bounds
        renderer.draw(.mask, effect: effect, uniforms: uniforms, in: mask)
        host.mask = mask
        maskLayer = mask
        CATransaction.commit()

        if effect.lightFunctionName != nil {
            installLightWindow()
        }
        clock.start { [weak self] time in
            self?.advance(to: time)
        }
    }

    func advance(to time: CFTimeInterval) {
        guard !isFinished else { return }
        let start = startTime ?? time
        startTime = start
        let elapsed = time - start
        uniforms.progress = Float(min(1, elapsed / effect.duration))
        uniforms.time = Float(elapsed)
        if let maskLayer {
            renderer.draw(.mask, effect: effect, uniforms: uniforms, in: maskLayer)
        }
        if let lightLayer {
            renderer.draw(.light, effect: effect, uniforms: uniforms, in: lightLayer)
        }
        if uniforms.progress >= 1 {
            finish()
        }
    }

    /// Idempotent. Removes the mask and the light overlay, then hands the old session back for cleanup.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        clock.stop()
        if let orderFrontObserver {
            NotificationCenter.default.removeObserver(orderFrontObserver)
        }
        orderFrontObserver = nil
        // Hidden before the mask goes: removing it first would show the whole old frame again until the window closes.
        oldWindow.alphaValue = 0
        if let host = oldWindow.contentView?.layer, host.mask === maskLayer {
            host.mask = nil
        }
        maskLayer = nil
        lightLayer = nil
        lightWindow?.orderOut(nil)
        lightWindow?.close()
        lightWindow = nil
        onFinish()
    }

    private func installLightWindow() {
        let frame = oldWindow.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.sharingType = WallpaperCapturePolicy.windowSharingType
        window.level = Self.overlayLevel(above: [oldWindow, newWindow].compactMap(\.self))

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let layer = makeMetalLayer(size: frame.size, scale: window.backingScaleFactor)
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        renderer.draw(.light, effect: effect, uniforms: uniforms, in: layer)
        lightWindow = window
        lightLayer = layer

        window.orderFrontRegardless()
        // An interactive wallpaper shares this level and orders itself front whenever its policy is reapplied.
        orderFrontObserver = NotificationCenter.default.addObserver(
            forName: VideoWallpaperWindow.didOrderFrontNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lightWindow?.orderFrontRegardless() }
        }
    }

    /// One level above passive wallpapers (still under the desktop icons); level with interactive ones.
    static func overlayLevel(above windows: [NSWindow]) -> NSWindow.Level {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        return NSWindow.Level(rawValue: windows.map(\.level.rawValue).reduce(desktop, max))
    }

    private func makeMetalLayer(size: CGSize, scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = WallpaperTransitionRenderer.pixelFormat
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        return layer
    }
}
