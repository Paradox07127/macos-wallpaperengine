#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct SceneResourceResolver: Sendable {
    enum ResolveError: Error, Equatable, Sendable {
        case pathEscape
        case fileMissing
        case decodeFailed
        case texture(WPETexDecodeError)
        /// image → model/material JSON with no resolvable texture.
        case materialUnresolved(reason: String)
        /// A WPE built-in `models/util/` layer this Mac has no copy of: a renderer gap, not damage.
        case builtinLayerUnavailable(reason: String)
    }

    private let provider: any WPESceneAssetProvider
    private static let rawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    init(cacheRootURL: URL) {
        let normalized = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.provider = WPEDirectorySceneAssetProvider(rootURL: normalized)
    }

    init(provider: any WPESceneAssetProvider) {
        self.provider = provider
    }

    private func imageStorageCandidates(for relativePath: String) -> [String] {
        let extensionName = (relativePath as NSString).pathExtension.lowercased()
        guard Self.rawImageExtensions.contains(extensionName) else {
            return [relativePath]
        }

        var candidates = [relativePath, "\(relativePath).tex"]
        let anchoredPrefixes = [
            "materials/", "models/", "shaders/", "fonts/",
            "scripts/", "particles/", "sounds/", "scenes/", "../"
        ]
        let isSingleUnderscoreReference = relativePath.hasPrefix("_") && !relativePath.hasPrefix("__")
        if !anchoredPrefixes.contains(where: relativePath.hasPrefix), !isSingleUnderscoreReference {
            candidates.append("materials/\(relativePath)")
            candidates.append("materials/\(relativePath).tex")
        }
        return candidates
    }

    func exists(relativePath: String) -> Bool {
        imageStorageCandidates(for: relativePath).contains { candidate in
            provider.exists(atRelativePath: candidate)
        }
    }

    /// Raw asset bytes; `.fileMissing` continues multi-root fallback.
    func data(relativePath: String) throws -> Data {
        try providerData(relativePath)
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        do {
            return try provider.stagedURL(atRelativePath: relativePath)
        } catch WPESceneAssetProviderError.invalidRelativePath {
            throw ResolveError.pathEscape
        } catch {
            throw ResolveError.fileMissing
        }
    }

    private func providerData(_ relativePath: String) throws -> Data {
        do {
            return try provider.data(atRelativePath: relativePath)
        } catch WPESceneAssetProviderError.invalidRelativePath {
            throw ResolveError.pathEscape
        } catch {
            throw ResolveError.fileMissing
        }
    }
}
#endif
