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
        let rendersSomething = document.imageObjects.contains { object in
            isReachable(object.imageRelativePath, through: resolver)
        }

        if rendersSomething {
            return .imageOnly
        }
        // Text produces synthetic glyph layers; particles own their runtime draw path.
        // Admission is not deep material validation, matching the image path above.
        if !document.textObjects.isEmpty || document.particleObjects.contains(where: {
            isReachable($0.particleRelativePath, through: resolver)
        }) {
            return .degraded
        }
        return .unsupported
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
