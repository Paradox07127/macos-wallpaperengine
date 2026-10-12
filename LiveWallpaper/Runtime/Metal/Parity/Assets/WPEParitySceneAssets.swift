#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// The parity pipeline's file lookup over what the old renderer is given: the wallpaper's files through the
/// scene asset provider (scene.pkg or source folder; `nil` reads the extracted cache at `projectRoot`), with
/// `../<workshop id>/` paths going to the dependency mounts, then the engine root's `assets` directory.
enum WPEParitySceneAssets {
    /// `provider` and `projectRoot` are `AmbientWallpaperSessionBuilder.sceneAssets(...)`'s result.
    static func make(provider: (any WPESceneAssetProvider)?, projectRoot: URL, dependencyMounts: [WPEAssetMount],
                     engineAssetsRootURL: URL?) -> WPEParityProgramAssets {
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
        return WPEParityProgramAssets(sources: sources)
    }
}
#endif
