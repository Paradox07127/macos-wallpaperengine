#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

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

/// Last write wins on the actor channel; apply has one-frame latency.
@MainActor
final class WPERendererConfigAdapter: WallpaperPerformanceConfigurable, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable {
    private let renderActor: WPEDisplayRenderActor

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        renderActor.submitConfig(.performanceProfile(profile))
    }

    func setFrameRateCeiling(_ framesPerSecond: Int) {
        renderActor.submitConfig(.frameRateCeiling(framesPerSecond))
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

@MainActor
final class SceneWallpaperSession: WallpaperRuntimeSession, WallpaperPlaybackControllable, WallpaperIntentMachineAdopting {
    let wallpaperType: WallpaperType = .scene

    private var window: NSWindow?
    private let renderActor: WPEDisplayRenderActor
    private let scenePropertyMutationAuthority = ScenePropertyMutationAuthority()
    private let scenePropertyPosterCommitGate = ScenePropertyPosterCommitGate()
    private let surface: WPERenderSurface
    private let rendererConfigAdapter: WPERendererConfigAdapter
    /// True while a renderer is adopted (construction → cleanup).
    private var hasRenderer = true
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var previewProfileOverride: WallpaperPerformanceProfile?
    private var lastAppliedPerformanceProfile: WallpaperPerformanceProfile?
    private var requiresSystemAudioCapture = false
    private var lastLoggedAudioDemandInputs = ""

    private var audioCaptureDemandRetained = false
    private let audioCaptureDemandController: any SystemAudioCaptureDemandControlling
    private(set) var isHibernated = false
    private let hibernationDelay: Duration
    /// Manual pause is not an absence; uses its own longer dwell, not the absence constant.
    private let userPauseHibernationDelay: Duration
    private let wakeRetryDelay: Duration
    private let absenceDwell = AbsenceDwell()
    private let pauseDwell = AbsenceDwell()
    private let pressureDwell = AbsenceDwell()
    private var wakeTask: Task<Void, Never>?
    /// Nil until the first publish; treat nil as "may be working".
    private(set) var rendererRuntimeActivity: WPESceneRuntimeActivity?
    var onRuntimeActivityChange: (@MainActor () -> Void)?
    var playbackMachine = WallpaperPlaybackStateMachine()
    var userIntendsToPlay: Bool { playbackMachine.userIntendsToPlay }
    private var didStartLoad = false
    private var loadTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    /// Guards clearing loadTask so a finished older task cannot drop a newer one.
    private var loadGeneration = 0
    private(set) var loadFailureCause: WallpaperFailureCause?
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

    func pollRendererState() async {
        guard let snapshot = await renderActor.rendererStateSnapshot() else {
            hasPresentedFrame = nil
            rendererDiagnostics = nil
            return
        }
        cacheRendererState(snapshot)
    }

    private func cacheRendererState(_ snapshot: WPERendererStateSnapshot) {
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

    func captureLivePosterFromNextFrame() async -> NSImage? {
        await renderActor.captureLivePoster()
    }

    /// .quality clears the override; it does not force play over a folded suspension.
    func applyPreviewPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        previewProfileOverride = profile == .quality ? nil : profile
        applyEffectivePerformanceProfile()
    }

    func clearPreviewPerformanceOverride() {
        previewProfileOverride = nil
        applyEffectivePerformanceProfile()
    }

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

    /// Side-effect-free; do not apply until MainActor persists and commitScenePropertyPatch.
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

    /// Does not re-check proposal intent: a later no-op must not cancel a persisted delivery.
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
        // Honour userIntendsToPlay — a manual pause must not resume on visibility alone.
        applyEffectivePerformanceProfile()
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        applyEffectivePerformanceProfile()
    }

    private func applyEffectivePerformanceProfile() {
        let effective = effectivePerformanceProfile
        if effective == .quality {
            absenceDwell.cancel()
            pressureDwell.cancel()
        }
        if lastAppliedPerformanceProfile != effective {
            lastAppliedPerformanceProfile = effective
            rendererConfigAdapter.applyPerformanceProfile(effective)
        }
        if effective == .quality, isHibernated {
            isHibernated = false
            // Cancel the earlier wake: left alive it would reload on top of this one and restore isHibernated behind it.
            wakeTask?.cancel()
            wakeTask = Task { [weak self] in
                await self?.reloadForWake()
            }
        }
        reconcileManualPauseHibernation()
        reconcileSystemAudioCaptureDemand()
    }

    private func reloadForWake() async {
        await reload()
        guard loadError != nil else { return }
        do {
            try await Task.sleep(for: wakeRetryDelay)
        } catch {
            return
        }
        // Giving up while still broken must restore isHibernated, or later play is a no-op.
        guard hasRenderer, effectivePerformanceProfile == .quality, loadError != nil else {
            if hasRenderer, loadError != nil { isHibernated = true }
            return
        }
        await reload()
        if loadError != nil { isHibernated = true }
    }

    // MARK: - Deep hibernate (resource depth of the suspend path, not a profile)

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

    /// Skip the dwell and release now. Own slot so setHibernationEligible(false) cannot cancel it.
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

    /// User-paused is not an absence; own dwell, never the absence slot. Repeats are idempotent.
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

    func noteRendererRuntimeActivity(_ activity: WPESceneRuntimeActivity) {
        guard activity != rendererRuntimeActivity else { return }
        rendererRuntimeActivity = activity
        onRuntimeActivityChange?()
    }

    /// Conservative: true until the first activity push (nil means may be working).
    var mayPerformRuntimeWork: Bool {
        guard let rendererRuntimeActivity else { return true }
        return rendererRuntimeActivity.producesFrames
            || rendererRuntimeActivity.audible
            || loadTask != nil
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        renderActor.submitConfig(.mouseInteractionEnabled(enabled))
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        (window as? VideoWallpaperWindow)?.setWallpaperMouseInteractionEnabled(enabled)
        renderActor.submitConfig(.clickCaptureEnabled(enabled))
    }

    func setSceneFitMode(_ mode: VideoFitMode) {
        renderActor.submitConfig(.presentFitMode(WPEPresentFitMode(mode)))
    }

    func startAdoptingRenderer(_ handoff: WPERendererHandoff) {
        let generation = lifecycleGeneration
        startupTask = Task { [weak self, renderActor] in
            await renderActor.adopt(handoff.renderer)
            // If cleanup raced the adopt hop, skip the load; cleanup still releases the adopted renderer.
            guard let self, self.isCurrentLifecycle(generation) else { return }
            await self.beginLoad()
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        lifecycleGeneration == generation
    }

    func cleanup() {
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
        let displayLinkStopTask = surface.stopDisplayLinkDriver()
        window?.close()
        window = nil
        let actor = renderActor
        let startup = startupTask
        let load = loadTask
        startupTask = nil
        loadTask?.cancel()
        loadTask = nil
        // cleanup() is sync; drain happens in the retained task so teardown cannot overtake adopt/load.
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
            // Async join: a wedged render thread must cost a leaked thread, never a frozen main thread.
            await actor.shutdown()
        }
    }

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
            cacheRendererState(snapshot)
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
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.renderActor.reload()
                guard self.loadGeneration == generation else { return }
                await self.refreshSystemAudioCaptureRequirement()
                loadFailureCause = nil
                self.loadError = nil
                self.loadProgress = nil
            } catch is CancellationError {
                return
            } catch let error as SceneRenderingError {
                guard self.loadGeneration == generation else { return }
                self.loadFailureCause = SceneFailureCause.make(error)
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
            loadFailureCause = nil
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
            loadFailureCause = SceneFailureCause.make(error)
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
        let inputs = "\(hasRenderer)/\(requiresSystemAudioCapture)"
            + "/\(userIntendsToPlay)/\(effectivePerformanceProfile)"
        if inputs != lastLoggedAudioDemandInputs {
            lastLoggedAudioDemandInputs = inputs
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

    private func mapLoadFailure(_ error: Error) async -> SceneRenderingError {
        let cause = SceneFailureCause.make(error)
        loadFailureCause = cause
        if let diagnostic = await renderActor.loadDiagnostics() {
            loadFailureCause = SceneFailureCause.make(diagnostic)
            return .resourceFailed(diagnostic)
        }
        if error is WPESceneDocumentError {
            return .parseFailed(error.localizedDescription)
        }
        return .resourceFailed(.other(layer: "scene", message: cause.reason))
    }
}

/// Named structs, not labeled tuples: stored labeled-tuple properties would crash Swift 6.x Sendable synthesis.
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
