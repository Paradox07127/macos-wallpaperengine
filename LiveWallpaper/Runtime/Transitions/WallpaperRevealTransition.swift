import AppKit
import LiveWallpaperCore
import Metal
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

/// What `Screen` needs to run a transition; tests replace any of its parts.
struct WallpaperTransitionEnvironment {
    var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var lowPowerMode: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var plan: @MainActor (_ reduceMotion: Bool, _ lowPower: Bool) -> WallpaperTransitionPlan = {
        WallpaperTransitionPlan.current(reduceMotion: $0, lowPower: $1)
    }

    var makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock = { DisplayLinkTransitionClock(window: $0) }
    var renderer: @MainActor () -> (any WallpaperTransitionRendering)? = { WallpaperTransitionRenderer.shared }
    var distortionRenderer: @MainActor () -> (any WallpaperDistortionRendering)? = { WallpaperDistortionRenderer.shared }
}

/// Cuts the outgoing wallpaper window away with a Metal-drawn layer mask while an overlay window
/// draws the effect's light on top. The incoming wallpaper is already live underneath.
@MainActor
final class WallpaperRevealTransition {
    let effect: WallpaperRevealEffect
    let duration: TimeInterval
    private let shaders: WallpaperMaskShaders
    private let oldWindow: NSWindow
    private let originalOldWindowLevel: NSWindow.Level
    private weak var newWindow: NSWindow?
    private let renderer: any WallpaperTransitionRendering
    private let clock: any WallpaperTransitionClock
    private let onFinish: @MainActor () -> Void
    private var uniforms: WallpaperTransitionUniforms
    private var startTime: CFTimeInterval?
    private let finishDeadline: Duration
    private var deadlineTask: Task<Void, Never>?
    private var orderFrontObserver: NSObjectProtocol?

    private(set) var maskLayer: CAMetalLayer?
    private(set) var lightWindow: NSWindow?
    private var lightLayer: CAMetalLayer?
    private(set) var isFinished = false

    /// nil when there is nothing to mask or no Metal renderer; the caller falls back to the crossfade.
    init?(
        effect: WallpaperRevealEffect,
        pace: WallpaperTransitionPace = .manual,
        oldWindow: NSWindow,
        newWindow: NSWindow?,
        renderer: (any WallpaperTransitionRendering)? = WallpaperTransitionRenderer.shared,
        makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock,
        finishDeadline: Duration? = nil,
        onFinish: @escaping @MainActor () -> Void
    ) {
        guard let renderer, let contentView = oldWindow.contentView, contentView.bounds.height > 0 else {
            return nil
        }
        self.effect = effect
        shaders = WallpaperMaskShaders(mask: effect.maskFunctionName, light: effect.lightFunctionName)
        duration = effect.duration * pace.durationScale
        self.oldWindow = oldWindow
        originalOldWindowLevel = oldWindow.level
        self.newWindow = newWindow
        self.renderer = renderer
        clock = makeClock(oldWindow)
        self.onFinish = onFinish
        self.finishDeadline = finishDeadline ?? .seconds(duration + 0.5)
        uniforms = WallpaperTransitionUniforms(
            progress: 0,
            time: 0,
            aspect: Float(contentView.bounds.width / contentView.bounds.height),
            seed: Float.random(in: 0 ..< 1),
            origin: SIMD2(Float.random(in: 0.15 ... 0.85), Float.random(in: 0.15 ... 0.85))
        )
    }

    /// false publishes no mask, light window, or ordering change; Screen can crossfade.
    @discardableResult
    func start() -> Bool {
        guard !isFinished, maskLayer == nil,
              let contentView = oldWindow.contentView,
              contentView.bounds.width.isFinite, contentView.bounds.height.isFinite,
              contentView.bounds.width > 0, contentView.bounds.height > 0,
              renderer.prepare(shaders) else { return false }
        contentView.wantsLayer = true
        guard let host = contentView.layer else { return false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let mask = Self.makeMaskLayer(device: renderer.device, host: host, backingScale: oldWindow.backingScaleFactor)
        guard draw(.mask, in: mask) else { return false }
        // Stage both first draws before publishing either owner property.
        if effect.lightFunctionName != nil, !installLightWindow() {
            return false
        }
        host.mask = mask
        maskLayer = mask

        // Ink has no light window, but its masked content needs the same order.
        orderFrontObserver = NotificationCenter.default.addObserver(
            forName: VideoWallpaperWindow.didOrderFrontNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let object = notification.object else { return }
            let identity = ObjectIdentifier(object as AnyObject)
            MainActor.assumeIsolated {
                guard let self,
                      identity == ObjectIdentifier(self.oldWindow)
                      || identity == self.newWindow.map(ObjectIdentifier.init) else { return }
                self.restackContentAndLight()
            }
        }
        restackContentAndLight()
        let deadline = finishDeadline
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.finish()
        }
        clock.start { [weak self] time in
            self?.advance(to: time)
        }
        return true
    }

    private func draw(_ pass: WallpaperTransitionRenderer.Pass, in layer: CAMetalLayer) -> Bool {
        renderer.draw(pass, shaders: shaders, uniforms: uniforms, in: layer) { [weak self] in
            // Completion runs later on MainActor; finish is also the cancellation
            // path and is idempotent if another command failed or the deadline won.
            guard let self, maskLayer != nil else { return }
            finish()
        }
    }

    func advance(to time: CFTimeInterval) {
        guard !isFinished else { return }
        let start = startTime ?? time
        startTime = start
        let elapsed = time - start
        uniforms.progress = Float(min(1, elapsed / duration))
        uniforms.time = Float(elapsed)
        if let maskLayer, !draw(.mask, in: maskLayer) {
            finish()
            return
        }
        if let lightLayer, !draw(.light, in: lightLayer) {
            finish()
            return
        }
        if uniforms.progress >= 1 {
            finish()
        }
    }

    /// Idempotent. Removes the mask and the light overlay, then hands the old session back for cleanup.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        deadlineTask?.cancel()
        deadlineTask = nil
        clock.stop()
        if let orderFrontObserver {
            NotificationCenter.default.removeObserver(orderFrontObserver)
        }
        orderFrontObserver = nil
        // Hidden before the mask goes: removing it first would show the whole old frame again until the window closes.
        oldWindow.alphaValue = 0
        oldWindow.level = originalOldWindowLevel
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

    private func installLightWindow() -> Bool {
        let (window, layer) = Self.makeLightWindow(
            frame: oldWindow.frame,
            level: Self.overlayLevel(above: [oldWindow, newWindow].compactMap(\.self)),
            device: renderer.device
        )
        guard draw(.light, in: layer) else {
            window.close()
            return false
        }
        lightWindow = window
        lightLayer = layer
        return true
    }

    /// Raising only the light leaves a passive old wallpaper hidden behind an
    /// interactive incoming one. Keep the masked content above the incoming
    /// content without raising either above desktop widgets or taking focus.
    private func restackContentAndLight() {
        guard !isFinished else { return }
        oldWindow.ignoresMouseEvents = true
        oldWindow.acceptsMouseMovedEvents = false
        oldWindow.level = NSWindow.Level(rawValue: max(
            originalOldWindowLevel.rawValue, newWindow?.level.rawValue ?? originalOldWindowLevel.rawValue
        ))
        if let newWindow, newWindow !== oldWindow {
            oldWindow.order(.above, relativeTo: newWindow.windowNumber)
        }
        if let lightWindow {
            lightWindow.level = Self.overlayLevel(above: [oldWindow, newWindow].compactMap(\.self))
            lightWindow.orderFrontRegardless()
        }
    }

    /// Share the highest wallpaper level; ordering places the light above its content, below higher-level widgets.
    static func overlayLevel(above windows: [NSWindow]) -> NSWindow.Level {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        return NSWindow.Level(rawValue: windows.map(\.level.rawValue).reduce(desktop, max))
    }

    /// Half resolution; presents inside the caller's CATransaction so it lands with the attach.
    static func makeMaskLayer(device: MTLDevice, host: CALayer, backingScale: CGFloat) -> CAMetalLayer {
        let mask = makeMetalLayer(device: device, size: host.bounds.size, scale: backingScale * 0.5)
        mask.presentsWithTransaction = true
        mask.frame = host.bounds
        return mask
    }

    /// A click-through, transparent overlay covering `frame`; not yet ordered in.
    static func makeLightWindow(frame: NSRect, level: NSWindow.Level, device: MTLDevice) -> (NSWindow, CAMetalLayer) {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.sharingType = WallpaperCapturePolicy.windowSharingType
        window.level = level

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let layer = makeMetalLayer(device: device, size: frame.size, scale: window.backingScaleFactor)
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        return (window, layer)
    }

    private static func makeMetalLayer(device: MTLDevice, size: CGSize, scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = WallpaperTransitionRenderer.pixelFormat
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        return layer
    }
}
