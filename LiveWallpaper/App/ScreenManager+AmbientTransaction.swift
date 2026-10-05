import CoreGraphics
import Foundation
import LiveWallpaperCore

typealias WallpaperPreparationCompletion = @MainActor (WallpaperPreparationResult, WallpaperFailureSnapshot?) -> Void

@MainActor
extension ScreenManager {
    func commitPreparedAmbientConfiguration(
        proposed: ScreenConfiguration,
        effective: ScreenConfiguration,
        screenID: CGDirectDisplayID,
        ownerCommit: @MainActor () -> Bool
    ) -> Bool {
        guard ownerCommit() else { return false }
        if effective != proposed,
           configurationStore.get(for: screenID) != effective {
            saveConfiguration(effective)
        }
        return true
    }

    func retireOutgoingVideoWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer?
    ) {
        transitionRegistry.cancelAssetReadiness(for: screenID)
        guard let player, effectsCoordinatorWasInitialized else { return }
        effectsCoordinator.retireWork(for: screenID, player: player)
    }

    @discardableResult
    func beginPreparedAmbientSession(
        _ candidate: any WallpaperRuntimeSession,
        for screen: Screen,
        replacing expected: (any WallpaperRuntimeSession)?,
        generation: Int,
        attemptID: UUID? = nil,
        proposedConfiguration: ScreenConfiguration,
        expectedConfigurationRevision: UInt64,
        timeout: Duration,
        beforeCommit: @MainActor @escaping () -> Bool,
        afterCommit: @MainActor @escaping () -> Void,
        completion: WallpaperPreparationCompletion? = nil
    ) -> RuntimePreparationWork {
        let screenID = screen.id
        let fingerprint = screen.displayFingerprint
        let currentScreen: @MainActor () -> Screen? = { [weak self] in
            self?.screens.first { $0.id == screenID && $0.displayFingerprint == fingerprint }
        }
        let work = RuntimePreparationWork()
        let task = Task { @MainActor [weak self, weak work] in
            guard let self else {
                candidate.cleanup()
                completion?(.cancelled, nil)
                return
            }
            // Evaluated conjunct-by-conjunct only so a dropped candidate names the reason: success and every failure mode would look identical here.
            let isCandidateStillCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: ScreenManager was deallocated",
                        category: .screenManager
                    )
                    return false
                }
                if isTerminating {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: the app is terminating",
                        category: .screenManager
                    )
                    return false
                }
                if !wallpapersGloballyEnabled {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: wallpapers are globally disabled",
                        category: .screenManager
                    )
                    return false
                }
                if currentScreen() == nil {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: the physical display was removed or replaced",
                        category: .screenManager
                    )
                    return false
                }
                if !isCurrentTransition(generation, for: screenID) {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: a newer transition superseded generation \(generation)",
                        category: .screenManager
                    )
                    return false
                }
                let revision = configurationStore.revision(for: screenID)
                if revision != expectedConfigurationRevision {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: configuration revision advanced \(expectedConfigurationRevision) → \(revision)",
                        category: .screenManager
                    )
                    return false
                }
                return true
            }
            let result = await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: expected,
                timeout: timeout,
                isStillCurrent: isCandidateStillCurrent,
                currentScreen: currentScreen,
                claimOpening: { [weak self] in
                    self?.openingBatch?.claim(screenID)
                },
                beforeCommit: beforeCommit,
                afterCommit: { [weak self] in
                    guard let self, let screen = currentScreen() else { return }
                    if let attemptID {
                        wallpaperLoads.clear(for: screen, matching: attemptID)
                    }
                    afterCommit()
                    self.observeRuntimeErrors(for: candidate)
                    self.setTransientRuntimeError(nil, for: screenID)
                    self.resetPlaybackStateMachine(for: screen)
                    self.applyPerformancePolicy(to: screen)
                    // Any successful cross-type replacement can retire the
                    // previous Video or HTML leader. Recompute both domains.
                    self.playbackCoordinator.refreshVideoAudioLeadership()
                    self.htmlCoordinator.refreshAudioLeadership()
                    self.notifyWallpaperSessionChanged()
                },
                beforeDiscard: { [weak self, weak screen] result in
                    guard let self, let screen, let attemptID,
                          WallpaperCandidateErrorPolicy.shouldPublish(result, isStillCurrent: isCandidateStillCurrent()) else { return }
                    let error = candidate.runtimeError ?? .wallpaperPreparationFailed(type: candidate.wallpaperType, timedOut: result == .timedOut)
                    var cause = WallpaperFailureCause.runtime(error)
                    var diagnostics = ""
                    // Web's counterpart of the scene branch below; `WebFailureCause` is what
                    // keeps a 404, a revoked folder and a renderer crash from sharing one code.
                    if let ambient = candidate as? AmbientWallpaperSession,
                       let webCause = ambient.loadFailureCause {
                        cause = webCause
                    }
                    #if !LITE_BUILD
                    if let scene = candidate as? any SceneWallpaperRuntime {
                        cause = scene.loadFailureCause ?? scene.loadError.map(SceneFailureCause.make) ?? cause
                        if scene.loadError == nil, let gpuError = scene.rendererDiagnostics?.gpuErrors.last {
                            cause = WallpaperFailureCause(code: "scene.gpu_present", reason: gpuError)
                        }
                        if let config = wallpaperLoads.attempt(for: screen)?.configuration,
                           case let .scene(descriptor) = config.activeWallpaper {
                            diagnostics = WPERenderDiagnosticReport.make(descriptor: descriptor, diagnostics: scene.rendererDiagnostics, errorCode: cause.code)
                        }
                    }
                    #endif
                    guard isCandidateStillCurrent() else { return }
                    failWallpaperAttempt(attemptID, for: screen, cause: cause, stage: result == .timedOut ? .firstFrame : .loading, diagnostics: diagnostics)
                }
            )

            if result == .cancelled, let attemptID {
                wallpaperLoads.clear(for: screen, matching: attemptID)
            }
            if let error = WallpaperCandidateErrorPolicy.errorToPublish(
                result,
                isStillCurrent: isCandidateStillCurrent(),
                candidateError: candidate.runtimeError,
                fallbackWallpaperType: candidate.wallpaperType
            ) {
                if let attemptID, wallpaperLoads.attempt(for: screen)?.failure == nil {
                    failWallpaperAttempt(attemptID, for: screen, cause: .runtime(error), stage: .commit)
                }
                setTransientRuntimeError(error, for: screenID, failedProposal: proposedConfiguration)
                if attemptID == nil {
                    WallpaperPreparationFailure.announce(error.userMessage, on: screenID, generation: generation)
                }
            }
            if let work {
                self.transitionRegistry.clearRuntimePreparationIfMatch(
                    work,
                    for: screenID
                )
            }
            let attempt = wallpaperLoads.attempt(for: screen)
            completion?(result, attempt?.id == attemptID ? attempt?.failure : nil)
        }
        work.task = task
        transitionRegistry.setRuntimePreparation(work, for: screenID)
        return work
    }
}
