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

/// Absence-dwell teardown: the resource depth of the suspend path (same signal
/// and dwell as `SceneWallpaperSession`), not a third performance profile.
/// Ordering is the whole point — the snapshot overlay has to be covering before
/// the live document is dropped, or the desktop flashes blank (the same failure
/// that keeps `aggressiveSuspend` opt-in).
struct HTMLHibernationState {
    enum Phase: Equatable {
        case live
        case hibernated
        case restoring
    }

    /// `loadAboutBlank` is only ever returned by `snapshotDidPresent(_:generation:)`
    /// with `presented == true`, never by `beginHibernation()`.
    enum Step: Equatable {
        case presentSnapshotOverlay
        case loadAboutBlank
        case reloadSource
    }

    private(set) var phase: Phase = .live
    /// Bumped by every resume and every source load so a snapshot reply that
    /// lands after a wake cannot drop the document that wake just rebuilt.
    private(set) var generation: UInt64 = 0
    private(set) var isCoveringForHibernation = false

    mutating func beginHibernation() -> Step? {
        guard phase == .live, !isCoveringForHibernation else { return nil }
        isCoveringForHibernation = true
        return .presentSnapshotOverlay
    }

    mutating func snapshotDidPresent(_ presented: Bool, generation: UInt64) -> Step? {
        guard isCoveringForHibernation, self.generation == generation else { return nil }
        isCoveringForHibernation = false
        guard presented, phase == .live else { return nil }
        phase = .hibernated
        return .loadAboutBlank
    }

    /// Any source load other than the `about:blank` teardown puts a real
    /// document back; a restore in flight keeps its phase until it paints.
    mutating func noteSourceLoad() {
        isCoveringForHibernation = false
        generation &+= 1
        if phase == .hibernated { phase = .live }
    }

    mutating func requestRestore() -> Step? {
        isCoveringForHibernation = false
        generation &+= 1
        guard phase == .hibernated else {
            phase = .live
            return nil
        }
        phase = .restoring
        return .reloadSource
    }

    /// True once, when the rebuilt document has painted and the cover can go.
    mutating func didRestore() -> Bool {
        guard phase == .restoring else { return false }
        phase = .live
        return true
    }

    mutating func invalidate() {
        phase = .live
        isCoveringForHibernation = false
        generation &+= 1
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

    /// Native+JS suspend/resume; generation-ordered. The JS half reaches
    /// subframes through the main frame's relay (`broadcastToChildFrames`).
    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        guard !isCleaningUp else { return }
        let request = mediaLifecycleState.request(suspended)
        guard request.changed else { return }
        reloadScheduler.setSuspended(suspended)

        if suspended {
            cancelPackageBackingForSuspend()
            captureSuspendSnapshot()
            notifyWallpaperEngineGeneralProperties(fps: 1)
        } else {
            hibernationTask?.cancel()
            hibernationTask = nil
            if hibernationState.requestRestore() == .reloadSource {
                restartPackageBackingAfterResume = false
                // The overlay is stacked above the web view, so un-hiding it now
                // lets the rebuilt document paint under cover; `didFinish` drops
                // the cover. Calling `hideSnapshotOverlay()` here would expose
                // the `about:blank` we hibernated onto.
                webView.isHidden = false
                reloadCurrentSource()
                armRestoreCoverDeadline()
            } else {
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
    func setHibernationEligible(_ eligible: Bool) {
        guard eligible,
              !isCleaningUp,
              mediaPlaybackSuspended,
              lastSource != nil,
              hibernationState.phase == .live else {
            hibernationTask?.cancel()
            hibernationTask = nil
            return
        }
        guard hibernationTask == nil else { return }
        hibernationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: HTMLWallpaperView.hibernationDwell)
            guard !Task.isCancelled, let self else { return }
            self.hibernationTask = nil
            self.beginHibernationIfEligible()
        }
    }

    /// Re-checks across the dwell — cancellation races the sleep waking up.
    private func beginHibernationIfEligible() {
        guard !isCleaningUp, mediaPlaybackSuspended, lastSource != nil else { return }
        guard hibernationState.beginHibernation() == .presentSnapshotOverlay else { return }
        let generation = hibernationState.generation
        presentHibernationCover { [weak self] presented in
            guard let self else { return }
            let covered = presented && !self.isCleaningUp && self.mediaPlaybackSuspended
            guard self.hibernationState.snapshotDidPresent(covered, generation: generation)
                == .loadAboutBlank else { return }
            self.dropDocumentForHibernation()
        }
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
            notifyWallpaperEngineGeneralProperties(fps: 60)
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
        case .serious, .critical: 1
        @unknown default: 1
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
