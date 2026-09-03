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
final class SceneWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable, WallpaperIntentMachineAdopting {
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
    /// Deep hibernate (P1.5): while suspended for an absence-like reason the
    /// renderer's loaded resources are dropped after `hibernationDelay`; waking
    /// runs a full `reload()`. Session-level flag — the renderer's own state is
    /// simply "not loaded" while hibernated.
    private(set) var isHibernated = false
    private let hibernationDelay: Duration
    /// Manual pause is not an absence: the user may look at the frozen frame and
    /// unpause any moment, so it gets its own much longer dwell (M4a) instead of
    /// reusing the absence constant. Wake is a normal reload; seconds of latency
    /// on unpause are accepted.
    private let userPauseHibernationDelay: Duration
    /// Wake is the one load the user never triggered, so a failure there has no
    /// one to press retry: it looks like the wallpaper just died on unlock.
    /// Video (`stillFrameWakeDeadlineSeconds`) and HTML (`restoreCoverDeadline`)
    /// both force themselves back to live on a deadline; this is Scene's.
    private let wakeRetryDelay: Duration
    private let absenceDwell = AbsenceDwell()
    private let pauseDwell = AbsenceDwell()
    private let pressureDwell = AbsenceDwell()
    /// Retains the wake reload spawned on the suspended→quality transition so
    /// `cleanup()` can cancel it.
    private var wakeTask: Task<Void, Never>?
    /// Latest renderer activity mirror (frame/audio work under `.quality`).
    /// Nil until the renderer's first publish; consumers treat nil as "may be
    /// working" so the App Nap gate errs on holding.
    private(set) var rendererRuntimeActivity: WPESceneRuntimeActivity?
    var onRuntimeActivityChange: (@MainActor () -> Void)?
    /// Single source of truth for durable user play intent; effective =
    /// `userIntendsToPlay && profile == .quality`. Self-built so an
    /// independently constructed session stands alone; `ScreenManager` swaps in
    /// the screen's shared machine via `adoptPlaybackStateMachine` on install.
    var playbackMachine = WallpaperPlaybackStateMachine()
    var userIntendsToPlay: Bool { playbackMachine.userIntendsToPlay }
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
        audioCaptureDemandController: any SystemAudioCaptureDemandControlling = SystemAudioCaptureManager.shared,
        hibernationDelay: Duration = .seconds(20),
        userPauseHibernationDelay: Duration = ManualPauseHibernation.delay,
        wakeRetryDelay: Duration = .seconds(10)
    ) {
        self.window = window
        self.renderActor = renderActor
        self.surface = surface
        self.rendererConfigAdapter = WPERendererConfigAdapter(renderActor: renderActor)
        self.audioCaptureDemandController = audioCaptureDemandController
        self.hibernationDelay = hibernationDelay
        self.userPauseHibernationDelay = userPauseHibernationDelay
        self.wakeRetryDelay = wakeRetryDelay
    }

    private var effectivePerformanceProfile: WallpaperPerformanceProfile {
        guard userIntendsToPlay,
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
        } else if effectivePerformanceProfile == .suspended {
            // Still intending to play means something else is holding it down.
            activity = userIntendsToPlay ? .policySuspended : .paused
        } else {
            activity = .active
        }
        return WallpaperSessionSummary(
            wallpaperType: .scene,
            activity: activity,
            supportsPlaybackControl: true,
            subtitle: loadError?.errorDescription.map(LogPrivacyRedactor.scrub)
        )
    }

    var isPlaying: Bool {
        effectivePerformanceProfile == .quality
    }

    func play() {
        playbackMachine.userPlay()
        applyEffectivePerformanceProfile()
    }

    func pause() {
        playbackMachine.userPause()
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
        posterCommit: ScenePropertyPosterCommit,
        updatedDescriptor: SceneDescriptor
    ) async -> Bool {
        let didCommit = await renderActor.commitScenePropertyPatch(
            prepared, updatedDescriptor: updatedDescriptor
        )
        scenePropertyPosterCommitGate.resolve(posterCommit, result: didCommit)
        return didCommit
    }

    // Nil-when-no-renderer semantics preserved: consumers guard on this, and a
    // torn-down session must report no controller.
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
        window?.orderBack(nil)
        // Route through the session so the effective profile honours
        // `userIntendsToPlay` — a manually paused scene must not resume just
        // because it became visible again (space switch / display wake).
        applyEffectivePerformanceProfile()
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        applyEffectivePerformanceProfile()
    }

    private func applyEffectivePerformanceProfile() {
        let effective = effectivePerformanceProfile
        if effective == .quality {
            // Any transition to playing cancels the pending hibernate countdowns.
            absenceDwell.cancel()
            pressureDwell.cancel()
        }
        if lastAppliedPerformanceProfile != effective {
            lastAppliedPerformanceProfile = effective
            rendererConfigAdapter.applyPerformanceProfile(effective)
        }
        if effective == .quality, isHibernated {
            isHibernated = false
            // This wake supersedes any earlier one still waiting out its retry: left alive,
            // that one would reload on top of this wake and — when its reload failed — restore
            // `isHibernated` behind this wake's back. The replacement below inherits the
            // give-up restore, so cancelling here doesn't drop it.
            wakeTask?.cancel()
            // Rebuild everything hibernate dropped; the profile command above
            // (or the load tail's re-apply) restores pacing once loaded.
            wakeTask = Task { [weak self] in
                await self?.reloadForWake()
            }
        }
        reconcileManualPauseHibernation()
        reconcileSystemAudioCaptureDemand()
    }

    /// Wake reload plus one delayed retry. Bounded at two attempts: a scene that
    /// fails twice is failing for a reason waiting cannot fix, and the inspector's
    /// manual retry stays the escape hatch.
    private func reloadForWake() async {
        await reload()
        guard loadError != nil else { return }
        do {
            try await Task.sleep(for: wakeRetryDelay)
        } catch {
            return
        }
        // Give up if the wallpaper stopped being wanted while we waited (paused again, policy
        // re-suspended, session torn down) — or if a manual retry already healed it. Giving up
        // while still broken has to restore the hibernated flag: the wake path is gated on it,
        // so leaving it false would make every later play a no-op and strand the scene in
        // `loadError` with no automatic way back.
        guard hasRenderer, effectivePerformanceProfile == .quality, loadError != nil else {
            if hasRenderer, loadError != nil { isHibernated = true }
            return
        }
        await reload()
        if loadError != nil { isHibernated = true }
    }

    // MARK: - Deep hibernate (resource depth of the suspend path, not a profile)

    /// `ScreenManager` marks the session eligible while it is suspended for an
    /// absence-like reason (lock, display sleep, full-screen cover/occlusion).
    /// After `hibernationDelay` of uninterrupted eligibility the renderer's
    /// loaded resources are released; any flip back cancels the countdown.
    func setHibernationEligible(_ eligible: Bool) {
        guard eligible,
              hasRenderer,
              !isHibernated,
              effectivePerformanceProfile == .suspended else {
            absenceDwell.cancel()
            return
        }
        absenceDwell.arm(initial: hibernationDelay, retry: hibernationDelay) {
            [weak self] in
            guard let self else { return true }
            return await hibernateNow()
        }
    }

    /// Critical system memory pressure: skip the dwell and release renderer resources now
    /// (policy has already suspended the session). Own slot so a routine
    /// `setHibernationEligible(false)` push cannot cancel it. Takes the level as state, not a
    /// one-shot trigger: the retry cadence must not outlive the emergency — armed-and-blocked
    /// (in-flight load) plus a return to normal used to leave the 1s retry running, which then
    /// hibernated a session suspended for an unrelated reason, bypassing the manual-pause and
    /// absence dwells entirely.
    func setCriticalMemoryPressureActive(_ active: Bool) {
        guard active else {
            pressureDwell.cancel()
            return
        }
        guard hasRenderer,
              !isHibernated,
              effectivePerformanceProfile == .suspended else { return }
        // Non-zero retry: an in-flight load makes `hibernateNow` return false,
        // and a zero-dwell retry would spin until the load finishes.
        pressureDwell.arm(initial: .zero, retry: .seconds(1)) { [weak self] in
            guard let self else { return true }
            return await hibernateNow()
        }
    }

    /// Second hibernatable class (M4a): a user-paused wallpaper is not an
    /// absence, so it keeps its own dwell and never touches the absence slot.
    /// Called from every effective-profile fold; the slot guard makes repeats
    /// idempotent instead of restarting the countdown.
    private func reconcileManualPauseHibernation() {
        guard !userIntendsToPlay,
              hasRenderer,
              !isHibernated else {
            pauseDwell.cancel()
            return
        }
        pauseDwell.arm(
            initial: userPauseHibernationDelay,
            retry: userPauseHibernationDelay
        ) { [weak self] in
            guard let self else { return true }
            return await hibernateNow()
        }
    }

    /// Returns false only on a transient blocker (an in-flight load/reload) so
    /// the countdown re-arms; true when hibernated or no longer applicable.
    private func hibernateNow() async -> Bool {
        guard hasRenderer,
              !isHibernated,
              effectivePerformanceProfile == .suspended else { return true }
        // Never tear down under an in-flight load/reload.
        guard loadTask == nil else { return false }
        let hibernated = await renderActor.hibernate()
        guard hibernated, hasRenderer else { return true }
        if effectivePerformanceProfile == .quality {
            // Woken while the actor hop was in flight: rebuild immediately.
            await reload()
        } else {
            isHibernated = true
        }
        return true
    }

    // MARK: - Runtime-activity mirror (App Nap gate)

    /// Renderer push (dedup'd on its side); forwarded so `ScreenManager` can
    /// re-evaluate the App Nap assertion on real transitions only.
    func noteRendererRuntimeActivity(_ activity: WPESceneRuntimeActivity) {
        guard activity != rendererRuntimeActivity else { return }
        rendererRuntimeActivity = activity
        onRuntimeActivityChange?()
    }

    /// Whether this session may be doing real work under `.quality` — the App
    /// Nap assertion should stay held. Conservative: true until the renderer's
    /// first activity push, and while a load/reload is in flight (preparing).
    var mayPerformRuntimeWork: Bool {
        guard let rendererRuntimeActivity else { return true }
        return rendererRuntimeActivity.producesFrames
            || rendererRuntimeActivity.audible
            || loadTask != nil
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

    func setSceneFitMode(_ mode: VideoFitMode) {
        renderActor.submitConfig(.presentFitMode(WPEPresentFitMode(mode)))
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
        let wake = wakeTask
        wakeTask?.cancel()
        wakeTask = nil
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
            // A hibernate/wake may be mid-flight on the actor with no other
            // drainable handle; teardown must not overtake it.
            await absenceDwell.drain()
            await pauseDwell.drain()
            await pressureDwell.drain()
            await wake?.value
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
        // A reload rebuilds everything hibernate dropped, whatever triggered it.
        isHibernated = false
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
        // Console-only, but kept: it is the only record that separates "the
        // renderer answered, and the answer was no" from "the answer was
        // discarded because the renderer went away", which the guard below
        // makes indistinguishable downstream.
        Logger.info(
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
            && userIntendsToPlay
            && effectivePerformanceProfile == .quality
        // Log which audio-tap gate is false (demand never transitioning is the interesting case).
        let inputs = "\(hasRenderer)/\(requiresSystemAudioCapture)"
            + "/\(userIntendsToPlay)/\(effectivePerformanceProfile)"
        if inputs != lastLoggedAudioDemandInputs {
            lastLoggedAudioDemandInputs = inputs
            // Console-only: the dedupe key includes `effectivePerformanceProfile`,
            // which flips on every app switch, so this can never be quiet enough
            // for the file. `SystemAudioCaptureService` records the real outcome.
            Logger.info(
                "[AudioCapture] session demand=\(shouldRetain)"
                    + " renderer=\(hasRenderer) sceneNeedsAudio=\(requiresSystemAudioCapture)"
                    + " playing=\(userIntendsToPlay)"
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
