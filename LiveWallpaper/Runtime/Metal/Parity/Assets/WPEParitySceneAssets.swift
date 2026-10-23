#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// The parity pipeline's file lookup: the wallpaper's files through the
/// scene asset provider (scene.pkg or source folder; `nil` reads the extracted cache at `projectRoot`), with
/// `../<workshop id>/` paths going to the dependency mounts, then the engine root's `assets` directory.
enum WPEParitySceneAssets {
    /// `provider` and `projectRoot` are `AmbientWallpaperSessionBuilder.sceneAssets(...)`'s result; `userValues` are the
    /// load's effective property values, as the scene document is parsed with.
    static func make(provider: (any WPESceneAssetProvider)?, projectRoot: URL, dependencyMounts: [WPEAssetMount],
                     engineAssetsRootURL: URL?,
                     userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) -> WPEParityProgramAssets {
        let wallpaper = if let provider {
            WPEMultiRootResourceResolver(primaryProvider: provider, dependencyMounts: dependencyMounts)
        } else {
            WPEMultiRootResourceResolver(primaryRootURL: projectRoot, dependencyMounts: dependencyMounts)
        }
        var sources: [WPEParityProgramAssets.Source] = [
            .lookup(projectRoot) { try? wallpaper.data(relativePath: $0) },
        ]
        if let engineAssetsRootURL {
            let root = engineAssetsRootURL.appendingPathComponent("assets", isDirectory: true)
            // Holds the engine root's security scope while the lookup lives; a root that needs none reads anyway.
            let engine = WPESecurityScopedSceneAssetProvider(
                wrapped: WPEDirectorySceneAssetProvider(rootURL: root), scopedURL: engineAssetsRootURL,
                didStartAccessing: engineAssetsRootURL.startAccessingSecurityScopedResource()
            )
            sources.append(.lookup(root) { try? engine.data(atRelativePath: $0) })
        }
        var assets = WPEParityProgramAssets(sources: sources)
        assets.userValues = userValues
        return assets
    }
}
#endif
