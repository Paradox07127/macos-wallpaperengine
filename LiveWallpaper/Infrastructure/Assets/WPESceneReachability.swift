#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

@MainActor
enum WPESceneReachability {
    static func referencedWorkshopIDs() -> Set<String> {
        var ids: Set<String> = []

        func add(_ origin: WPEOrigin?) {
            guard let origin else { return }
            ids.insert(origin.workshopID)
            ids.formUnion(origin.dependencyWorkshopIDs)
        }
        func add(_ descriptor: SceneDescriptor?) {
            guard let descriptor else { return }
            ids.insert(descriptor.workshopID)
            ids.formUnion(descriptor.dependencyWorkshopIDs)
        }

        for config in SettingsManager.shared.loadConfigurations() {
            add(config.activeWallpaper.sceneDescriptor)
            add(config.wpeOrigin)
        }
        for entry in SettingsManager.shared.loadGlobalSettings().recentWPEImports {
            add(entry.origin)
        }
        for bookmark in BookmarkStore.shared.bookmarks {
            add(bookmark.wpeOrigin)
            add(bookmark.content.sceneDescriptor)
        }
        return ids.filter { !$0.isEmpty }
    }
}
#endif
