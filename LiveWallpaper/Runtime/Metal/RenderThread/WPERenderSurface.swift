#if !LITE_BUILD
import AppKit
import MetalKit
import os
import QuartzCore

@MainActor
final class WPERenderSurface: NSObject, MTKViewDelegate {
    let mtkView: WPEInteractiveMTKView
    let mailbox: WPEPointerMailbox
    let metalLayer: CAMetalLayer

    private let publisher: WPEPointerPublisher
    /// Written synchronously (caller order); main-thread deliveries apply this latest value, not their captured one.
    private let desiredPointerEventsEnabled = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private var client: WPERenderSurfaceClient?

    // MARK: - Display-link Frame Driver
    private weak var displayLinkActor: WPEDisplayRenderActor?
    private var displayLinkTarget: WPEDisplayLinkTarget?
    private var screenParamsObserver: NSObjectProtocol?
    private var displayLinkLifecycleTask: Task<Void, Never>?
    private var displayLinkGeneration: UInt64 = 0

    init(frame: CGRect, device: MTLDevice) {
        let view = WPEInteractiveMTKView(frame: frame, device: device)
        view.wantsLayer = true
        let hdrOutput = WPEDisplayHDROutput.shouldRequestHDROutput(
            settingEnabled: WPEDisplayHDROutput.isEnabled,
            hasCapableScreen: WPEDisplayHDROutput.hasEDRCapableScreen
        )
        view.colorPixelFormat = WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: hdrOutput)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = WPEMetalSceneRenderer.defaultPreferredFPS
        view.autoresizingMask = [.width, .height]
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        guard let metalLayer = view.layer as? CAMetalLayer else {
            preconditionFailure("MTKView must be backed by a CAMetalLayer")
        }
        // MetalFX writes the drawable, so framebufferOnly is off while the experiment is on.
        metalLayer.maximumDrawableCount = 3
        metalLayer.framebufferOnly = !WPEMetalFXSpatialUpscaler.isExperimentEnabled
        WPEDisplayHDROutput.apply(to: metalLayer, hdrOutputEnabled: hdrOutput)
        let mailbox = WPEPointerMailbox()
        self.mtkView = view
        self.mailbox = mailbox
        self.metalLayer = metalLayer
        self.publisher = WPEPointerPublisher(mailbox: mailbox, view: view)
        super.init()
        view.delegate = self
        publisher.onPointerEnteredView = { [weak self] in
            self?.client?.renderAndPresentFrame()
        }
        view.onPointerFrameChange = { [mailbox] frame in
            mailbox.publishPointerFrame(frame)
        }
    }

    /// NOT `metalLayer.drawableSize`: a CAMetalLayer reports 0x0 until `nextDrawable()` (see `WPEMetalSurfaceGeometryTests`).
    var backingDrawableSize: CGSize {
        let viewSize = mtkView.drawableSize
        if viewSize.width > 0, viewSize.height > 0 { return viewSize }
        return mtkView.convertToBacking(mtkView.bounds).size
    }

    func attach(client: WPERenderSurfaceClient) {
        let size = backingDrawableSize
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        self.client = client
        publisher.start()
        client.updateSurfaceGeometry(drawableSize: size)
    }

    // MARK: - Display-link Driver Lifecycle

    func startDisplayLinkDriver(renderActor: WPEDisplayRenderActor) {
        displayLinkActor = renderActor
        displayLinkTarget = WPEDisplayLinkTarget(renderActor: renderActor)
        buildDisplayLink()
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildDisplayLink() }
        }
    }

    private func buildDisplayLink() {
        guard let renderActor = displayLinkActor,
              let target = displayLinkTarget,
              let screen = mtkView.window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: target, selector: #selector(WPEDisplayLinkTarget.step(_:)))
        let handoff = WPEDisplayLinkHandoff(link: link)
        displayLinkGeneration &+= 1
        let generation = displayLinkGeneration
        let previousTask = displayLinkLifecycleTask
        displayLinkLifecycleTask = Task { @MainActor in
            await previousTask?.value
            await renderActor.replaceDisplayLink(handoff, generation: generation)
        }
    }

    @discardableResult
    func stopDisplayLinkDriver() -> Task<Void, Never>? {
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
        screenParamsObserver = nil
        guard let renderActor = displayLinkActor else {
            return displayLinkLifecycleTask
        }

        displayLinkGeneration &+= 1
        let generation = displayLinkGeneration
        let previousTask = displayLinkLifecycleTask
        let stopTask = Task { @MainActor in
            await previousTask?.value
            await renderActor.stopDisplayLinkDriver(generation: generation)
        }
        displayLinkLifecycleTask = stopTask
        displayLinkActor = nil
        displayLinkTarget = nil
        return stopTask
    }

    // MARK: - Pacing (driven by the renderer, via `WPESurfaceControl`)

    private func applyPacingOnMain(_ update: WPERenderPacingUpdate) {
        if let paused = update.isPaused { mtkView.isPaused = paused }
        if let enable = update.enableSetNeedsDisplay { mtkView.enableSetNeedsDisplay = enable }
        if let fps = update.preferredFramesPerSecond { mtkView.preferredFramesPerSecond = fps }
        if update.pointerEventsEnabled != nil,
           let latest = desiredPointerEventsEnabled.withLock({ $0 }) {
            // Latest-wins: `deliver`'s unstructured Tasks are not FIFO, so a rapid suspend→resume pair could apply gates inverted.
            publisher.setMouseMonitoringEnabled(latest)
        }
    }

    private func setNeedsRedrawOnMain() { mtkView.setNeedsDisplay(mtkView.bounds) }

    private func drawImmediatelyOnMain() { mtkView.draw() }

    private func releaseDrawablesOnMain() { mtkView.releaseDrawables() }

    /// The per-screen Interaction toggle: the view gates event capture on it, the
    /// mailbox exposes it to the render path. Both must see the same value.
    private func setClickCaptureEnabledOnMain(_ enabled: Bool) {
        mtkView.clickCaptureEnabled = enabled
        mailbox.setClickCaptureEnabled(enabled)
    }

    private func detachOnMain() {
        stopDisplayLinkDriver()
        publisher.stop()
        mtkView.delegate = nil
        client = nil
    }

    // MARK: - MTKViewDelegate

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            self?.client?.renderAndPresentFrame()
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.client?.updateSurfaceGeometry(drawableSize: size)
            // Refresh the mailbox so the first read after layout isn't `.none`.
            self.mailbox.publishGeometry(WPEPointerPublisher.geometry(of: self.mtkView))
        }
    }
}

/// Format is settled once at surface construction: the main thread must not mutate the layer while the render actor is presenting.
enum WPEDisplayHDROutput {
    /// `defaults write com.loomscreen.pro WPEMetalDisplayHDROutputEnabled -bool YES`
    static let defaultsKey = "WPEMetalDisplayHDROutputEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    /// `maximumPotential…` is capability and is stable; `maximum…ExtendedDynamicRangeColorComponentValue` tracks current brightness and is NOT usable here.
    @MainActor
    static var hasEDRCapableScreen: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    static func drawablePixelFormat(hdrOutputEnabled: Bool) -> MTLPixelFormat {
        hdrOutputEnabled ? .rgba16Float : WPEMetalRenderExecutor.outputPixelFormat
    }

    /// The setting alone must not widen the drawable: on an all-SDR setup that pays float bandwidth for output nothing can show.
    static func shouldRequestHDROutput(settingEnabled: Bool, hasCapableScreen: Bool) -> Bool {
        settingEnabled && hasCapableScreen
    }

    /// Ask the drawable format, not the defaults key: the key can be on while the drawable stayed 8-bit, and a plan that believed the key would demote the scene to native for life.
    static func isHDROutput(drawablePixelFormat: MTLPixelFormat) -> Bool {
        drawablePixelFormat == .rgba16Float
    }

    /// Extended-range colorspace + the EDR request. Construction-time only: calling this
    /// once frames are in flight is the race `WPEPresentLayer` warns about.
    static func apply(to layer: CAMetalLayer, hdrOutputEnabled: Bool) {
        guard hdrOutputEnabled else { return }
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
    }
}

/// `@unchecked Sendable` because `CAMetalLayer` isn't `Sendable`, yet `nextDrawable()`/present
/// are documented safe off the main thread and the render actor is the layer's only present-time
/// caller. Unsound if present ever races the surface's own main-thread layer mutations.
struct WPEPresentLayer: @unchecked Sendable {
    let layer: CAMetalLayer
}

/// A partial update to the view's pacing knobs. `nil` fields are left untouched,
/// so each renderer call site writes exactly the knobs it wrote before.
struct WPERenderPacingUpdate: Sendable {
    var isPaused: Bool?
    var enableSetNeedsDisplay: Bool?
    var preferredFramesPerSecond: Int?
    var pointerEventsEnabled: Bool?
}

@MainActor
protocol WPERenderSurfaceClient: AnyObject {
    func renderAndPresentFrame()
    func updateSurfaceGeometry(drawableSize: CGSize)
}

protocol WPESurfaceControl: Sendable {
    func applyPacing(_ update: WPERenderPacingUpdate)
    func setNeedsRedraw()
    func drawImmediately()
    func releaseDrawables()
    func detach()
    func setClickCaptureEnabled(_ enabled: Bool)
}

extension WPERenderSurface: WPESurfaceControl {
    nonisolated func applyPacing(_ update: WPERenderPacingUpdate) {
        if let pointerEvents = update.pointerEventsEnabled {
            desiredPointerEventsEnabled.withLock { $0 = pointerEvents }
        }
        deliver { $0.applyPacingOnMain(update) }
    }

    nonisolated func setNeedsRedraw() {
        deliver { $0.setNeedsRedrawOnMain() }
    }

    nonisolated func drawImmediately() {
        deliver { $0.drawImmediatelyOnMain() }
    }

    nonisolated func releaseDrawables() {
        deliver { $0.releaseDrawablesOnMain() }
    }

    nonisolated func detach() {
        deliver { $0.detachOnMain() }
    }

    nonisolated func setClickCaptureEnabled(_ enabled: Bool) {
        deliver { $0.setClickCaptureEnabledOnMain(enabled) }
    }

    private nonisolated func deliver(_ body: @escaping @MainActor (WPERenderSurface) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            Task { @MainActor in body(self) }
        }
    }
}
#endif
