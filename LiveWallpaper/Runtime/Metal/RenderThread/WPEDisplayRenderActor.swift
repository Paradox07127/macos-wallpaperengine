import Foundation
import QuartzCore
#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Monotonic admission state for display-link handoffs. A terminal stop can
/// never be reversed; stale or duplicate generations are rejected.
struct WPEDisplayLinkLifecycleState: Sendable {
    private(set) var latestGeneration: UInt64 = 0
    private(set) var isTerminal = false

    mutating func admit(generation: UInt64) -> Bool {
        guard !isTerminal, generation > latestGeneration else { return false }
        latestGeneration = generation
        return true
    }

    mutating func stop(generation: UInt64) {
        latestGeneration = max(latestGeneration, generation)
        isTerminal = true
    }
}
#endif

actor WPEDisplayRenderActor {
    enum Backing {
        case main
        case renderThread
    }

    /// Non-nil only for `.renderThread` backing; `.main` reuses `MainActor`'s
    /// executor and the process main run loop, so it owns no thread of its own.
    private let thread: WPERenderThread?
    private let executor: WPERenderThreadExecutor?

    nonisolated let unownedExecutor: UnownedSerialExecutor

    #if !LITE_BUILD
    private var renderer: WPEMetalSceneRenderer?
    /// Set instead of `renderer` for scenes listed by `WPEParityRendererFlag`; both are never set at once.
    private var parityDriver: WPEParitySceneDriver?
    private var parityInputs: WPEParitySceneInputs?
    private var parityReplanning = false
    /// A static parity scene runs the link until one frame after a change presents, then parks it.
    private var parityFramePending = false
    private var parityActivity: WPESceneRuntimeActivity?
    private var spanPresenter: WPESceneSpanPresenter?
    /// Prepared property patches may commit only against the exact renderer generation they preflighted.
    private var scenePropertyRendererGeneration: UInt64 = 0
    private var displayLinkLifecycle = WPEDisplayLinkLifecycleState()

    /// FIFO: last write always wins. `nonisolated let` lets setters on any thread yield without a hop.
    private nonisolated let configContinuation: AsyncStream<WPERendererConfigCommand>.Continuation
    private let configStream: AsyncStream<WPERendererConfigCommand>
    private var configConsumerTask: Task<Void, Never>?
    #endif

    init(label: String = "com.livewallpaper.render", backing: Backing = .renderThread) {
        switch backing {
        case .renderThread:
            let thread = WPERenderThread(label: label)
            let executor = WPERenderThreadExecutor(thread: thread)
            self.thread = thread
            self.executor = executor
            unownedExecutor = executor.asUnownedSerialExecutor()
        case .main:
            thread = nil
            executor = nil
            unownedExecutor = MainActor.sharedUnownedExecutor
        }
        #if !LITE_BUILD
        (configStream, configContinuation) = AsyncStream.makeStream(
            of: WPERendererConfigCommand.self
        )
        #endif
    }

    deinit {
        // Safety net so a dropped actor never leaks its dedicated thread.
        requestStop()
    }

    // MARK: - Isolated entry points

    func run<T: Sendable>(_ body: @Sendable (isolated WPEDisplayRenderActor) throws -> T) rethrows -> T {
        try body(self)
    }

    nonisolated func assumeIsolatedOnRenderThread<T: Sendable>(
        _ body: (isolated WPEDisplayRenderActor) throws -> T
    ) rethrows -> T {
        // Forward `body` directly (no wrapping closure) so it matches the stdlib
        // `Actor.assumeIsolated` shape and stays callable with a plain closure.
        try assumeIsolated(body)
    }

    // MARK: - Introspection (non-crashing; usable from any thread)

    nonisolated var isOnRenderThread: Bool {
        thread?.isCurrent ?? Thread.isMainThread
    }

    // MARK: - Render-loop Wiring

    nonisolated func add(_ displayLink: CADisplayLink, forMode mode: RunLoop.Mode = .common) {
        if let thread {
            thread.add(displayLink, forMode: mode)
        } else {
            displayLink.add(to: .main, forMode: mode)
        }
    }

    nonisolated func add(_ timer: Timer, forMode mode: RunLoop.Mode = .common) {
        if let thread {
            thread.add(timer, forMode: mode)
        } else {
            RunLoop.main.add(timer, forMode: mode)
        }
    }

    // MARK: - Lifecycle

    /// Never blocks; idempotent. The render thread exits on its own once its current pass is over.
    /// No-op for a `.main` backing, which owns no thread to stop.
    nonisolated func requestStop() {
        #if !LITE_BUILD
        configContinuation.finish()
        #endif
        thread?.requestStop()
    }

    /// Requests the stop and waits for the render thread to exit; false when it is still wedged after
    /// `timeout` (the thread is leaked, a fault is logged, the caller is never blocked).
    @discardableResult
    nonisolated func shutdown(timeout: Duration = .seconds(5)) async -> Bool {
        requestStop()
        guard let thread else { return true }
        return await thread.waitUntilStopped(timeout: timeout)
    }

    #if !LITE_BUILD
    nonisolated func submitConfig(_ command: WPERendererConfigCommand) {
        configContinuation.yield(command)
    }

    private func applyConfigCommand(_ command: WPERendererConfigCommand) {
        switch command {
        case let .performanceProfile(profile): applyPerformanceProfile(profile)
        case let .frameRateCeiling(fps): setFrameRateCeiling(fps)
        case let .adaptiveFrameRateThrottle(active): setAdaptiveFrameRateThrottle(active)
        case let .audioMuted(muted): setAudioMuted(muted)
        case let .audioVolume(volume): setAudioVolume(volume)
        case let .mouseInteractionEnabled(enabled): setMouseInteractionEnabled(enabled)
        case let .clickCaptureEnabled(enabled): setClickCaptureEnabled(enabled)
        case let .presentFitMode(mode): setPresentFitMode(mode)
        case let .surfaceGeometry(size): updateSurfaceGeometry(drawableSize: size)
        case let .sceneScriptLanguage(language): renderer?.setSceneScriptLanguage(language)
        }
    }
    #endif

    #if !LITE_BUILD

    // MARK: - Renderer Ownership

    func adopt(_ renderer: sending WPEMetalSceneRenderer) {
        scenePropertyRendererGeneration &+= 1
        self.renderer = renderer
        renderer.displayActor = self
        renderer.installSceneScriptLanguageObservers(on: self)
        startConfigConsumer()
    }

    /// The driver is built here because it is not Sendable and must live on this actor.
    func adoptParity(_ inputs: WPEParitySceneInputs) throws {
        scenePropertyRendererGeneration &+= 1
        let driver = try WPEParitySceneDriver(device: inputs.device)
        driver.updateSurfaceGeometry(drawableSize: inputs.drawableSize)
        driver.setPresentFitMode(inputs.presentFitMode)
        driver.spanFrames = inputs.span?.frames
        driver.executor.spanOutputTextureLimit = inputs.span?.outputTextureLimit
        parityDriver = driver
        parityInputs = inputs
        startConfigConsumer()
    }

    private func startConfigConsumer() {
        guard configConsumerTask == nil else { return }
        configConsumerTask = Task { [weak self, configStream] in
            for await command in configStream {
                guard let self else { break }
                await applyConfigCommand(command)
            }
        }
    }

    func adoptSpanPresenter(_ handoff: WPESceneSpanPresenterHandoff) {
        spanPresenter = handoff.presenter
        startConfigConsumer()
    }

    func updateSpanPresentation(_ configuration: VideoSpanRenderConfiguration) {
        spanPresenter?.configuration = configuration
    }

    func renderFrame() {
        if let spanPresenter {
            spanPresenter.present()
            return
        }
        if let parityDriver, let parityInputs {
            let acquisitionStart = parityDriver.drawableAcquisitionSeconds
            let start = CACurrentMediaTime()
            let pointer = parityDriver.pointerInput(parityInputs.mailbox.read())
            // As the old renderer: the shared system-audio capture, not the scene's own sounds.
            let audio = SystemAudioCaptureManager.isCapturing
                ? SystemAudioCaptureManager.broker.snapshot(clampedTo01: false) : nil
            let presented = if let frames = parityDriver.spanFrames {
                parityDriver.renderAndPublishSpanFrame(to: frames, timestamp: start, pointer: pointer.position,
                                                       buttonDown: pointer.buttonDown, audio: audio)
            } else {
                parityDriver.renderAndPresentFrame(layer: parityInputs.presentLayer.layer, timestamp: start,
                                                   pointer: pointer.position, buttonDown: pointer.buttonDown,
                                                   audio: audio)
            }
            thread?.noteFrameDuration(CACurrentMediaTime() - start,
                                      drawableWait: parityDriver.drawableAcquisitionSeconds - acquisitionStart)
            if parityFramePending, presented != nil {
                parityFramePending = false
                applyParityPacing()
            }
            return
        }
        // `.main` backing owns no thread and must never touch the main thread's QoS, so it skips timing.
        guard let thread else {
            renderer?.renderAndPresentFrame()
            return
        }
        guard let renderer else { return }
        let acquisitionStart = renderer.executor.drawableAcquisitionSeconds
        let start = CACurrentMediaTime()
        renderer.renderAndPresentFrame()
        thread.noteFrameDuration(
            CACurrentMediaTime() - start,
            drawableWait: renderer.executor.drawableAcquisitionSeconds - acquisitionStart
        )
    }

    /// A static scene re-presents its cached frame on a plain redraw; changed texture content needs a fresh encode.
    func forceContentRerender() {
        guard let renderer else { return }
        renderer.pendingForcedRerender = true
        renderer.surfaceControl.setNeedsRedraw()
    }

    func renderDisplayLinkFrame(at timestamp: Double) {
        guard !linkPaused,
              frameCadence.shouldRender(at: timestamp, framesPerSecond: linkPreferredFPS) else { return }
        renderFrame()
    }

    // MARK: - CADisplayLink Frame Driver

    // `isPaused` is the only knob Apple documents as thread-safe; `preferredFrameRateRange` is not, so neither is touched off the render thread.

    /// The live per-display link. Isolated state: only the render thread reads or
    /// writes it. Nil until installed / after invalidation.
    private var displayLink: CADisplayLink?
    /// Buffered pacing so an install that races the first `applyPacing` still ends on the right state.
    private var linkPaused = true
    private var linkPreferredFPS = WPEMetalSceneRenderer.defaultPreferredFPS
    private var linkDisplayFPS = 60
    private var frameCadence = FrameRateCadence()

    func replaceDisplayLink(
        _ handoff: WPEDisplayLinkHandoff,
        generation: UInt64
    ) {
        guard displayLinkLifecycle.admit(generation: generation) else {
            handoff.link.invalidate()
            return
        }
        displayLink?.invalidate()
        let link = handoff.link
        displayLink = link
        linkDisplayFPS = max(1, handoff.maximumFramesPerSecond)
        frameCadence.reset()
        applyLinkPacing()
        add(link)
    }

    func stopDisplayLinkDriver(generation: UInt64) {
        displayLinkLifecycle.stop(generation: generation)
        displayLink?.invalidate()
        displayLink = nil
        frameCadence.reset()
    }

    func setLinkPaused(_ paused: Bool) {
        if linkPaused != paused {
            frameCadence.reset()
        }
        linkPaused = paused
        applyLinkPacing()
    }

    func setLinkPreferredFPS(_ fps: Int) {
        if linkPreferredFPS != fps {
            frameCadence.reset()
        }
        linkPreferredFPS = fps
        // Keep the QoS budget on the live cadence so a 30fps wallpaper isn't judged
        // against a 60fps frame budget. Runs on the render thread (this actor).
        thread?.setFrameBudget(seconds: 1.0 / Double(max(fps, 1)))
        applyLinkPacing()
    }

    private func applyLinkPacing() {
        guard let displayLink else { return }
        displayLink.isPaused = linkPaused
        displayLink.preferredFrameRateRange = Self.frameRateRange(
            forPreferredFPS: linkPreferredFPS, displayFramesPerSecond: linkDisplayFPS
        )
    }

    /// Callback frequency and content frequency differ for non-divisor targets.
    static func frameRateRange(forPreferredFPS fps: Int, displayFramesPerSecond: Int = 60) -> CAFrameRateRange {
        let clamped = Float(FrameRateCadence.driverFramesPerSecond(target: fps, display: displayFramesPerSecond))
        return CAFrameRateRange(minimum: clamped, maximum: clamped, preferred: clamped)
    }

    #if DEBUG
    var linkPausedForTesting: Bool {
        linkPaused
    }

    var linkPreferredFPSForTesting: Int {
        linkPreferredFPS
    }

    var hasDisplayLinkForTesting: Bool {
        displayLink != nil
    }

    var usesParityDriverForTesting: Bool {
        parityDriver != nil
    }

    var parityPointerForTesting: WPEParityUniformPointer? {
        parityDriver?.renderer?.pointer
    }

    var parityFitModeForTesting: WPEPresentFitMode? {
        parityDriver?.fitMode
    }

    var parityDriverForTesting: WPEParitySceneDriver? {
        parityDriver
    }
    #endif

    func updateSurfaceGeometry(drawableSize: CGSize) {
        if let parityDriver {
            parityDriver.updateSurfaceGeometry(drawableSize: drawableSize)
            replanParityIfNeeded()
            return
        }
        renderer?.updateSurfaceGeometry(drawableSize: drawableSize)
    }

    /// The re-plan builds off the frame path; frames keep the current plan until it is swapped in.
    private func replanParityIfNeeded() {
        guard let parityDriver, parityDriver.needsReplan, !parityReplanning else { return }
        parityReplanning = true
        Task { await self.replanParity() }
    }

    private func replanParity() async {
        defer { parityReplanning = false }
        while let parityDriver, parityDriver.needsReplan, await parityDriver.replan() {
            requestParityFrame()
        }
    }

    /// The next frame shows a change a static scene's parked link would not draw on its own.
    private func requestParityFrame() {
        parityFramePending = true
        applyParityPacing()
    }

    func performStaticReload(
        path: String,
        record: WPEMetalSceneRenderer.StaticTextureCacheRecord,
        resolver: WPEMultiRootResourceResolver,
        loader: WPEMetalTextureLoader,
        threshold: Int,
        ticket: WPEStaticTextureReloadTaskOwner.Ticket
    ) async {
        await renderer?.performStaticTextureReload(
            path: path,
            record: record,
            resolver: resolver,
            loader: loader,
            threshold: threshold,
            ticket: ticket,
            on: self
        )
    }

    func harvestLazyPrefetches() {
        guard let renderer else { return }
        for source in renderer.dynamicTextureSources.values {
            (source as? WPETexLazyAnimatedTextureSource)?.harvestCompletedPrefetches()
        }
    }

    func rebuildOnDemandVideo(key: String, generation: Int) async {
        guard let renderer else { return }
        defer {
            if renderer.loadGeneration == generation {
                renderer.onDemandVideoTasks.removeValue(forKey: key)
            }
        }
        guard !Task.isCancelled, renderer.loadGeneration == generation else { return }
        let previous = renderer.dynamicTextureSources[key] as? WPEVideoTextureSource
        do {
            // The generation must hold at PUBLICATION time, not just entry: a stale rebuild must not overwrite sources a wake reload just installed.
            try await renderer.loadDynamicTextureOnActor(
                path: key,
                layerName: key,
                publicationAllowed: { renderer.loadGeneration == generation },
                on: self
            )
        } catch is CancellationError {
            return
        } catch {
            Logger.warning("Scene \(renderer.descriptor.workshopID) [OnDemandVideo] rebuild failed for \(key): \(error)", category: .wpeRender)
            return
        }
        guard renderer.loadGeneration == generation,
              let source = renderer.dynamicTextureSources[key] as? WPEVideoTextureSource else { return }
        if let previous, previous !== source {
            previous.invalidate()
        }
        renderer.sceneScriptVideoCommandBuffer.transportBySourceKey[key]?.apply(
            to: source,
            automaticPlayback: renderer.currentProfile == .quality
        )
        source.applyPerformanceProfile(renderer.currentProfile)
        renderer.surfaceControl.setNeedsRedraw()
    }

    func prewarmShaders(pipeline: WPEPreparedRenderPipeline) async -> Set<String> {
        await renderer?.prewarmCustomShaders(for: pipeline, on: self)
        return await renderer?.prewarmAuthoredVertexShaders(for: pipeline, on: self) ?? []
    }

    func publishDeferredAudio(runtime: WPESoundRuntime, generation: Int) {
        guard let renderer, !Task.isCancelled, renderer.loadGeneration == generation else {
            runtime.stop()
            return
        }
        runtime.setMuted(renderer.pendingAudioMuted)
        runtime.setMasterVolume(renderer.effectiveAudioVolume)
        renderer.soundRuntime = runtime
        // Seed the suspend flag from the live profile BEFORE any later mute toggle: `pause()` records isSuspended so a subsequent un-mute can't start audio on a suspended wallpaper.
        if renderer.currentProfile == .quality {
            runtime.play()
        } else {
            runtime.pause()
        }
        renderer.publishRuntimeActivity()
    }

    /// Once one present succeeds, later frame errors remain diagnostics and cannot revoke the already-visible readiness contract.
    func recordPresentCompletion(_ result: WPEFrameReadinessResult) {
        if let parityDriver {
            parityDriver.recordSpanPresent(result)
            return
        }
        guard let renderer,
              WPEFrameReadinessCoordinator.isCurrent(
                  result,
                  didLoad: renderer.didLoad,
                  currentGeneration: renderer.loadGeneration,
                  completedGeneration: renderer.completedPresentGeneration
              ) else {
            return
        }
        guard result.renderCompleted, result.presentCompleted else {
            renderer.failedPresentGeneration = result.generation
            return
        }
        renderer.completedPresentGeneration = result.generation
        renderer.failedPresentGeneration = nil
        if renderer.pendingAudioStartupDocument != nil {
            renderer.beginDeferredAudioStartup()
        }
    }

    func load() async throws {
        if parityDriver != nil {
            try await loadParity()
            return
        }
        try await renderer?.load(on: self)
        if renderer?.spanFrames != nil {
            renderer?.renderAndPresentFrame()
        }
        // First frames can still miss PSO signatures after prewarming.
        thread?.boostRenderQoSWarmup()
    }

    func reload() async throws {
        scenePropertyRendererGeneration &+= 1
        if parityDriver != nil {
            try await loadParity()
            return
        }
        try await renderer?.reload(on: self)
        if renderer?.spanFrames != nil {
            renderer?.renderAndPresentFrame()
        }
        thread?.boostRenderQoSWarmup()
    }

    private func loadParity() async throws {
        guard let parityDriver, let inputs = parityInputs else { return }
        let document = try await CancellableBackgroundWork.run { try inputs.makeDocument() }
        try await parityDriver.load(document: document, assets: inputs.assets, settings: inputs.settings,
                                    drawableSize: parityDriver.drawableSize, pixelFormat: inputs.pixelFormat,
                                    compiler: inputs.compiler, soundResolver: inputs.soundResolver,
                                    audioPreset: WPEEngineAudioSettings.parse(inputs.descriptor.presetSnapshot),
                                    workshopID: inputs.descriptor.workshopID)
        requestParityFrame()
        // A resize or fit change that arrived while loading.
        replanParityIfNeeded()
        thread?.boostRenderQoSWarmup()
    }

    /// The display link starts paused; the parity scene runs it while loaded and not suspended, and a static one
    /// only until its pending frame presents. The frame-rate ceiling and pointer monitoring follow the old renderer:
    /// neither applies while suspended.
    private func applyParityPacing() {
        guard let parityDriver, let parityInputs else { return }
        let running = parityDriver.didLoad && !parityDriver.isPaused
            && (parityDriver.needsContinuousFrames || parityFramePending)
        let pointerDemand = parityDriver.mouseInteractionEnabled || parityInputs.mailbox.read().clickCaptureEnabled
        parityInputs.surfaceControl.applyPacing(WPERenderPacingUpdate(
            isPaused: !running, enableSetNeedsDisplay: !running,
            preferredFramesPerSecond: parityDriver.isPaused ? nil : parityDriver.effectiveFPS,
            pointerEventsEnabled: !parityDriver.isPaused && pointerDemand
        ))
        let activity = WPESceneRuntimeActivity(producesFrames: parityDriver.needsContinuousFrames,
                                               audible: parityDriver.soundRuntime != nil)
        guard activity != parityActivity else { return }
        parityActivity = activity
        parityInputs.onRuntimeActivityChange?(activity)
    }

    func hibernate() async -> Bool {
        if let parityDriver {
            guard parityDriver.didLoad else { return false }
            scenePropertyRendererGeneration &+= 1
            parityDriver.cleanup()
            applyParityPacing()
            return true
        }
        guard let renderer else { return false }
        scenePropertyRendererGeneration &+= 1
        return await renderer.hibernate(on: self)
    }

    func teardownRenderer() async {
        scenePropertyRendererGeneration &+= 1
        let retiringRenderer = renderer
        renderer = nil
        spanPresenter = nil
        parityDriver?.cleanup()
        parityDriver = nil
        parityInputs = nil
        if let retiringRenderer {
            let videoTasks = retiringRenderer.cancelOnDemandVideoLoads()
            let staticDrain = await retiringRenderer.staticTextureReloadTaskOwner.quiesce()
            retiringRenderer.cleanup()
            await staticDrain.wait()
            for task in videoTasks {
                await task.value
            }
        }
    }

    // MARK: - Configuration Forwarders

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        if let parityDriver {
            parityDriver.applyPerformanceProfile(profile)
            parityFramePending = parityFramePending || profile != .suspended
            applyParityPacing()
            return
        }
        if spanPresenter != nil {
            setLinkPaused(profile == .suspended)
        }
        renderer?.applyPerformanceProfile(profile)
    }

    func setFrameRateCeiling(_ framesPerSecond: Int) {
        if let parityDriver {
            parityDriver.setFrameRateCeiling(framesPerSecond)
            applyParityPacing()
            return
        }
        if spanPresenter != nil {
            setLinkPreferredFPS(framesPerSecond)
        }
        renderer?.setFrameRateCeiling(framesPerSecond)
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        if let parityDriver {
            parityDriver.setAdaptiveFrameRateThrottle(active)
            applyParityPacing()
            return
        }
        renderer?.setAdaptiveFrameRateThrottle(active)
    }

    func setAudioMuted(_ muted: Bool) {
        parityDriver?.setAudioMuted(muted)
        renderer?.setAudioMuted(muted)
    }

    func setAudioVolume(_ volume: Double) {
        parityDriver?.setAudioVolume(volume)
        renderer?.setAudioVolume(volume)
    }

    #if DEBUG
    func currentPendingAudioVolume() -> Double? {
        renderer?.pendingAudioVolume
    }
    #endif

    func requiresSystemAudioCapture() -> Bool {
        if let parityDriver {
            return parityDriver.requiresSystemAudioCapture
        }
        return renderer?.sceneSupportsAudioProcessing ?? false
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        if let parityDriver {
            parityDriver.setMouseInteractionEnabled(enabled)
            applyParityPacing()
            return
        }
        renderer?.setMouseInteractionEnabled(enabled)
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        if let parityInputs {
            // The mailbox first, as the old renderer: its epoch cancels pending presses at once.
            parityInputs.mailbox.setClickCaptureEnabled(enabled)
            parityInputs.surfaceControl.setClickCaptureEnabled(enabled)
            applyParityPacing()
            return
        }
        renderer?.setClickCaptureEnabled(enabled)
    }

    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        if let parityDriver {
            parityDriver.setPresentFitMode(mode)
            replanParityIfNeeded()
            return
        }
        renderer?.setPresentFitMode(mode)
    }

    func scenePropertyBindings() -> [String: [WPEScenePropertyBinding]] {
        if let parityDriver {
            return parityDriver.userPropertyBindings
        }
        return renderer?.scenePropertyBindings ?? [:]
    }

    func prepareScenePropertyPatch(
        _ patch: WPEScenePropertyPatch,
        authority: ScenePropertyMutationAuthority,
        expectedIntent token: ScenePropertyMutationToken
    ) async -> PreparedScenePropertyPatch? {
        if let parityDriver, let parityInputs {
            // The scene is re-parsed with the new values off the render thread, so frames keep running meanwhile.
            let generation = scenePropertyRendererGeneration
            guard authority.isCurrent(token), parityDriver.canApplyUserPropertiesLive(patch),
                  let document = try? await CancellableBackgroundWork.run({
                      try parityInputs.makeDocument(changing: patch)
                  }),
                  generation == scenePropertyRendererGeneration, authority.isCurrent(token),
                  parityDriver.prepareUserProperties(patch, document: document) else {
                return nil
            }
            return PreparedScenePropertyPatch(patch: patch, rendererGeneration: generation)
        }
        guard authority.isCurrent(token),
              renderer?.canApplyScenePropertyPatch(patch) == true else {
            return nil
        }
        return PreparedScenePropertyPatch(
            patch: patch,
            rendererGeneration: scenePropertyRendererGeneration
        )
    }

    func commitScenePropertyPatch(
        _ prepared: PreparedScenePropertyPatch,
        updatedDescriptor: SceneDescriptor
    ) -> Bool {
        guard prepared.rendererGeneration == scenePropertyRendererGeneration else {
            return false
        }
        if let parityDriver {
            guard parityDriver.commitUserProperties(prepared.patch) else { return false }
            // A later reload parses with the committed values.
            parityInputs?.descriptor = updatedDescriptor
            requestParityFrame()
            return true
        }
        guard let renderer, renderer.applyScenePropertyPatch(prepared.patch) else {
            return false
        }
        renderer.descriptor = updatedDescriptor
        return true
    }

    func captureLivePoster() async -> NSImage? {
        if let parityDriver {
            // As `enqueueLivePosterCapture`: only a presented, running scene.
            guard !parityDriver.isPaused, let copy = await parityDriver.copyPresentedBackbuffer(),
                  !Task.isCancelled else { return nil }
            return await WPEMetalTextureSnapshotter.shared.snapshotAsync(from: copy)
        }
        let id = UUID()
        // Keep the suspension and its continuation on the owning actor. Nesting these
        // closures in the renderer's isolated-parameter method lost executor inheritance
        // on the cooperative pool, racing the render loop's dictionary drain.
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.preconditionIsolated()
                guard !Task.isCancelled, let renderer = self.renderer else {
                    continuation.resume(returning: nil)
                    return
                }
                renderer.enqueueLivePosterCapture(id: id, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.finishLivePosterCapture(id: id, image: nil) }
        }, isolation: self)
    }

    /// Works while running or suspended; nil when nothing was presented, the scene is hibernated, or MetalFX drew the last frame.
    func captureDisplayedFrame() async -> WPEDisplayedFrameCapture? {
        let resumer = WPEDisplayedFrameCaptureResumer()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.preconditionIsolated()
                resumer.install(continuation)
                if let parityDriver = self.parityDriver, let parityInputs = self.parityInputs, !Task.isCancelled {
                    parityDriver.captureDisplayedFrame(colorSpace: parityInputs.presentLayer.layer.colorspace) {
                        resumer.resume(returning: $0)
                    }
                    return
                }
                guard !Task.isCancelled, let renderer = self.renderer, let source = renderer.outputTexture else {
                    resumer.resume(returning: nil)
                    return
                }
                renderer.executor.encodeDisplayedFrameCapture(
                    source: source,
                    colorSpace: renderer.metalLayer.layer.colorspace
                ) { capture in
                    resumer.resume(returning: capture)
                }
            }
        }, onCancel: {
            resumer.resume(returning: nil)
        }, isolation: self)
    }

    func loadDiagnostics() -> SceneLoadDiagnostic? {
        renderer?.loadDiagnostics ?? parityDriver?.loadDiagnostics
    }

    func isCurrentLoadGeneration(_ generation: Int) -> Bool {
        renderer?.loadGeneration == generation
    }

    func finishLivePosterCapture(id: UUID, image: NSImage?) {
        renderer?.finishLivePosterCapture(id: id, image: image)
    }

    /// Apply an intro→loop phase offset on this actor. `token` guards staleness (bumped by every reload/invalidate).
    func applyIntroLoopOffset(_ offset: TimeInterval?, token: Int, scriptLoadToken: WPESceneScriptInstanceLimitToken) {
        guard let renderer,
              renderer.introPhaseToken == token,
              renderer.isCurrentSceneScriptLoad(scriptLoadToken) else { return }
        renderer.introLoopOffset = offset
    }

    func setProgressHandler(_ handler: @escaping @Sendable (String) -> Void) {
        renderer?.onProgress = handler
    }

    func rendererStateSnapshot() -> WPERendererStateSnapshot? {
        if let parityDriver {
            let shader = parityDriver.shaderErrorSummary
            return WPERendererStateSnapshot(
                isLoaded: parityDriver.didLoad,
                currentLoadGeneration: parityDriver.loadGeneration,
                completedPresentGeneration: parityDriver.completedPresentGeneration,
                failedPresentGeneration: parityDriver.failedPresentGeneration,
                hasPresentedFrame: parityDriver.hasPresentedFrame,
                loadDiagnostics: parityDriver.loadDiagnostics,
                resolution: WPEResolutionDiagnosticsSnapshot(events: []),
                shaderErrors: shader.entries.map { .init(shader: $0.shader, reason: $0.reason) },
                shaderErrorCount: shader.count,
                gpuErrorCount: 0,
                gpuErrorLast: nil,
                descriptor: parityInputs?.descriptor,
                parity: parityDriver.diagnostics
            )
        }
        guard let renderer else { return nil }
        let shader = renderer.shaderErrorSummary
        let gpu = renderer.gpuErrorSummary
        return WPERendererStateSnapshot(
            isLoaded: renderer.didLoad,
            currentLoadGeneration: renderer.loadGeneration,
            completedPresentGeneration: renderer.completedPresentGeneration,
            failedPresentGeneration: renderer.failedPresentGeneration,
            hasPresentedFrame: renderer.hasPresentedFrame,
            loadDiagnostics: renderer.loadDiagnostics,
            resolution: renderer.resolutionDiagnostics,
            shaderErrors: shader.entries.map { .init(shader: $0.shader, reason: $0.reason) },
            shaderErrorCount: shader.count,
            gpuErrorCount: gpu.count,
            gpuErrorLast: gpu.last,
            descriptor: renderer.descriptor,
            compatibilitySummary: renderer.sceneTestingSummary
        )
    }
    #endif
}

#if !LITE_BUILD
enum WPERendererConfigCommand: Sendable {
    case performanceProfile(WallpaperPerformanceProfile)
    case frameRateCeiling(Int)
    case adaptiveFrameRateThrottle(Bool)
    case audioMuted(Bool)
    case audioVolume(Double)
    case mouseInteractionEnabled(Bool)
    case clickCaptureEnabled(Bool)
    case presentFitMode(WPEPresentFitMode)
    case surfaceGeometry(CGSize)
    case sceneScriptLanguage(String)
}

/// `@unchecked Sendable`: the renderer is built on main, transferred into the actor exactly
/// once before any frame runs, and never touched on the constructing thread again. Unsound if
/// the builder uses the renderer after wrapping, or hands the same renderer to two actors.
struct WPERendererHandoff: @unchecked Sendable {
    let renderer: WPEMetalSceneRenderer
}

struct WPERendererStateSnapshot: Sendable {
    struct ShaderError: Sendable {
        let shader: String
        let reason: String
    }

    let isLoaded: Bool
    let currentLoadGeneration: Int
    let completedPresentGeneration: Int?
    let failedPresentGeneration: Int?
    let hasPresentedFrame: Bool
    let loadDiagnostics: SceneLoadDiagnostic?
    let resolution: WPEResolutionDiagnosticsSnapshot
    let shaderErrors: [ShaderError]
    let shaderErrorCount: Int
    let gpuErrorCount: Int
    let gpuErrorLast: String?
    var descriptor: SceneDescriptor?
    var compatibilitySummary = ""
    /// Set only for a scene on the parity pipeline.
    var parity: WPEParityRuntimeDiagnostics?
}
#endif
