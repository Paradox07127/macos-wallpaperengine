#if !LITE_BUILD
import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

extension ScreenManager {
    /// References move before the history entry goes, so a pass cut short is finished by the next one.
    @discardableResult
    func supersedeLocalCopiesWithSteam() -> Int {
        guard !isTerminating else { return 0 }
        var superseded = 0
        for (local, steam) in SettingsManager.shared.localCopiesShadowedBySteam() {
            // A local copy keeps its manifest's Workshop id, so the id alone would also match the Steam item.
            let matchesLocal = { (origin: WPEOrigin) in SettingsManager.isSameWPEItem(origin, local.origin) }
            if let content = WPECachedContentResolver().content(for: steam.origin) {
                repointWPEReferences(where: matchesLocal, to: steam.origin, content: content)
            } else if hasWPEReferences(where: matchesLocal, other: steam.origin) {
                // Repointing would swap playable local content for a Steam item that can't play.
                continue
            }
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

    private func repointWPEReferences(where matchesLocal: (WPEOrigin) -> Bool, to steam: WPEOrigin, content: WallpaperContent) {
        var reloadedScreenIDs: Set<CGDirectDisplayID> = []
        for configuration in configurationStore.loadAll() {
            guard let updated = configuration.repointingWPEOrigin(where: matchesLocal, to: steam, content: content) else { continue }
            saveConfiguration(updated)
            if let current = configuration.wpeOrigin, matchesLocal(current) {
                reloadedScreenIDs.insert(updated.screenID)
            }
        }
        BookmarkStore.shared.repointWPEOrigin(where: matchesLocal, to: steam, content: content)
        SchemeStore.shared.repointWPEOrigin(where: matchesLocal, to: steam, content: content)
        for screen in screens where reloadedScreenIDs.contains(screen.id) {
            reloadWallpaperForScreen(screen)
        }
    }

    /// `other` is any origin `matches` rejects.
    private func hasWPEReferences(where matches: (WPEOrigin) -> Bool, other: WPEOrigin) -> Bool {
        /// A configuration repoints to something different exactly when it references a matching origin.
        func references(_ configuration: ScreenConfiguration) -> Bool {
            configuration.repointingWPEOrigin(where: matches, to: other, content: configuration.activeWallpaper) != nil
        }
        return configurationStore.loadAll().contains(where: references)
            || BookmarkStore.shared.bookmarks.contains { $0.wpeOrigin.map(matches) ?? false }
            || SchemeStore.shared.schemes.contains { references($0.configuration) }
    }
}
#endif
