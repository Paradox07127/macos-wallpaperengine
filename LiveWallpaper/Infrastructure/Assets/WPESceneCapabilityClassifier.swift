#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Import-time image-layer reachability: `.unsupported` when no image layer
/// resolves through the runtime multi-root chain, `.imageOnly` otherwise.
/// Complements structural `WPEScenePreflight`.
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

    /// Package-/source-backed variant — classifies against an in-place provider
    /// without extracting to a cache directory.
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

        // Renders something, or renders nothing — that is the whole judgement now.
        // There used to be a middle "Limited Compatibility" tier, gated on any parser diagnostic whose message didn't contain ".tex texture". It never looked at severity, and 29 of the parser's 40 diagnostics are `.info` *success* notes ("Particle object … parsed; rendered by the Metal particle simulator"), so every scene carrying a particle, text, or sound object was flagged — the label fired on richness, not on damage.
        // What actually went wrong at runtime is reported by the render diagnostics (unresolved refs, shader failures, GPU errors), which are collected in Release too.
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
