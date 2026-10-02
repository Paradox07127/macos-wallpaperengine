import AppKit
import LiveWallpaperCore
import Metal
import QuartzCore

/// Covers both wallpapers with an overlay window that warps the frozen outgoing frame into the incoming one.
@MainActor
final class WallpaperDistortionTransition {
    let effect: WallpaperDistortionEffect
    let duration: TimeInterval
    private let from: WallpaperFrameCapture
    private let to: WallpaperFrameCapture
    private let oldWindow: NSWindow
    private weak var newWindow: NSWindow?
    private let renderer: any WallpaperDistortionRendering
    private let prepared: WallpaperDistortionRenderer.Prepared
    private let makeClock: @MainActor (NSWindow) -> any WallpaperTransitionClock
    private var clock: (any WallpaperTransitionClock)?
    private let onFinish: @MainActor () -> Void
    private var startTime: CFTimeInterval?
    private let finishDeadline: Duration
    private var deadlineTask: Task<Void, Never>?
    private var orderFrontObserver: NSObjectProtocol?

    private(set) var compositeWindow: NSWindow?
    private var compositeLayer: CAMetalLayer?
    private(set) var isFinished = false

    private static let supportedPixelFormats: Set<MTLPixelFormat> = [.bgra8Unorm, .rgba8Unorm_srgb, .rgba16Float]

    /// nil when there is no renderer or the two frames cannot be drawn together; the caller falls back to the crossfade.
    init?(
        effect: WallpaperDistortionEffect,
        pace: WallpaperTransitionPace = .manual,
        from: WallpaperFrameCapture,
        to: WallpaperFrameCapture,
        oldWindow: NSWindow,
        newWindow: NSWindow?,
        renderer: (any WallpaperDistortionRendering)?,
        makeClock: @escaping @MainActor (NSWindow) -> any WallpaperTransitionClock,
        finishDeadline: Duration? = nil,
        onFinish: @escaping @MainActor () -> Void
    ) {
        let pixelFormat = from.texture.pixelFormat
        guard let renderer,
              from.texture.width == to.texture.width, from.texture.height == to.texture.height,
              pixelFormat == to.texture.pixelFormat, Self.supportedPixelFormats.contains(pixelFormat),
              from.colorSpace?.name as String? == to.colorSpace?.name as String?,
              let prepared = renderer.prepare(
                  effect,
                  from: from.texture,
                  to: to.texture,
                  seed: Float.random(in: 0 ..< 1),
                  origin: SIMD2(Float.random(in: 0.15 ... 0.85), Float.random(in: 0.15 ... 0.85)),
                  pixelFormat: pixelFormat
              ) else { return nil }
        self.effect = effect
        duration = effect.duration * pace.durationScale
        self.from = from
        self.to = to
        self.oldWindow = oldWindow
        self.newWindow = newWindow
        self.renderer = renderer
        self.prepared = prepared
        self.makeClock = makeClock
        self.onFinish = onFinish
        self.finishDeadline = finishDeadline ?? .seconds(duration + 0.5)
    }

    /// Scenes ignore the requested format, so the scene side goes first and the other side is asked to match it.
    /// nil when either side has no frame; the second side is then not asked.
    static func captureFrames(
        old: any WallpaperRuntimeSession,
        incoming: any WallpaperRuntimeSession,
        device: any MTLDevice
    ) async -> (from: WallpaperFrameCapture, to: WallpaperFrameCapture)? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let oldFirst = old.wallpaperType == .scene || incoming.wallpaperType != .scene
        let (first, second) = oldFirst ? (old, incoming) : (incoming, old)
        guard let firstFrame = await first.captureDisplayedFrame(device: device, pixelFormat: .bgra8Unorm, colorSpace: sRGB),
              let secondFrame = await second.captureDisplayedFrame(
                  device: device,
                  pixelFormat: firstFrame.texture.pixelFormat,
                  colorSpace: firstFrame.colorSpace ?? sRGB
              ) else { return nil }
        return oldFirst ? (firstFrame, secondFrame) : (secondFrame, firstFrame)
    }

    /// false orders no window in and changes no other window's state; Screen can crossfade.
    @discardableResult
    func start() -> Bool {
        guard !isFinished, compositeWindow == nil else { return false }
        let (window, layer) = makeCompositeWindow()
        guard draw(progress: 0, time: 0, in: layer) else {
            window.close()
            return false
        }
        compositeWindow = window
        compositeLayer = layer
        window.orderFrontRegardless()

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
                self.restackComposite()
            }
        }
        let deadline = finishDeadline
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.finish()
        }
        let clock = makeClock(window)
        self.clock = clock
        clock.start { [weak self] time in
            self?.advance(to: time)
        }
        return true
    }

    func advance(to time: CFTimeInterval) {
        guard !isFinished, let compositeLayer else { return }
        let start = startTime ?? time
        startTime = start
        let elapsed = time - start
        let progress = Float(min(1, elapsed / duration))
        if !draw(progress: progress, time: Float(elapsed), in: compositeLayer) || progress >= 1 {
            finish()
        }
    }

    /// Idempotent and the only exit. Hides the old wallpaper, closes the composite, then reports.
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
        // Hidden before the composite goes: the other order would flash the old frame for one refresh.
        oldWindow.alphaValue = 0
        compositeLayer = nil
        compositeWindow?.orderOut(nil)
        compositeWindow?.close()
        compositeWindow = nil
        onFinish()
    }

    private func draw(progress: Float, time: Float, in layer: CAMetalLayer) -> Bool {
        renderer.draw(prepared, progress: progress, time: time, in: layer) { [weak self] in
            guard let self, compositeWindow != nil else { return }
            finish()
        }
    }

    private func restackComposite() {
        guard !isFinished, let compositeWindow else { return }
        compositeWindow.level = WallpaperRevealTransition.overlayLevel(above: [oldWindow, newWindow].compactMap(\.self))
        compositeWindow.orderFrontRegardless()
    }

    /// Click-through window over `oldWindow` whose layer is sized to the frames, not the window; not yet ordered in.
    private func makeCompositeWindow() -> (NSWindow, CAMetalLayer) {
        let frame = oldWindow.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Neither window nor layer may claim opacity: the old wallpaper must show through until the first frame lands. Frames are always alpha 1.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.sharingType = WallpaperCapturePolicy.windowSharingType
        window.level = WallpaperRevealTransition.overlayLevel(above: [oldWindow, newWindow].compactMap(\.self))

        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = prepared.pixelFormat
        layer.colorspace = from.colorSpace
        layer.wantsExtendedDynamicRangeContent = from.isEDR || to.isEDR
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.contentsScale = oldWindow.backingScaleFactor
        layer.drawableSize = CGSize(width: from.texture.width, height: from.texture.height)

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        return (window, layer)
    }
}
