#if !LITE_BUILD
import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

extension ScreenManager {
    func observeWorkshopRepositoryMutations() {
        NotificationCenter.default.publisher(for: .workshopItemWillMutate)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let workshopID = notification.userInfo?["workshopID"] as? String
                    else { return }
                    self.suspendWorkshopItemForMutation(workshopID)
                }
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: .workshopItemDidMutate)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let workshopID = notification.userInfo?["workshopID"] as? String
                    else { return }
                    self.reloadWorkshopItemAfterMutation(workshopID)
                }
            }
            .store(in: &cleanupTasks)
    }

    /// Builds no session while a Workshop item the configuration reads is being rewritten: commits
    /// the configuration (`.ready`, like the globally-off path) and parks the screen for that item's didMutate reload. nil = not gated.
    func deferSessionDuringWorkshopMutation(
        for screen: Screen,
        configuration: ScreenConfiguration,
        beforeCommit: @MainActor () -> Bool
    ) -> WallpaperPreparationResult? {
        guard let origin = configuration.wpeOrigin, !workshopMutationSuspendedScreenIDs.isEmpty,
              let workshopID = ([origin.steamFolderItemID].compactMap(\.self) + origin.dependencyWorkshopIDs)
              .first(where: { workshopMutationSuspendedScreenIDs[$0] != nil })
        else { return nil }
        guard beforeCommit() else { return .failed }
        Logger.info("Deferring Workshop item load until shared-repository mutation finishes", category: .workshop)
        if screen.runtimeSession != nil {
            releaseRuntimeSession(screen)
        }
        workshopMutationSuspendedScreenIDs[workshopID, default: []].insert(screen.id)
        notifyWallpaperSessionChanged()
        return .ready
    }

    /// Mutation notifications carry the Steam folder name; a local copy shares only the manifest id and reads none of those files.
    private func reads(_ origin: WPEOrigin?, _ workshopID: String) -> Bool {
        guard let origin else { return false }
        return origin.steamFolderItemID == workshopID || origin.dependencyWorkshopIDs.contains(workshopID)
    }

    private func readsWorkshopItem(_ screen: Screen, _ workshopID: String) -> Bool {
        reads(configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.wpeOrigin, workshopID)
    }

    private func suspendWorkshopItemForMutation(_ workshopID: String) {
        var suspended = Set<CGDirectDisplayID>()
        for screen in screens {
            if let attempt = wallpaperLoads.attempt(for: screen), attempt.phase == .preparing,
               let proposal = attempt.configuration, reads(attempt.origin, workshopID) {
                Logger.info("Cancelling a Workshop item candidate before shared-repository mutation", category: .workshop)
                wallpaperLoads.clear(for: screen)
                workshopMutationParkedProposals[screen.id] = (bumpTransition(for: screen.id), proposal)
                suspended.insert(screen.id)
            }
            guard screen.runtimeSession != nil, readsWorkshopItem(screen, workshopID) else { continue }
            Logger.info(
                "Suspending Workshop item before shared-repository mutation",
                category: .workshop
            )
            releaseRuntimeSession(screen)
            suspended.insert(screen.id)
        }
        workshopMutationSuspendedScreenIDs[workshopID] = suspended
    }

    private func reloadWorkshopItemAfterMutation(_ workshopID: String) {
        let suspended = workshopMutationSuspendedScreenIDs.removeValue(forKey: workshopID) ?? []
        for screen in screens where suspended.contains(screen.id) {
            if let parked = workshopMutationParkedProposals.removeValue(forKey: screen.id) {
                if isCurrentTransition(parked.generation, for: screen.id) {
                    restoreProposedWallpaperSession(for: screen, configuration: parked.configuration)
                }
                continue
            }
            guard screen.runtimeSession == nil, readsWorkshopItem(screen, workshopID) else { continue }
            reloadWallpaperForScreen(screen)
        }
    }
}
#endif
