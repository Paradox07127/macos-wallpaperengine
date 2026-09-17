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
            self.unownedExecutor = executor.asUnownedSerialExecutor()
        case .main:
            self.thread = nil
            self.executor = nil
            self.unownedExecutor = MainActor.sharedUnownedExecutor
        }
        #if !LITE_BUILD
        (self.configStream, self.configContinuation) = AsyncStream.makeStream(
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

    nonisolated var isOnRenderThread: Bool { thread?.isCurrent ?? Thread.isMainThread }

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
        case .performanceProfile(let profile): applyPerformanceProfile(profile)
        case let .frameRateCeiling(fps): setFrameRateCeiling(fps)
        case .adaptiveFrameRateThrottle(let active): setAdaptiveFrameRateThrottle(active)
        case .audioMuted(let muted): setAudioMuted(muted)
        case .audioVolume(let volume): setAudioVolume(volume)
        case .mouseInteractionEnabled(let enabled): setMouseInteractionEnabled(enabled)
        case .clickCaptureEnabled(let enabled): setClickCaptureEnabled(enabled)
        case .presentFitMode(let mode): setPresentFitMode(mode)
        case .surfaceGeometry(let size): updateSurfaceGeometry(drawableSize: size)
        case .sceneScriptLanguage(let language): renderer?.setSceneScriptLanguage(language)
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
        guard configConsumerTask == nil else { return }
        configConsumerTask = Task { [weak self, configStream] in
            for await command in configStream {
                guard let self else { break }
                await self.applyConfigCommand(command)
            }
        }
    }

    func renderFrame() {
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
    var linkPausedForTesting: Bool { linkPaused }
    var linkPreferredFPSForTesting: Int { linkPreferredFPS }
    var hasDisplayLinkForTesting: Bool { displayLink != nil }
    #endif

    func updateSurfaceGeometry(drawableSize: CGSize) {
        renderer?.updateSurfaceGeometry(drawableSize: drawableSize)
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
        defer { renderer.onDemandVideoLoading.remove(key) }
        guard renderer.loadGeneration == generation else { return }
        let previous = renderer.dynamicTextureSources[key] as? WPEVideoTextureSource
        do {
            // The generation must hold at PUBLICATION time, not just entry: a stale rebuild must not overwrite sources a wake reload just installed.
            try await renderer.loadDynamicTextureOnActor(
                path: key,
                layerName: key,
                publicationAllowed: { renderer.loadGeneration == generation },
                on: self
            )
        } catch {
            Logger.warning("Scene \(renderer.descriptor.workshopID) [OnDemandVideo] rebuild failed for \(key): \(error)", category: .wpeRender)
            // A silent failure here would leave the loop paused forever (released on-demand videos carry no frame demand); kick one frame so reconcileVideoResidency runs again.
            renderer.surfaceControl.setNeedsRedraw()
            return
        }
        guard renderer.loadGeneration == generation,
              let source = renderer.dynamicTextureSources[key] as? WPEVideoTextureSource else { return }
        if let previous, previous !== source {
            previous.invalidate()
        }
        source.applyPerformanceProfile(renderer.currentProfile)
        renderer.surfaceControl.setNeedsRedraw()
    }

    func prewarmShaders(pipeline: WPEPreparedRenderPipeline) async {
        await renderer?.prewarmCustomShaders(for: pipeline, on: self)
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
        try await renderer?.load(on: self)
        // First frames can still miss PSO signatures after prewarming.
        thread?.boostRenderQoSWarmup()
    }

    func reload() async throws {
        scenePropertyRendererGeneration &+= 1
        try await renderer?.reload(on: self)
        thread?.boostRenderQoSWarmup()
    }

    func hibernate() async -> Bool {
        guard let renderer else { return false }
        scenePropertyRendererGeneration &+= 1
        return await renderer.hibernate(on: self)
    }

    func teardownRenderer() {
        scenePropertyRendererGeneration &+= 1
        renderer?.cleanup()
        renderer = nil
    }

    // MARK: - Configuration Forwarders

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        renderer?.applyPerformanceProfile(profile)
    }

    func setFrameRateCeiling(_ framesPerSecond: Int) {
        renderer?.setFrameRateCeiling(framesPerSecond)
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        renderer?.setAdaptiveFrameRateThrottle(active)
    }

    func setAudioMuted(_ muted: Bool) {
        renderer?.setAudioMuted(muted)
    }

    func setAudioVolume(_ volume: Double) {
        renderer?.setAudioVolume(volume)
    }

    #if DEBUG
    func currentPendingAudioVolume() -> Double? {
        renderer?.pendingAudioVolume
    }
    #endif

    func requiresSystemAudioCapture() -> Bool {
        renderer?.sceneSupportsAudioProcessing ?? false
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderer?.setMouseInteractionEnabled(enabled)
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        renderer?.setClickCaptureEnabled(enabled)
    }

    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        renderer?.setPresentFitMode(mode)
    }

    func scenePropertyBindings() -> [String: [WPEScenePropertyBinding]] {
        renderer?.scenePropertyBindings ?? [:]
    }

    func prepareScenePropertyPatch(
        _ patch: WPEScenePropertyPatch,
        authority: ScenePropertyMutationAuthority,
        expectedIntent token: ScenePropertyMutationToken
    ) -> PreparedScenePropertyPatch? {
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
        guard let renderer, renderer.applyScenePropertyPatch(prepared.patch) else {
            return false
        }
        renderer.descriptor = updatedDescriptor
        return true
    }

    func captureLivePoster() async -> NSImage? {
        guard let renderer else { return nil }
        return await renderer.captureLivePosterFromNextFrame(on: self)
    }

    func loadDiagnostics() -> SceneLoadDiagnostic? {
        renderer?.loadDiagnostics
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
            gpuErrorLast: gpu.last
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
}
#endif
