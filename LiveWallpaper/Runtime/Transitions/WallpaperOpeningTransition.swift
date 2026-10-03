import AppKit
import LiveWallpaperCore
import QuartzCore

/// Uncovers a freshly prepared wallpaper window with a Metal-drawn layer mask while an overlay
/// window darkens the still-covered desktop and draws the light.
@MainActor
final class WallpaperOpeningTransition {
    let shaders: WallpaperMaskShaders
    let duration: TimeInterval
    private let window: NSWindow
    private let renderer: any WallpaperTransitionRendering
    private let makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock
    private var clock: (any WallpaperTransitionClock)?
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

    /// nil when there is nothing to mask or no Metal renderer; the caller fades the window in instead.
    init?(
        shaders: WallpaperMaskShaders,
        duration: TimeInterval,
        window: NSWindow,
        renderer: (any WallpaperTransitionRendering)?,
        makeClock: @escaping @MainActor (NSWindow) -> any WallpaperTransitionClock,
        finishDeadline: Duration? = nil,
        onFinish: @escaping @MainActor () -> Void
    ) {
        guard let renderer, let contentView = window.contentView,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return nil }
        self.shaders = shaders
        self.duration = duration
        self.window = window
        self.renderer = renderer
        self.makeClock = makeClock
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

    /// false attaches no mask or light window and leaves `alphaValue` untouched.
    @discardableResult
    func start() -> Bool {
        guard !isFinished, maskLayer == nil,
              let contentView = window.contentView,
              contentView.bounds.width > 0, contentView.bounds.height > 0,
              renderer.prepare(shaders) else { return false }
        contentView.wantsLayer = true
        guard let host = contentView.layer else { return false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = WallpaperRevealTransition.makeMaskLayer(
            device: renderer.device, host: host, backingScale: window.backingScaleFactor
        )
        let attached = draw(.mask, in: mask) && (shaders.light == nil || installLightWindow())
        if attached {
            host.mask = mask
            maskLayer = mask
        }
        CATransaction.commit()
        guard attached else { return false }
        // Window alpha does not ride the CA transaction; raised before the commit it can show one unmasked frame.
        window.alphaValue = 1

        orderFrontObserver = NotificationCenter.default.addObserver(
            forName: VideoWallpaperWindow.didOrderFrontNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let object = notification.object else { return }
            let identity = ObjectIdentifier(object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, identity == ObjectIdentifier(self.window) else { return }
                self.restackLight()
            }
        }
        restackLight()
        let deadline = finishDeadline
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.finish()
        }
        // The wallpaper window has only just left alpha 0, so its own display link is not relied on.
        let clock = makeClock(lightWindow ?? window)
        self.clock = clock
        clock.start { [weak self] time in
            self?.advance(to: time)
        }
        return true
    }

    private func draw(_ pass: WallpaperTransitionRenderer.Pass, in layer: CAMetalLayer) -> Bool {
        renderer.draw(pass, shaders: shaders, uniforms: uniforms, in: layer) { [weak self] in
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

    /// Idempotent. Leaves the wallpaper fully shown and closes the light overlay.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        deadlineTask?.cancel()
        deadlineTask = nil
        clock?.stop()
        if let orderFrontObserver {
            NotificationCenter.default.removeObserver(orderFrontObserver)
        }
        orderFrontObserver = nil
        if let host = window.contentView?.layer, host.mask === maskLayer {
            host.mask = nil
        }
        window.alphaValue = 1
        maskLayer = nil
        lightLayer = nil
        lightWindow?.orderOut(nil)
        lightWindow?.close()
        lightWindow = nil
        onFinish()
    }

    private func installLightWindow() -> Bool {
        let (lightWindow, layer) = WallpaperRevealTransition.makeLightWindow(
            frame: window.frame,
            level: WallpaperRevealTransition.overlayLevel(above: [window]),
            device: renderer.device
        )
        guard draw(.light, in: layer) else {
            lightWindow.close()
            return false
        }
        self.lightWindow = lightWindow
        lightLayer = layer
        return true
    }

    private func restackLight() {
        guard !isFinished, let lightWindow else { return }
        lightWindow.level = WallpaperRevealTransition.overlayLevel(above: [window])
        lightWindow.orderFrontRegardless()
    }
}

struct WallpaperOpeningClaim {
    let effect: WallpaperOpeningEffect
    let barrier: WallpaperStartBarrier
}

/// The displays present at launch, each allowed to play the launch opening once.
@MainActor
final class WallpaperOpeningBatch {
    let barrier: WallpaperStartBarrier
    private let effect: WallpaperOpeningEffect
    private var unclaimed: Set<CGDirectDisplayID>
    private let deadline: ContinuousClock.Instant
    private let now: () -> ContinuousClock.Instant

    init(
        displayIDs: Set<CGDirectDisplayID>,
        effect: WallpaperOpeningEffect,
        lifetime: Duration = .seconds(60),
        barrier: WallpaperStartBarrier = WallpaperStartBarrier(),
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.effect = effect
        self.barrier = barrier
        unclaimed = displayIDs
        self.now = now
        deadline = now().advanced(by: lifetime)
    }

    /// nil when the display was not present at launch, already claimed, or the lifetime has passed.
    func claim(_ displayID: CGDirectDisplayID) -> WallpaperOpeningClaim? {
        guard now() <= deadline, unclaimed.remove(displayID) != nil else { return nil }
        return WallpaperOpeningClaim(effect: effect, barrier: barrier)
    }
}
