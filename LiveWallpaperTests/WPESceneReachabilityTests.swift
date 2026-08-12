#if !LITE_BUILD
import Foundation
import Testing
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("WPE scene reachability: package-backed ids")
@MainActor
struct WPESceneReachabilityTests {
    private func origin(
        _ workshopID: String,
        type: WPEType,
        entryFile: String
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID,
            title: "item-\(workshopID)",
            originalType: type,
            sourceFolderBookmark: Data("bookmark".utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: nil,
            entryFile: entryFile,
            resourceLocation: .cache
        )
    }

    private func config(
        _ content: WallpaperContent,
        origin: WPEOrigin?,
        screenID: UInt32 = 1
    ) -> ScreenConfiguration {
        var config = ScreenConfiguration(screenID: screenID, wallpaper: content)
        config.wpeOrigin = origin
        return config
    }

    private func sceneDescriptor(_ workshopID: String, storage: SceneAssetStorage) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly,
            assetStorage: storage
        )
    }
}
#endif
