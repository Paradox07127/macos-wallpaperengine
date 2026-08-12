#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// A side-effect-free renderer preflight promoted to a committed delivery only
/// after MainActor has persisted the matching descriptor.
struct PreparedScenePropertyPatch: Sendable {
    let patch: WPEScenePropertyPatch
    let rendererGeneration: UInt64
}

@MainActor
protocol SystemAudioCaptureDemandControlling: AnyObject {
    func retain()
    func release()
}

extension SystemAudioCaptureManager: SystemAudioCaptureDemandControlling {}

/// @MainActor adapter forwarding runtime-config to `WPEDisplayRenderActor` via ordered `submitConfig`.
/// One-frame apply latency is fine; last write wins on the actor channel.
@MainActor
final class WPERendererConfigAdapter: WallpaperPerformanceConfigurable, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable {
    private let renderActor: WPEDisplayRenderActor

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        renderActor.submitConfig(.performanceProfile(profile))
    }

    func setFrameRateLimit(_ limit: FrameRateLimit) {
        renderActor.submitConfig(.frameRateLimit(limit))
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        renderActor.submitConfig(.adaptiveFrameRateThrottle(active))
    }

    func setAudioMuted(_ muted: Bool) {
        renderActor.submitConfig(.audioMuted(muted))
    }

    func setAudioVolume(_ volume: Double) {
        renderActor.submitConfig(.audioVolume(volume))
    }
}

/// `WallpaperRuntimeSession` adapter over a per-display render actor (not the bare renderer).
/// Frame-config is fire-and-forget; present/diagnostics are polled for the inspector.
@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    /// Per-display render isolation domain. Owns the renderer; the
    /// session drives it entirely through this actor.
    private let renderActor: WPEDisplayRenderActor
    /// Synchronous admission authority shared with the render actor. It is
    /// independent from renderer lifetime so cleanup can invalidate work that
    /// is already queued on the actor.
    private let scenePropertyMutationAuthority = ScenePropertyMutationAuthority()
    private let scenePropertyPosterCommitGate = ScenePropertyPosterCommitGate()
    /// The main-thread surface, held strongly so it (and the delivery shim it
    /// owns) outlive the wallpaper. The renderer only references it through the
    /// `Sendable` `surfaceControl` seam, so the session is its sole strong owner.
    private let surface: WPERenderSurface
    /// @MainActor forwarding surface for the renderer's runtime-config protocols.
    private let rendererConfigAdapter: WPERendererConfigAdapter
    /// True while a renderer is adopted (construction → cleanup). Drives the
    /// nil-when-no-renderer semantics for the frame-rate/audio controllers.
    private var hasRenderer = true
    /// System policy remains the durable source of truth. The inspector may
    /// temporarily force suspension, but clearing that override must restore
    /// the folded policy/visibility/user-intent result rather than force play.
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var previewProfileOverride: WallpaperPerformanceProfile?
    private var lastAppliedPerformanceProfile: WallpaperPerformanceProfile?
    private var requiresSystemAudioCapture = false
    /// Last-logged snapshot of the five capture-demand inputs, so the diagnostic
    /// prints on any change instead of only when the outcome flips.
    private var lastLoggedAudioDemandInputs = ""

    private var audioCaptureDemandRetained = false
    private let audioCaptureDemandController: any SystemAudioCaptureDemandControlling
    /// Durable user play intent; effective = `userIntendsToPlay && profile == .quality`.
    private(set) var userIntendsToPlay = true
    private var isVisible = true
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    /// The controlled startup task (renderer adopt → initial load). Session-owned
    /// so `cleanup()` can cancel and drain it before teardown — a detached startup
    /// could otherwise adopt a renderer into an already-shut-down actor.
    private var startupTask: Task<Void, Never>?
    /// Retains the ordered teardown task spawned by `cleanup()` (which must keep a
    /// synchronous signature) so it runs to completion.
    private var cleanupTask: Task<Void, Never>?
    /// Bumped by `cleanup()`. The startup task checks it after `adopt` so a cleanup
    /// that raced the adopt skips `beginLoad` on a torn-down session.
    private var lifecycleGeneration = 0
    /// Monotonic id of the most recent load/reload. Guards the "clear
    /// `loadTask` when done" writes so a finished older task can't drop the
    /// handle of a newer one that replaced it while the older was draining.
    private var loadGeneration = 0
    private(set) var loadError: SceneRenderingError? {
        didSet {
            runtimeError = loadError.map {
                .sceneRenderingFailed(description: $0.errorDescription ?? "")
            }
        }
    }
    private(set) var loadProgress: String?
    private(set) var runtimeError: WallpaperRuntimeError? {
        didSet {
            guard oldValue != runtimeError else { return }
            onRuntimeErrorChange?()
        }
    }
    var onRuntimeErrorChange: (@MainActor () -> Void)?

    /// Cached present flag from `pollRendererState()`: nil/false/true → idle/loading/presented.
    private(set) var hasPresentedFrame: Bool? = false
    /// Cached diagnostic snapshot for the inspector's log sheet, refreshed by
    /// `pollRendererState()` so the SwiftUI read stays synchronous.
    private(set) var rendererDiagnostics: SceneRendererDiagnostics?

    init(
        window: NSWindow,
        renderActor: WPEDisplayRenderActor,
        surface: WPERenderSurface,
        audioCaptureDemandController: any SystemAudioCaptureDemandControlling = SystemAudioCaptureManager.shared
    ) {
        self.window = window
        self.renderActor = renderActor
        self.surface = surface
        self.rendererConfigAdapter = WPERendererConfigAdapter(renderActor: renderActor)
        self.audioCaptureDemandController = audioCaptureDemandController
    }

    private var effectivePerformanceProfile: WallpaperPerformanceProfile {
        guard isVisible,
              userIntendsToPlay,
              currentProfile == .quality,
              previewProfileOverride != .suspended else {
            return .suspended
        }
        return .quality
    }

    var summary: WallpaperSessionSummary {
        let activity: WallpaperSessionActivity
        if loadError != nil {
            activity = .error
        } else if !isVisible {
            activity = .off
        } else if effectivePerformanceProfile == .suspended {
            activity = .paused
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: .scene,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: loadError?.errorDescription.map(PIISanitizer.scrub)
        )
    }

    var isPlaying: Bool {
        effectivePerformanceProfile == .quality
    }

    func play() {
        userIntendsToPlay = true
        applyEffectivePerformanceProfile()
    }

    func pause() {
        userIntendsToPlay = false
        applyEffectivePerformanceProfile()
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { window }

    /// Refreshes the present + diagnostics caches from the live renderer. The
    /// inspector's 0.4s poll awaits this before reading the sync accessors.
    func pollRendererState() async {
        guard let snapshot = await renderActor.rendererStateSnapshot() else {
            hasPresentedFrame = nil
            rendererDiagnostics = nil
            return
        }
        hasPresentedFrame = snapshot.hasPresentedFrame
        rendererDiagnostics = SceneRendererDiagnostics(
            loadDiagnostics: snapshot.loadDiagnostics,
            resolution: snapshot.resolution,
            shaderErrors: .init(
                count: snapshot.shaderErrorCount,
                entries: snapshot.shaderErrors.map { .init(shader: $0.shader, reason: $0.reason) }
            ),
            gpuErrors: .init(count: snapshot.gpuErrorCount, last: snapshot.gpuErrorLast)
        )
    }

    /// Async forwarder for the inspector's on-demand poster read-back.
    func captureLivePosterFromNextFrame() async -> NSImage? {
        await renderActor.captureLivePoster()
    }

    /// Inspector-only override used to force a static preview under Reduce
    /// Motion. `.quality` clears the override and restores the current folded
    /// policy instead of overriding a battery/offscreen/manual suspension.
    func applyPreviewPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        previewProfileOverride = profile == .quality ? nil : profile
        applyEffectivePerformanceProfile()
    }

    /// Ends the inspector's temporary performance override without changing
    /// system policy or durable user play/pause intent.
    func clearPreviewPerformanceOverride() {
        previewProfileOverride = nil
        applyEffectivePerformanceProfile()
    }

    /// The loaded scene's property→binding map, read from the live renderer.
    func scenePropertyBindings() async -> [String: [WPEScenePropertyBinding]] {
        await renderActor.scenePropertyBindings()
    }

    @discardableResult
    func advanceScenePropertyMutationIntent() -> ScenePropertyMutationToken {
        scenePropertyMutationAuthority.advance()
    }

    func currentScenePropertyMutationToken() -> ScenePropertyMutationToken {
        scenePropertyMutationAuthority.currentToken()
    }

    func isCurrentScenePropertyMutationIntent(
        _ token: ScenePropertyMutationToken
    ) -> Bool {
        scenePropertyMutationAuthority.isCurrent(token)
    }

    /// Side-effect-free preflight. A successful result is not allowed to touch
    /// renderer state until MainActor persists the descriptor and promotes it
    /// through `commitScenePropertyPatch`.
    func prepareScenePropertyPatch(
        _ patch: WPEScenePropertyPatch,
        expectedIntent token: ScenePropertyMutationToken
    ) async -> PreparedScenePropertyPatch? {
        await renderActor.prepareScenePropertyPatch(
            patch,
            authority: scenePropertyMutationAuthority,
            expectedIntent: token
        )
    }

    /// Delivers a patch whose descriptor has already been persisted. This does
    /// not re-check proposal intent: a later no-op selection must not cancel a
    /// renderer delivery that is now the persisted source of truth.
    func stageScenePropertyPosterCommit(
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> ScenePropertyPosterCommit {
        scenePropertyPosterCommitGate.stage(overrides: overrides)
    }

    func stagedScenePropertyPosterCommit(
        matching revision: ScenePropertyOverridesRevision
    ) -> ScenePropertyPosterCommit? {
        scenePropertyPosterCommitGate.staged(matching: revision)
    }

    func waitForScenePropertyPosterCommit(_ expected: ScenePropertyPosterCommit) async -> Bool {
        guard hasRenderer else { return false }
        return await scenePropertyPosterCommitGate.wait(for: expected)
    }

    func commitScenePropertyPatch(
        _ prepared: PreparedScenePropertyPatch,
        posterCommit: ScenePropertyPosterCommit
    ) async -> Bool {
        let didCommit = await renderActor.commitScenePropertyPatch(prepared)
        scenePropertyPosterCommitGate.resolve(posterCommit, result: didCommit)
        return didCommit
    }

    // Nil-when-no-renderer semantics preserved: consumers guard on this, and a
    // torn-down session must report no controller (mirrors the old `{ renderer }`).
    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        hasRenderer ? rendererConfigAdapter : nil
    }

    var audioController: (any WallpaperAudioConfigurable)? {
        hasRenderer ? rendererConfigAdapter : nil
    }

    func updateFrame(to frame: CGRect) {
        window?.setFrame(frame, display: true)
        // The window's contentView IS the renderer's MTKView (set at build time),
        // so resize it here without reaching into the actor for `nsView`.
        window?.contentView?.frame = CGRect(origin: .zero, size: frame.size)
    }

    func show() {
        isVisible = true
        window?.orderBack(nil)
        // Route through the session so the effective profile honours
        // `userIntendsToPlay` — a manually paused scene must not resume just
        // because it became visible again (space switch / display wake).
        applyEffectivePerformanceProfile()
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        applyEffectivePerformanceProfile()
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        applyEffectivePerformanceProfile()
    }

    private func applyEffectivePerformanceProfile() {
        let effective = effectivePerformanceProfile
        if lastAppliedPerformanceProfile != effective {
            lastAppliedPerformanceProfile = effective
            rendererConfigAdapter.applyPerformanceProfile(effective)
        }
        reconcileSystemAudioCaptureDemand()
    }

    /// Per-screen cursor-reactivity toggle (camera parallax + pointer shaders).
    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderActor.submitConfig(.mouseInteractionEnabled(enabled))
    }

    /// Per-screen "Interaction" toggle: makes the wallpaper window capture real
    /// clicks (steals desktop clicks while on) and routes them to the renderer.
    func setClickCaptureEnabled(_ enabled: Bool) {
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(enabled)
        renderActor.submitConfig(.clickCaptureEnabled(enabled))
    }

    /// Maps the shared `VideoFitMode` onto the renderer-local present transform
    /// (the renderer has no AVFoundation dependency).
    func setSceneFitMode(_ mode: VideoFitMode) {
        let present: WPEPresentFitMode
        switch mode {
        case .stretch: present = .stretch
        case .aspectFit: present = .contain
        case .aspectFill: present = .cover
        case .center: present = .center
        }
        renderActor.submitConfig(.presentFitMode(present))
    }

    /// Adopt the freshly-built renderer into the actor and drive the initial load,
    /// inside a session-owned `startupTask`. Called by the builder in place of a
    /// detached task so `cleanup()` controls the adopt/load lifetime.
    func startAdoptingRenderer(_ handoff: WPERendererHandoff) {
        let generation = lifecycleGeneration
        startupTask = Task { [weak self, renderActor] in
            await renderActor.adopt(handoff.renderer)
            // If cleanup ran during the adopt hop, skip the load: the actor is being
            // (or has been) torn down. The renderer is still adopted, so cleanup's
            // teardown releases it.
            guard let self, self.isCurrentLifecycle(generation) else { return }
            await self.beginLoad()
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        lifecycleGeneration == generation
    }

    func cleanup() {
        // Invalidate any pending startup guard so a racing adopt won't drive a load.
        lifecycleGeneration += 1
        scenePropertyMutationAuthority.advance()
        hasRenderer = false
        scenePropertyPosterCommitGate.invalidate()
        requiresSystemAudioCapture = false
        reconcileSystemAudioCaptureDemand()
        hasPresentedFrame = nil
        // Remove the display-link reconfiguration observer and invalidate the
        // link on main now, before the async teardown — so no rebuild can install a
        // link into an actor that is being shut down. No-op in `.main` mode.
        let displayLinkStopTask = surface.stopDisplayLinkDriver()
        window?.close()
        window = nil
        let actor = renderActor
        let startup = startupTask
        let load = loadTask
        startupTask = nil
        loadTask?.cancel()
        loadTask = nil
        // Ordered teardown: cancel then DRAIN the startup/load tasks before tearing
        // the renderer down, so teardown never runs ahead of an in-flight adopt or
        // load. cleanup() keeps its sync signature; the task is retained above.
        cleanupTask = Task {
            startup?.cancel()
            await displayLinkStopTask?.value
            await startup?.value
            await load?.value
            await actor.teardownRenderer()
            actor.shutdown()
        }
    }

    /// Install progress handler and run initial load on the actor (after adopt).
    /// Session-retained `loadTask` so reload/cleanup can cancel and drain it.
    func beginLoad() async {
        guard !didStartLoad else { return }
        didStartLoad = true
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.installProgressHandler()
            await self.runLoadViaActor()
        }
        loadTask = task
        await task.value
        if loadGeneration == generation {
            loadTask = nil
        }
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        var targetGeneration: Int?
        return await WallpaperPreparationWaiter.wait(
            timeout: timeout,
            pollInterval: .milliseconds(25)
        ) { [weak self] in
            guard let self else { return .cancelled }
            if self.loadError != nil {
                return .failed
            }
            guard let snapshot = await self.renderActor.rendererStateSnapshot() else {
                return nil
            }
            guard snapshot.isLoaded else { return nil }
            if targetGeneration == nil {
                targetGeneration = snapshot.currentLoadGeneration
            }
            guard snapshot.currentLoadGeneration == targetGeneration else {
                return .cancelled
            }
            if snapshot.failedPresentGeneration == targetGeneration {
                return .failed
            }
            return snapshot.completedPresentGeneration == targetGeneration ? .ready : nil
        }
    }

    func retry() async {
        await reload()
    }

    func reload() async {
        guard hasRenderer else {
            loadError = .cacheRootMissing
            return
        }
        // Cancel+drain in-flight load before reload — cooperative cancel can append half-loaded state.
        loadTask?.cancel()
        if let previous = loadTask {
            await previous.value
        }
        loadTask = nil
        requiresSystemAudioCapture = false
        reconcileSystemAudioCaptureDemand()
        await installProgressHandler()
        loadGeneration += 1
        let generation = loadGeneration
        // Run the reload inside a tracked task so `cleanup()` can cancel a
        // reload that is still streaming assets when the session goes away.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.renderActor.reload()
                guard self.loadGeneration == generation else { return }
                await self.refreshSystemAudioCaptureRequirement()
                self.loadError = nil
                self.loadProgress = nil
            } catch is CancellationError {
                return
            } catch let error as SceneRenderingError {
                guard self.loadGeneration == generation else { return }
                self.loadError = error
            } catch {
                guard self.loadGeneration == generation else { return }
                self.loadError = await self.mapLoadFailure(error)
            }
        }
        loadTask = task
        await task.value
        if loadGeneration == generation {
            loadTask = nil
        }
    }

    private func installProgressHandler() async {
        let handler: @Sendable (String) -> Void = { [weak self] progress in
            Task { @MainActor in self?.loadProgress = progress }
        }
        await renderActor.setProgressHandler(handler)
    }

    private func runLoadViaActor() async {
        do {
            try await renderActor.load()
            guard !Task.isCancelled else { return }
            await refreshSystemAudioCaptureRequirement()
            loadError = nil
            loadProgress = nil
        } catch is CancellationError {
            return
        } catch let error as SceneRenderingError {
            guard !Task.isCancelled else { return }
            requiresSystemAudioCapture = false
            reconcileSystemAudioCaptureDemand()
            Logger.warning(
                "Scene wallpaper load failed: \(error.errorDescription ?? "(no description)")",
                category: .screenManager
            )
            loadError = error
        } catch {
            guard !Task.isCancelled else { return }
            requiresSystemAudioCapture = false
            reconcileSystemAudioCaptureDemand()
            Logger.warning(
                "Scene wallpaper load failed: \(error.localizedDescription)",
                category: .screenManager
            )
            loadError = await mapLoadFailure(error)
        }
    }

    private func refreshSystemAudioCaptureRequirement() async {
        let requiresCapture = await renderActor.requiresSystemAudioCapture()
        // Separates "the renderer says this scene needs no audio" from "we never
        // got to ask" — `updateSystemAudioCaptureRequirement` drops the value
        // entirely when the renderer has gone, leaving the flag false forever.
        Logger.notice(
            "[AudioCapture] session refresh: rendererSaysNeedsAudio=\(requiresCapture)"
                + " hasRenderer=\(hasRenderer) cancelled=\(Task.isCancelled)",
            category: .audioCapture
        )
        guard hasRenderer, !Task.isCancelled else { return }
        updateSystemAudioCaptureRequirement(requiresCapture)
    }

    func updateSystemAudioCaptureRequirement(_ requiresCapture: Bool) {
        guard hasRenderer else { return }
        requiresSystemAudioCapture = requiresCapture
        reconcileSystemAudioCaptureDemand()
    }

    private func reconcileSystemAudioCaptureDemand() {
        let shouldRetain = hasRenderer
            && requiresSystemAudioCapture
            && isVisible
            && userIntendsToPlay
            && effectivePerformanceProfile == .quality
        // Log which audio-tap gate is false (demand never transitioning is the interesting case).
        let inputs = "\(hasRenderer)/\(requiresSystemAudioCapture)/\(isVisible)"
            + "/\(userIntendsToPlay)/\(effectivePerformanceProfile)"
        if inputs != lastLoggedAudioDemandInputs {
            lastLoggedAudioDemandInputs = inputs
            Logger.notice(
                "[AudioCapture] session demand=\(shouldRetain)"
                    + " renderer=\(hasRenderer) sceneNeedsAudio=\(requiresSystemAudioCapture)"
                    + " visible=\(isVisible) playing=\(userIntendsToPlay)"
                    + " profile=\(effectivePerformanceProfile)",
                category: .audioCapture
            )
        }
        guard shouldRetain != audioCaptureDemandRetained else { return }
        audioCaptureDemandRetained = shouldRetain
        if shouldRetain {
            audioCaptureDemandController.retain()
        } else {
            audioCaptureDemandController.release()
        }
    }

    /// Folds a non-typed load error into a `SceneRenderingError`, pulling the
    /// renderer's `loadDiagnostics` (via the actor) when available.
    private func mapLoadFailure(_ error: Error) async -> SceneRenderingError {
        if let diagnostic = await renderActor.loadDiagnostics() {
            return .resourceFailed(diagnostic)
        }
        return .parseFailed(error.localizedDescription)
    }
}

/// Sendable diagnostic snapshot for the log sheet. Named structs (not labeled tuples)
/// — stored labeled-tuple properties crashed Swift 6.x Sendable synthesis.
struct SceneRendererDiagnostics: Sendable {
    struct ShaderErrors: Sendable {
        struct Entry: Sendable {
            let shader: String
            let reason: String
        }
        let count: Int
        let entries: [Entry]
    }
    struct GPUErrors: Sendable {
        let count: Int
        let last: String?
    }
    let loadDiagnostics: SceneLoadDiagnostic?
    let resolution: WPEResolutionDiagnosticsSnapshot
    let shaderErrors: ShaderErrors
    let gpuErrors: GPUErrors
}
#endif
