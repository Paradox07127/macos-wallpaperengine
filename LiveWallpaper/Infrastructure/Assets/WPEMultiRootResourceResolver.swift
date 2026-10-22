#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPEMultiRootResourceResolver: Sendable {
    private let primary: SceneResourceResolver
    private let dependencyMounts: [String: SceneResourceResolver]
    private let engineAssetsResolver: SceneResourceResolver?

    init(
        primaryRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil
    ) {
        self.primary = SceneResourceResolver(cacheRootURL: primaryRootURL)
        self.engineAssetsResolver = engineAssetsRootURL.map {
            SceneResourceResolver(
                cacheRootURL: $0.appendingPathComponent("assets", isDirectory: true)
            )
        }
        self.dependencyMounts = Self.makeMountResolvers(dependencyMounts)
    }

    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil
    ) {
        self.primary = SceneResourceResolver(provider: primaryProvider)
        self.engineAssetsResolver = engineAssetsRootURL.map {
            SceneResourceResolver(
                cacheRootURL: $0.appendingPathComponent("assets", isDirectory: true)
            )
        }
        self.dependencyMounts = Self.makeMountResolvers(dependencyMounts)
    }

    /// A package mount that can't be opened is dropped, so its references
    /// resolve as missing rather than crashing.
    private static func makeMountResolvers(_ dependencyMounts: [WPEAssetMount]) -> [String: SceneResourceResolver] {
        var mounts: [String: SceneResourceResolver] = [:]
        for mount in dependencyMounts {
            switch mount.backing {
            case .directory(let rootURL):
                mounts[mount.workshopID] = SceneResourceResolver(cacheRootURL: rootURL)
            case .package(let packageURL):
                if let provider = try? WPEPackageSceneAssetProvider(packageURL: packageURL) {
                    mounts[mount.workshopID] = SceneResourceResolver(provider: provider)
                }
            }
        }
        return mounts
    }

    func exists(relativePath: String) -> Bool {
        if let dependency = Self.dependencyReference(relativePath) {
            return dependencyMounts[dependency.workshopID]?.exists(relativePath: dependency.childPath) ?? false
        }
        if primary.exists(relativePath: relativePath) { return true }
        if let engineAssetsResolver, engineAssetsResolver.exists(relativePath: relativePath) { return true }
        return false
    }

    func data(relativePath: String) throws -> Data {
        if let dependency = Self.dependencyReference(relativePath) {
            return try resolveDependency(dependency: dependency) { resolver, path in
                try resolver.data(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.data(relativePath: path)
        }
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        if let dependency = Self.dependencyReference(relativePath) {
            return try resolveDependency(dependency: dependency) { resolver, path in
                try resolver.resolveExistingFileURL(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveExistingFileURL(relativePath: path)
        }
    }

    private func resolveWithFallbacks<T>(
        relativePath: String,
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        do {
            return try resolve(primary, relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing {
            guard let engineAssetsResolver else {
                throw SceneResourceResolver.ResolveError.fileMissing
            }
            return try resolve(engineAssetsResolver, relativePath)
        }
    }

    private func resolveDependency<T>(
        dependency: (workshopID: String, childPath: String),
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        guard let resolver = dependencyMounts[dependency.workshopID] else {
            throw SceneResourceResolver.ResolveError.pathEscape
        }
        return try resolve(resolver, dependency.childPath)
    }

    static func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }
}
#endif
