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

    private func suspendWorkshopItemForMutation(_ workshopID: String) {
        var suspended = Set<CGDirectDisplayID>()
        for screen in screens {
            guard screen.runtimeSession != nil,
                  configurationStore.get(
                    for: screen.id,
                    fingerprint: screen.displayFingerprint
                  )?.wpeOrigin?.workshopID == workshopID
            else { continue }
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
            guard screen.runtimeSession == nil,
                  configurationStore.get(
                    for: screen.id,
                    fingerprint: screen.displayFingerprint
                  )?.wpeOrigin?.workshopID == workshopID
            else { continue }
            reloadWallpaperForScreen(screen)
        }
    }
}
#endif
