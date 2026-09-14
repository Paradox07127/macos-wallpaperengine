#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

struct WPESceneCapabilityClassifier: Sendable {
    func capabilityTier(
        for document: WPESceneDocument,
        cacheURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil
    ) -> SceneCapabilityTier {
        classify(document: document, resolver: WPEMultiRootResourceResolver(
            primaryRootURL: cacheURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL
        ))
    }

    func capabilityTier(
        for document: WPESceneDocument,
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil
    ) -> SceneCapabilityTier {
        classify(document: document, resolver: WPEMultiRootResourceResolver(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL
        ))
    }

    private func classify(
        document: WPESceneDocument,
        resolver: WPEMultiRootResourceResolver
    ) -> SceneCapabilityTier {
        guard !document.imageObjects.isEmpty else {
            return .unsupported
        }

        let rendersSomething = document.imageObjects.contains { object in
            isReachable(object.imageRelativePath, through: resolver)
        }

        return rendersSomething ? .imageOnly : .unsupported
    }

    private func isReachable(
        _ relativePath: String,
        through resolver: WPEMultiRootResourceResolver
    ) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return resolver.exists(relativePath: relativePath)
    }
}
#endif
