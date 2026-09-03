import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
extension ScreenManager {
    /// Persist bookmark-normalized config inside the install CAS (final write wins).
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

    /// Retire outgoing video work: asset readiness is screen-scoped; effects are player-scoped.
    func retireOutgoingVideoWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer?
    ) {
        transitionRegistry.cancelAssetReadiness(for: screenID)
        guard let player, effectsCoordinatorWasInitialized else { return }
        effectsCoordinator.retireWork(for: screenID, player: player)
    }

    func beginPreparedAmbientSession(
        _ candidate: any WallpaperRuntimeSession,
        for screen: Screen,
        replacing expected: (any WallpaperRuntimeSession)?,
        generation: Int,
        expectedConfigurationRevision: UInt64,
        timeout: Duration,
        beforeCommit: @MainActor @escaping () -> Bool,
        afterCommit: @MainActor @escaping () -> Void
    ) {
        let screenID = screen.id
        let work = RuntimePreparationWork()
        let task = Task { @MainActor [weak self, weak screen, weak work] in
            guard let self, let screen else {
                candidate.cleanup()
                return
            }
            // Evaluated conjunct-by-conjunct only so a dropped candidate names the
            // reason: success and every failure mode used to look identical here.
            let isCandidateStillCurrent: @MainActor () -> Bool = {
                [weak self, weak screen] in
                guard let self, let screen else {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: ScreenManager or Screen was deallocated",
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
                if !screens.contains(where: { $0 === screen }) {
                    Logger.notice(
                        "Wallpaper candidate for screen \(screenID) dropped: Screen object was replaced (display refresh during prepare)",
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
                beforeCommit: beforeCommit,
                afterCommit: { [weak self, weak screen] in
                    guard let self, let screen else { return }
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
                }
            )

            if let error = WallpaperCandidateErrorPolicy.errorToPublish(
                result,
                isStillCurrent: isCandidateStillCurrent(),
                candidateError: candidate.runtimeError,
                fallbackWallpaperType: candidate.wallpaperType
            ) {
                self.setTransientRuntimeError(error, for: screenID)
            }
            if let work {
                self.transitionRegistry.clearRuntimePreparationIfMatch(
                    work,
                    for: screenID
                )
            }
        }
        work.task = task
        transitionRegistry.setRuntimePreparation(work, for: screenID)
    }
}
