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
    /// The scene driver is confined to this actor.
    private var parityDriver: WPEParitySceneDriver?
    private var parityInputs: WPEParitySceneInputs?
    private var languageObservation: WPESceneLanguageObservation?
    private var progressHandler: (@Sendable (String) -> Void)?
    private var parityReplanning = false
    /// A static parity scene runs the link until one frame after a change presents, then parks it.
    private var parityFramePending = false
    /// The current `.suspended` profile keeps the link running until the parity pause ramp holds scene time.
    private var parityPauseRampDown = false
    private var parityActivity: WPESceneRuntimeActivity?
    private var parityAudioFeed = WPEParityAudioFeed()
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
        case let .performanceProfile(profile, rampDown): applyPerformanceProfile(profile, rampDown: rampDown)
        case let .frameRateCeiling(fps): setFrameRateCeiling(fps)
        case let .adaptiveFrameRateThrottle(active): setAdaptiveFrameRateThrottle(active)
        case let .audioMuted(muted): setAudioMuted(muted)
        case let .audioVolume(volume): setAudioVolume(volume)
        case let .mouseInteractionEnabled(enabled): setMouseInteractionEnabled(enabled)
        case let .clickCaptureEnabled(enabled): setClickCaptureEnabled(enabled)
        case let .presentFitMode(mode): setPresentFitMode(mode)
        case let .surfaceGeometry(size): updateSurfaceGeometry(drawableSize: size)
        case let .sceneScriptLanguage(language):
            if let parityDriver {
                parityDriver.setSceneScriptLanguage(language)
                requestParityFrame()
            }
        }
    }
    #endif

    #if !LITE_BUILD

    // MARK: - Renderer Ownership

    /// The driver is built here because it is not Sendable and must live on this actor.
    func adoptParity(_ inputs: WPEParitySceneInputs) throws {
        scenePropertyRendererGeneration &+= 1
        let driver = try WPEParitySceneDriver(device: inputs.device)
        driver.setSceneScriptLanguage(inputs.sceneScriptLanguage ?? WPESceneLanguageObservation.currentLanguage())
        languageObservation = WPESceneLanguageObservation { [weak self] language in
            self?.submitConfig(.sceneScriptLanguage(language))
        }
        driver.updateSurfaceGeometry(drawableSize: inputs.drawableSize)
        driver.setPresentFitMode(inputs.presentFitMode)
        driver.spanFrames = inputs.span?.frames
        driver.executor.spanOutputTextureLimit = inputs.span?.outputTextureLimit
        parityInputs?.userShortcutIcons?.onChange = nil
        parityInputs?.userShortcuts?.setChangeHandler(nil)
        (parityDriver, parityInputs) = (driver, inputs)
        inputs.userShortcutIcons?.onChange = { [weak self, weak icons = inputs.userShortcutIcons] in
            guard let icons else { return }
            Task { await self?.parityIconsChanged(icons) }
        }
        inputs.userShortcuts?.setChangeHandler { [weak self, weak bridge = inputs.userShortcuts] in
            guard let bridge else { return }
            Task { await self?.parityUserShortcutsChanged(bridge) }
        }
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
            let pointer = parityDriver.pointerInput(parityInputs.mailbox)
            // As the old renderer: the shared system-audio capture, not the scene's own sounds.
            let audio = parityAudioFeed.frame(broker: SystemAudioCaptureManager.broker,
                                              isCapturing: SystemAudioCaptureManager.isCapturing)
            let presented = if let frames = parityDriver.spanFrames {
                parityDriver.renderAndPublishSpanFrame(to: frames, timestamp: start, pointer: pointer.position,
                                                       buttonDown: pointer.buttonDown, audio: audio)
            } else {
                parityDriver.renderAndPresentFrame(layer: parityInputs.presentLayer.layer, timestamp: start,
                                                   pointer: pointer.position, buttonDown: pointer.buttonDown,
                                                   audio: audio)
            }
            parityInputs.mailbox.publishInteractiveZones(parityDriver.interactiveZones())
            thread?.noteFrameDuration(CACurrentMediaTime() - start,
                                      drawableWait: parityDriver.drawableAcquisitionSeconds - acquisitionStart)
            if parityFramePending, presented != nil {
                parityFramePending = false
                applyParityPacing()
            } else if parityPauseRampDown, !parityDriver.isPauseRamping {
                // The ramp's last frame presents nothing, so parking follows the clock.
                applyParityPacing()
            }
            if parityDriver.runtimeFailure != nil {
                applyParityPacing()
            }
            replanParityIfNeeded()
            return
        }
    }

    /// A static scene re-presents its cached frame on a plain redraw; changed texture content needs a fresh encode.
    func forceContentRerender() {
        requestParityFrame()
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
    private var linkPreferredFPS = WPESceneRenderPolicy.defaultPreferredFPS
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

    /// Once one present succeeds, later frame errors remain diagnostics and cannot revoke the already-visible readiness contract.
    func recordPresentCompletion(_ result: WPEFrameReadinessResult) {
        parityDriver?.recordSpanPresent(result)
    }

    func load() async throws {
        try await loadParity()
    }

    func reload() async throws {
        scenePropertyRendererGeneration &+= 1
        try await loadParity()
    }

    private func loadParity() async throws {
        guard let parityDriver, let inputs = parityInputs else { return }
        progressHandler?(String(localized: "Reading scene", bundle: .appLanguage, comment: "Scene load progress: parsing the scene package."))
        let (document, assets, userProperties) = try await CancellableBackgroundWork.run {
            try (inputs.makeDocument(), inputs.makeAssets(), inputs.scriptUserProperties())
        }
        progressHandler?(String(localized: "Preparing render pipeline", bundle: .appLanguage, comment: "Scene load progress: compiling Metal pipeline state."))
        try await parityDriver.load(document: document, assets: assets, settings: inputs.settings,
                                    drawableSize: parityDriver.drawableSize, pixelFormat: inputs.pixelFormat,
                                    compiler: inputs.compiler, diskCache: inputs.diskCache,
                                    compilerIdentity: inputs.compilerIdentity, shaderOptions: inputs.shaderOptions,
                                    bindingABIVersion: inputs.bindingABIVersion, shaderPolicy: inputs.shaderPolicy,
                                    requireCompleteShaders: inputs.requireCompleteShaders,
                                    renderScaleOverride: inputs.renderScaleOverride,
                                    textureCompression: inputs.textureCompression.map { $0 ? .shared : nil } ?? .resolve(),
                                    soundResolver: inputs.soundResolver,
                                    audioPreset: WPEEngineAudioSettings.parse(inputs.descriptor.presetSnapshot),
                                    workshopID: inputs.descriptor.workshopID,
                                    scriptHost: inputs.scriptHost(userPropertiesJSON: userProperties),
                                    userShortcutIcons: inputs.userShortcutIcons)
        let generation = parityDriver.loadGeneration
        if let media = inputs.media {
            let mailbox = media.mailbox
            if parityDriver.scriptHandlesMedia || parityDriver.hasMediaTextureDemand {
                let textureDemand = parityDriver.hasMediaTextureDemand
                _ = await MainActor.run {
                    media.configureParity(generation: generation, device: textureDemand ? inputs.device : nil,
                                          textureDemand: textureDemand, onChange: { [weak self] in
                                              Task { await self?.parityMediaChanged(generation: generation, mailbox: mailbox) }
                                          })
                }
            } else {
                await MainActor.run { media.stop() }
            }
        }
        guard self.parityDriver === parityDriver, parityDriver.loadGeneration == generation,
              parityDriver.didLoad else { throw CancellationError() }
        progressHandler?(String(localized: "Rendering scene", bundle: .appLanguage, comment: "Scene load progress: first frame is being drawn."))
        requestParityFrame()
        // A resize or fit change that arrived while loading.
        replanParityIfNeeded()
        thread?.boostRenderQoSWarmup()
    }

    private func parityMediaChanged(generation: Int, mailbox: WPESceneMediaEventMailbox) {
        // Reload requests its own first frame. Its replay callback may reach this actor after that frame
        // has already consumed the input and parked; only queued input still needs another frame.
        guard let driver = parityDriver, driver.didLoad, driver.loadGeneration == generation,
              parityInputs?.media?.mailbox === mailbox, mailbox.hasPendingParityInputs(generation: generation) else { return }
        requestParityFrame()
    }

    private func parityIconsChanged(_ icons: WPEUserShortcutIconStore) {
        guard parityInputs?.userShortcutIcons === icons, parityDriver?.didLoad == true else { return }
        requestParityFrame()
    }

    /// The next tick hands the rebound keys to applyUserProperties, so a parked scene needs that frame.
    private func parityUserShortcutsChanged(_ bridge: WPEUserShortcutScriptBridge) {
        guard parityInputs?.userShortcuts === bridge, parityDriver?.didLoad == true else { return }
        requestParityFrame()
    }

    /// The display link starts paused; the parity scene runs it while loaded and not suspended (or still ramping a
    /// suspend down), and a static one only until its pending frame presents. The frame-rate ceiling and pointer
    /// monitoring follow the old renderer: neither applies while suspended.
    private func applyParityPacing() {
        guard let parityDriver, let parityInputs else { return }
        let running = parityDriver.didLoad && parityDriver.runtimeFailure == nil
            && (!parityDriver.isPaused || (parityPauseRampDown && parityDriver.isPauseRamping))
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
            parityInputs?.mailbox.publishInteractiveZones([])
            applyParityPacing()
            return true
        }
        return false
    }

    func teardownRenderer() async {
        scenePropertyRendererGeneration &+= 1
        spanPresenter = nil
        parityDriver?.cleanup()
        languageObservation = nil
        progressHandler = nil
        let retiringInputs = parityInputs
        retiringInputs?.mailbox.publishInteractiveZones([])
        (parityDriver, parityInputs) = (nil, nil)
        retiringInputs?.userShortcutIcons?.onChange = nil
        retiringInputs?.userShortcuts?.setChangeHandler(nil)
        if let media = retiringInputs?.media {
            await MainActor.run { media.stop() }
        }
    }

    // MARK: - Configuration Forwarders

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile, rampDown: Bool = false) {
        if let parityDriver {
            parityDriver.applyPerformanceProfile(profile)
            parityPauseRampDown = profile == .suspended && rampDown
            parityFramePending = parityFramePending || profile != .suspended
            applyParityPacing()
            return
        }
        if spanPresenter != nil {
            setLinkPaused(profile == .suspended)
        }
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
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        if let parityDriver {
            parityDriver.setAdaptiveFrameRateThrottle(active)
            applyParityPacing()
            return
        }
    }

    func setAudioMuted(_ muted: Bool) {
        parityDriver?.setAudioMuted(muted)
    }

    func setAudioVolume(_ volume: Double) {
        parityDriver?.setAudioVolume(volume)
    }

    #if DEBUG
    func currentPendingAudioVolume() -> Double? {
        parityDriver?.audioVolume
    }
    #endif

    func requiresSystemAudioCapture() -> Bool {
        parityDriver?.requiresSystemAudioCapture ?? false
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        if let parityDriver {
            parityDriver.setMouseInteractionEnabled(enabled)
            applyParityPacing()
            return
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        if let parityInputs {
            // The mailbox first, as the old renderer: its epoch cancels pending presses at once.
            parityInputs.mailbox.setClickCaptureEnabled(enabled)
            parityInputs.surfaceControl.setClickCaptureEnabled(enabled)
            applyParityPacing()
            return
        }
    }

    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        if let parityDriver {
            parityDriver.setPresentFitMode(mode)
            replanParityIfNeeded()
            return
        }
    }

    /// Reload only when an authored control changes; a layer-only exclusion needs no rebuild.
    func setSystemWallpaperState(descriptor: SceneDescriptor, excludedObjectIDs: Set<String>) async throws {
        if let parityDriver, var inputs = parityInputs {
            parityDriver.excludedObjectIDs = excludedObjectIDs
            guard inputs.descriptor != descriptor else { requestParityFrame(); return }
            inputs.descriptor = descriptor
            parityInputs = inputs
            if parityDriver.didLoad {
                try await reload()
            }
            return
        }
    }

    func scenePropertyBindings() -> [String: [WPEScenePropertyBinding]] {
        if let parityDriver {
            return parityDriver.userPropertyBindings
        }
        return [:]
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
        return nil
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
        return false
    }

    func captureLivePoster() async -> NSImage? {
        if let parityDriver {
            // As `enqueueLivePosterCapture`: only a presented, running scene.
            guard !parityDriver.isPaused, let copy = await parityDriver.copyPresentedBackbuffer(),
                  !Task.isCancelled else { return nil }
            return await WPEMetalTextureSnapshotter.shared.snapshotAsync(from: copy)
        }
        return nil
    }

    /// Works while running or suspended; nil before presentation, after hibernation, or when replay fails.
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
                resumer.resume(returning: nil)
            }
        }, onCancel: {
            resumer.resume(returning: nil)
        }, isolation: self)
    }

    /// Export uses the normal frame and terminal colour pass, without acquiring a window drawable.
    func renderMovieFrame(into destination: WPEMetalRenderExecutor.PresentCompletionTexture) async throws {
        try Task.checkCancellation()
        if let parityDriver {
            if parityDriver.needsReplan {
                _ = await parityDriver.replan()
            }
            try await parityDriver.renderMovieFrame(into: destination, timestamp: CACurrentMediaTime())
            return
        }
        throw WPEMetalRenderExecutorError.noRenderablePasses
    }

    func loadDiagnostics() -> SceneLoadDiagnostic? {
        parityDriver?.loadDiagnostics
    }

    func setProgressHandler(_ handler: @escaping @Sendable (String) -> Void) {
        progressHandler = handler
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
                gpuErrorCount: parityDriver.gpuErrorSummary.count,
                gpuErrorLast: parityDriver.gpuErrorSummary.last,
                descriptor: parityInputs?.descriptor,
                parity: parityDriver.diagnostics,
                runtimeFailure: parityDriver.runtimeFailure
            )
        }
        return nil
    }
    #endif
}

#if !LITE_BUILD
enum WPERendererConfigCommand: Sendable {
    /// `rampDown`: a parity scene keeps drawing a `.suspended` profile until its pause ramp holds scene time.
    case performanceProfile(WallpaperPerformanceProfile, rampDown: Bool = false)
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
    var runtimeFailure: String?
}
#endif

#if !LITE_BUILD
/// NotificationCenter permits cross-thread delivery/removal; tokens are immutable and the callback owns no actor.
private final class WPESceneLanguageObservation: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]

    static func currentLanguage() -> String {
        AppLanguagePreference.current(in: .appScoped()).wallpaperEngineLanguageCode()
    }

    init(deliver: @escaping @Sendable (String) -> Void) {
        tokens = [UserDefaults.didChangeNotification, NSLocale.currentLocaleDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                deliver(Self.currentLanguage())
            }
        }
    }

    deinit { for token in tokens {
        NotificationCenter.default.removeObserver(token)
    } }
}
#endif
