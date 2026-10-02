#if !LITE_BUILD
import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

extension ScreenManager {
    /// References move before the history entry goes, so a pass cut short is finished by the next one.
    @discardableResult
    func supersedeLocalCopiesWithSteam() -> Int {
        var superseded = 0
        for (local, steam) in SettingsManager.shared.localCopiesShadowedBySteam()
            where repointWPEReferences(from: local.origin, to: steam.origin) {
            SettingsManager.shared.replaceWPEImport(local, with: steam)
            superseded += 1
        }
        return superseded
    }

    func observeWPEHistoryForSupersede() {
        NotificationCenter.default.publisher(for: .wpeHistoryDidChange)
            // Must stay asynchronous: superseding posts this notification itself and would re-enter.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.supersedeLocalCopiesWithSteam()
            }
            .store(in: &cleanupTasks)
    }

    /// false, changing nothing, when the Steam item's content can't be rebuilt.
    @discardableResult
    func repointWPEReferences(from local: WPEOrigin, to steam: WPEOrigin) -> Bool {
        guard !isTerminating, let content = WPECachedContentResolver().content(for: steam) else { return false }
        // A local copy keeps its manifest's Workshop id, so the id alone would also match the Steam item.
        let matchesLocal = { (origin: WPEOrigin) in SettingsManager.isSameWPEItem(origin, local) }
        var repointedScreenIDs: Set<CGDirectDisplayID> = []
        for configuration in configurationStore.loadAll() {
            guard let updated = configuration.repointingWPEOrigin(where: matchesLocal, to: steam, content: content) else { continue }
            saveConfiguration(updated)
            repointedScreenIDs.insert(updated.screenID)
        }
        BookmarkStore.shared.repointWPEOrigin(where: matchesLocal, to: steam, content: content)
        SchemeStore.shared.repointWPEOrigin(where: matchesLocal, to: steam, content: content)
        for screen in screens where repointedScreenIDs.contains(screen.id) {
            guard let configuration = getConfiguration(for: screen) else { continue }
            applyConfiguration(configuration, to: screen, forceReplacement: true)
        }
        return true
    }
}
#endif
