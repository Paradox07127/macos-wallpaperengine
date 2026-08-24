import AppKit
import LiveWallpaperCore
import WebKit

/// Two-stage native/JS lifecycle: one in-flight transition; rapid requests coalesce.
struct HTMLMediaLifecycleState {
    struct Transition: Equatable {
        let generation: UInt64
        let suspended: Bool
    }

    struct Completion {
        let wasCurrent: Bool
        let next: Transition?
    }

    private(set) var desiredSuspended = false
    private(set) var generation: UInt64 = 0
    private(set) var inFlight: Transition?

    mutating func request(_ suspended: Bool) -> (changed: Bool, start: Transition?) {
        guard desiredSuspended != suspended else { return (false, nil) }
        desiredSuspended = suspended
        generation &+= 1
        guard inFlight == nil else { return (true, nil) }
        let transition = Transition(generation: generation, suspended: suspended)
        inFlight = transition
        return (true, transition)
    }

    mutating func finish(_ transition: Transition) -> Completion {
        guard inFlight == transition else { return Completion(wasCurrent: false, next: nil) }
        inFlight = nil
        let wasCurrent = transition.generation == generation
            && transition.suspended == desiredSuspended
        guard !wasCurrent else { return Completion(wasCurrent: true, next: nil) }
        let next = Transition(generation: generation, suspended: desiredSuspended)
        inFlight = next
        return Completion(wasCurrent: false, next: next)
    }

    mutating func invalidate() {
        generation &+= 1
        inFlight = nil
    }
}

/// HTML runtimes whose frame pacing is a JS rAF gate rather than a display link.
/// Separate from `WallpaperFrameRateConfigurable`: that protocol also carries the
/// adaptive background throttle, which only the scene renderer is dispatched.
@MainActor
protocol HTMLWallpaperFrameRateTargeting: AnyObject {
    func setTargetFrameRate(_ limit: FrameRateLimit)
}

/// The user frame-rate ceiling translated for the web runtime.
///
/// It has to be an interval rather than a divisor of the display refresh:
/// WebKit exposes no frame-rate knob at all (no `WKWebpagePreferences` property,
/// and the media-suspension API only reaches `<video>`/`<audio>`), so the ceiling
/// lands on our own rAF gate, and 30 fps is not a whole divisor of a 136 Hz panel.
enum HTMLFramePacingPolicy {
    /// Milliseconds between allowed rAF callbacks; 0 = run at the display rate.
    static func minimumFrameIntervalMilliseconds(for limit: FrameRateLimit?) -> Double {
        guard let limit, limit != .unlimited, limit.rawValue > 0 else { return 0 }
        return 1000.0 / Double(limit.rawValue)
    }

    /// `wallpaperPropertyListener.applyGeneralProperties({fps})`. Unlimited (and
    /// "no limit pushed yet") keep reporting 60: a WPE web wallpaper reads this
    /// as its animation tempo and has no "as fast as the display" value.
    static func wallpaperEngineFPS(for limit: FrameRateLimit?) -> Int {
        guard let limit, limit != .unlimited else { return 60 }
        return limit.rawValue
    }
}

struct HTMLPreparationProbeState {
    let generation: UInt64
    let source: HTMLSource?
    let failedGeneration: UInt64?
    let completedGeneration: UInt64?
    let isCleaningUp: Bool
}

/// Binds main-frame navigation callbacks to the load generation that started them.
struct HTMLNavigationGenerationState {
    private var activeNavigationID: ObjectIdentifier?
    private var activeGeneration: UInt64?

    mutating func registerHostNavigation(
        _ navigation: AnyObject?,
        generation: UInt64
    ) {
        activeNavigationID = nil
        activeGeneration = nil
        guard let navigation else { return }
        activeNavigationID = ObjectIdentifier(navigation)
        activeGeneration = generation
    }

    /// WebKit same-origin navs skip `load`; do not reclaim host-owned identity.
    mutating func registerWebKitNavigationIfNeeded(
        _ navigation: AnyObject?,
        currentGeneration: UInt64
    ) {
        guard let navigation else { return }
        let navigationID = ObjectIdentifier(navigation)
        if activeNavigationID == navigationID {
            return
        }
        guard activeNavigationID == nil else { return }
        activeNavigationID = navigationID
        activeGeneration = currentGeneration
    }

    mutating func consumeIfCurrent(
        _ navigation: AnyObject?,
        currentGeneration: UInt64
    ) -> Bool {
        guard let navigation else { return false }
        let navigationID = ObjectIdentifier(navigation)
        guard activeNavigationID == navigationID,
              activeGeneration == currentGeneration else {
            return false
        }
        activeNavigationID = nil
        activeGeneration = nil
        return true
    }

    mutating func invalidate() {
        activeNavigationID = nil
        activeGeneration = nil
    }
}

/// Live-preview reuse gate: source/config + completed generation, not cache key alone.
struct HTMLLivePreviewCaptureState {
    let source: HTMLSource?
    let config: HTMLConfig?
    let navigationGeneration: UInt64
    let completedNavigationGeneration: UInt64?
    let failedNavigationGeneration: UInt64?
    let isCleaningUp: Bool

    func canReuse(
        requestedSource: HTMLSource,
        requestedConfig: HTMLConfig
    ) -> Bool {
        !isCleaningUp
            && source == requestedSource
            && config == requestedConfig
            && completedNavigationGeneration == navigationGeneration
            && failedNavigationGeneration != navigationGeneration
    }
}

@MainActor
enum HTMLPreparationReadiness {
    static func wait(
        timeout: Duration,
        initialGeneration: UInt64,
        source: HTMLSource?,
        currentState: @MainActor @escaping () -> HTMLPreparationProbeState?,
        captureSnapshot: @MainActor @escaping () async -> Bool
    ) async -> WallpaperPreparationResult {
        var generation = initialGeneration
        return await WallpaperPreparationWaiter.wait(
            timeout: timeout,
            pollInterval: .milliseconds(50)
        ) {
            guard let state = currentState() else { return .cancelled }
            guard !state.isCleaningUp else { return .cancelled }
            if generation != state.generation {
                // Auto-retry same source: follow new generation; source change is stale.
                guard state.source == source else { return .cancelled }
                generation = state.generation
            }
            if state.failedGeneration == generation {
                return .failed
            }
            guard state.completedGeneration == generation else {
                return nil
            }
            return await captureSnapshot() ? .ready : nil
        }
    }
}

@MainActor
extension HTMLWallpaperView {
    var livePreviewCaptureState: HTMLLivePreviewCaptureState {
        HTMLLivePreviewCaptureState(
            source: lastSource,
            config: lastAppliedConfig,
            navigationGeneration: preparationGeneration,
            completedNavigationGeneration: completedNavigationGeneration,
            failedNavigationGeneration: failedPreparationGeneration,
            isCleaningUp: isCleaningUp
        )
    }

    func retryCurrentSource(timeout: Duration) async -> WallpaperPreparationResult {
        guard let lastSource else { return .failed }
        guard !isCleaningUp else { return .cancelled }
        // User entry resets backoff so Retry is not a single-shot after exhaust.
        loadSourceForUserRetry(lastSource)
        return await prepareForDisplay(timeout: timeout)
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        let generation = preparationGeneration
        let source = lastSource
        return await HTMLPreparationReadiness.wait(
            timeout: timeout,
            initialGeneration: generation,
            source: source,
            currentState: { [weak self] in
                guard let self else { return nil }
                return HTMLPreparationProbeState(
                    generation: self.preparationGeneration,
                    source: self.lastSource,
                    failedGeneration: self.failedPreparationGeneration,
                    completedGeneration: self.completedNavigationGeneration,
                    isCleaningUp: self.isCleaningUp
                )
            },
            captureSnapshot: { [weak self] in
                guard let self else { return false }
                return await self.capturePreparationSnapshot()
            }
        )
    }

    private func capturePreparationSnapshot() async -> Bool {
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        configuration.snapshotWidth = NSNumber(value: Double(min(64, bounds.width)))
        configuration.afterScreenUpdates = true
        let gate = WallpaperPreparationContinuationGate<Bool>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                webView.takeSnapshot(with: configuration) { image, _ in
                    Task { @MainActor in
                        gate.resolve(image != nil)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                gate.resolve(false)
            }
        }
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        setMediaPlaybackSuspended(profile == .suspended)
    }

    /// User frame-rate ceiling. Deliberately not folded into the performance
    /// profile: `.suspended` stops the page, this only slows it down, and a
    /// suspended view must keep the target so the resume publishes it rather
    /// than snapping back to 60.
    func setTargetFrameRate(_ limit: FrameRateLimit) {
        guard !isCleaningUp, targetFrameRateLimit != limit else { return }
        targetFrameRateLimit = limit
        // Pushed even while suspended: the JS side stores the value behind its
        // own suspend guard and reconciles the wrapper on resume.
        applyRafTargetFrameInterval(
            HTMLFramePacingPolicy.minimumFrameIntervalMilliseconds(for: limit)
        )
        guard !mediaPlaybackSuspended else { return }
        notifyWallpaperEngineGeneralProperties(
            fps: HTMLFramePacingPolicy.wallpaperEngineFPS(for: limit)
        )
    }

    func applyRafTargetFrameInterval(_ milliseconds: Double) {
        guard !isCleaningUp,
              milliseconds != lastRafTargetFrameIntervalMilliseconds else { return }
        lastRafTargetFrameIntervalMilliseconds = milliseconds
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.rafTargetFrameInterval(milliseconds: milliseconds),
            completionHandler: nil
        )
    }

    /// Native+JS suspend/resume; generation-ordered. The JS half reaches
    /// subframes through the main frame's relay (`broadcastToChildFrames`).
    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        guard !isCleaningUp else { return }
        let request = mediaLifecycleState.request(suspended)
        guard request.changed else { return }
        reloadScheduler.setSuspended(suspended)

        if suspended {
            cancelPackageBackingForSuspend()
            // Mid-restore the cover is already up and the reload is still in
            // flight; snapshotting now would capture a blank document, and the
            // phase has to stay hibernatable so the dwell can arm again.
            hibernationState.noteSuspendedDuringRestore()
            restoreCoverDeadlineTask?.cancel()
            restoreCoverDeadlineTask = nil
            captureSuspendSnapshot()
            notifyWallpaperEngineGeneralProperties(fps: 1)
        } else {
            hibernationDwell.cancel()
            switch hibernationState.requestRestore() {
            case .rebuild:
                restartPackageBackingAfterResume = false
                // The overlay is stacked above the web view, so un-hiding it now
                // lets the rebuilt document paint under cover; `didFinish` drops
                // the cover. Calling `hideSnapshotOverlay()` here would expose
                // the `about:blank` we hibernated onto.
                webView.isHidden = false
                reloadCurrentSource()
                armRestoreCoverDeadline()
            case .keepCover:
                // Restore already running underneath; uncovering here is exactly
                // the blank-desktop regression.
                break
            default:
                hideSnapshotOverlay()
            }
        }

        if let transition = request.start {
            runMediaLifecycleTransition(transition)
        }
    }

    /// Only `didFinish` drops the cover, and several `loadSource` exits report an
    /// error without starting a navigation at all (a folder bookmark that went
    /// stale while the volume was unmounted during the absence). Without a bound
    /// the desktop stays frozen on the pre-absence snapshot, and because
    /// `setHibernationEligible` requires `.live`, the screen also never
    /// hibernates again. Mirrors the still-frame deadline on the video player.
    private func armRestoreCoverDeadline() {
        restoreCoverDeadlineTask?.cancel()
        let generation = hibernationState.generation
        restoreCoverDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.restoreCoverDeadline)
            guard !Task.isCancelled,
                  let self,
                  !isCleaningUp,
                  // A suspend that landed during the restore put its own cover up
                  // and warm suspend depends on it staying: dropping it here would
                  // un-freeze a wallpaper the user cannot see.
                  !mediaPlaybackSuspended,
                  hibernationState.generation == generation,
                  hibernationState.phase == .restoring else { return }
            Logger.warning(
                "HTML wallpaper restore never painted; dropping the hibernation cover",
                category: .screenManager
            )
            // Back to `.live` so a later absence can hibernate this screen again.
            hibernationState.invalidate()
            hideSnapshotOverlay()
        }
    }

    // MARK: - Absence-dwell hibernation

    /// `ScreenManager` marks the view eligible while it is suspended for an
    /// absence-like reason (lock, display sleep, full-screen cover/occlusion) —
    /// the same signal `SceneWallpaperSession.setHibernationEligible` takes. An
    /// app-rule or battery pause stays a warm suspend.
    /// `immediately` is the manual-pause handover: that countdown has already
    /// run its full term in the session, and re-running this one after it made
    /// a paused HTML wallpaper hold its resources longer than a paused scene.
    func setHibernationEligible(_ eligible: Bool, immediately: Bool = false) {
        hibernationEligible = eligible
        guard eligible,
              !isCleaningUp,
              mediaPlaybackSuspended,
              lastSource != nil,
              hibernationState.phase == .live else {
            hibernationDwell.cancel()
            return
        }
        hibernationDwell.arm(
            initial: immediately ? .zero : HTMLWallpaperView.hibernationDwell,
            retry: HTMLWallpaperView.hibernationDwell
        ) { [weak self] in
            guard let self else { return true }
            return beginHibernationIfEligible()
        }
    }

    /// Re-read when the cover reply lands, not captured when it was requested:
    /// the snapshot is asynchronous, and a pressure clear arriving inside that
    /// window used to release a manually paused wallpaper that still had most of
    /// its 300s warm dwell left. `generation` already rejects a reply that
    /// crossed a wake; eligibility is the dimension it does not cover.
    var stillWantsHibernation: Bool {
        !isCleaningUp && mediaPlaybackSuspended && hibernationEligible
    }

    /// Re-checks across the dwell — cancellation races the sleep waking up.
    /// Returns false only for a transient blocker so the dwell re-arms: a restore
    /// in flight will finish, and dropping the countdown there would skip the rest
    /// of the absence (eligibility is pushed on policy changes, never polled).
    @discardableResult
    private func beginHibernationIfEligible() -> Bool {
        guard !isCleaningUp, mediaPlaybackSuspended, lastSource != nil else { return true }
        if hibernationState.phase == .restoring { return false }
        guard hibernationState.begin() == .presentCover else { return true }
        let generation = hibernationState.generation
        presentHibernationCover { [weak self] presented in
            guard let self else { return }
            let covered = presented && self.stillWantsHibernation
            guard self.hibernationState.coverDidPresent(covered, generation: generation)
                == .releaseResources else { return }
            self.dropDocumentForHibernation()
        }
        // The cover request is now the owner of the outcome — a snapshot failure
        // is handled inside that completion, not by re-dwelling here.
        return true
    }

    /// Reuses the suspend overlay when it is already covering: re-snapshotting a
    /// hidden web view is what would hand back an empty image.
    private func presentHibernationCover(completion: @MainActor @escaping (Bool) -> Void) {
        guard !isSnapshotOverlayPresenting else {
            completion(true)
            return
        }
        captureSuspendSnapshot { [weak self] _ in
            // Report what is on screen, not this capture's own result: a
            // concurrent suspend-path capture may have won the generation.
            completion(self?.isSnapshotOverlayPresenting ?? false)
        }
    }

    private func dropDocumentForHibernation() {
        webView.stopLoading()
        reloadScheduler.cancelRetry()
        // Register the teardown navigation, then advance past its generation so
        // its `didFinish` cannot be mistaken for the source becoming ready.
        navigationGenerationState.registerHostNavigation(
            webView.load(URLRequest(url: Self.aboutBlank)),
            generation: preparationGeneration
        )
        preparationGeneration &+= 1
        completedNavigationGeneration = nil
        failedPreparationGeneration = nil
    }

    private func runMediaLifecycleTransition(
        _ transition: HTMLMediaLifecycleState.Transition
    ) {
        guard !isCleaningUp else { return }
        if transition.suspended {
            invokeLifecycleHook(.suspend) { [weak self] in
                self?.setNativeMediaPlaybackSuspended(
                    true,
                    transition: transition
                )
            }
        } else {
            setNativeMediaPlaybackSuspended(false, transition: transition)
        }
    }

    private func setNativeMediaPlaybackSuspended(
        _ suspended: Bool,
        transition: HTMLMediaLifecycleState.Transition
    ) {
        webView.setAllMediaPlaybackSuspended(suspended) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if suspended {
                    self.finishMediaLifecycleTransition(transition)
                } else {
                    self.invokeLifecycleHook(.resume) { [weak self] in
                        self?.finishMediaLifecycleTransition(transition)
                    }
                }
            }
        }
    }

    private func cancelPackageBackingForSuspend() {
        guard packageBackingTask != nil else { return }
        packageBackingGeneration &+= 1
        packageBackingTask?.cancel()
        packageBackingTask = nil
        restartPackageBackingAfterResume = true
    }

    private func finishMediaLifecycleTransition(
        _ transition: HTMLMediaLifecycleState.Transition
    ) {
        guard !isCleaningUp else { return }
        let completion = mediaLifecycleState.finish(transition)

        if completion.wasCurrent, !transition.suspended {
            notifyWallpaperEngineGeneralProperties(
                fps: HTMLFramePacingPolicy.wallpaperEngineFPS(for: targetFrameRateLimit)
            )
            applyRafThrottleRatio(rafThrottleRatio(for: ProcessInfo.processInfo.thermalState))
            if restartPackageBackingAfterResume {
                restartPackageBackingAfterResume = false
                reloadCurrentSource()
            }
        }
        if let next = completion.next {
            runMediaLifecycleTransition(next)
        }
    }

    enum LifecycleHook: String {
        case suspend = "__lwSuspend__"
        case resume = "__lwResume__"
    }

    func invokeLifecycleHook(
        _ hook: LifecycleHook,
        completion: @MainActor @escaping () -> Void = {}
    ) {
        webView.evaluateJavaScript(
            "if (typeof window.\(hook.rawValue) === 'function') { try { window.\(hook.rawValue)(); } catch (e) {} }"
        ) { _, _ in
            Task { @MainActor in
                completion()
            }
        }
    }

    func notifyWallpaperEngineGeneralProperties(fps: Int) {
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties(fps: fps),
            completionHandler: nil
        )
    }

    /// `.fair` RAF throttle — global quality policy does not cover this tier.
    func startObservingThermalState() {
        let token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyRafThrottleRatio(
                    self.rafThrottleRatio(for: ProcessInfo.processInfo.thermalState)
                )
            }
        }
        thermalObserver = token
    }

    func rafThrottleRatio(for thermalState: ProcessInfo.ThermalState) -> Int {
        switch thermalState {
        case .nominal: 1
        case .fair: 2
        // Was 1 (full speed) back when `.serious` suspended the wallpaper
        // outright, so the ratio never applied. Now that serious only throttles,
        // running faster than `.fair` while hotter would invert the whole point.
        case .serious: 4
        case .critical: 4
        @unknown default: 4
        }
    }

    func applyRafThrottleRatio(_ ratio: Int) {
        guard !isCleaningUp, ratio != lastRafThrottleRatio else { return }
        lastRafThrottleRatio = ratio
        webView.evaluateJavaScript(
            "if (typeof window.__lwSetRafThrottle__ === 'function') { try { window.__lwSetRafThrottle__(\(ratio)); } catch (e) {} }",
            completionHandler: nil
        )
    }
}

extension HTMLWallpaperView: HTMLWallpaperRetrying {}

extension HTMLWallpaperView: HTMLWallpaperFrameRateTargeting {}

extension HTMLWallpaperView: WallpaperHibernationEligible {}
