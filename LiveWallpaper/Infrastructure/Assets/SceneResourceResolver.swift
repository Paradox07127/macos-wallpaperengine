#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperCore
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
    private let decoder: WPETexDecoder
    private static let rawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    init(cacheRootURL: URL, decoder: WPETexDecoder = WPETexDecoder()) {
        let normalized = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.provider = WPEDirectorySceneAssetProvider(rootURL: normalized)
        self.decoder = decoder
    }

    init(provider: any WPESceneAssetProvider, decoder: WPETexDecoder = WPETexDecoder()) {
        self.provider = provider
        self.decoder = decoder
    }

    struct ResolvedImage {
        let image: CGImage
    }

    func resolveImage(relativePath: String, maxSourceEdge: Int? = nil) throws -> ResolvedImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        var lastMissing: ResolveError?
        for candidate in imageStorageCandidates(for: relativePath) {
            do {
                return try resolveImageCandidate(relativePath: candidate, maxSourceEdge: maxSourceEdge)
            } catch ResolveError.fileMissing {
                lastMissing = .fileMissing
                continue
            }
        }
        throw lastMissing ?? ResolveError.fileMissing
    }

    private func resolveImageCandidate(relativePath: String, maxSourceEdge: Int? = nil) throws -> ResolvedImage {
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)

        if (resolvedPath as NSString).pathExtension.lowercased() == "tex" {
            let payload: WPEMappedByteSpan
            do {
                payload = try providerWindow(resolvedPath)
            } catch ResolveError.fileMissing {
                if let resolved = try resolveRasterSiblingImage(
                    forMissingTexPath: resolvedPath,
                    maxSourceEdge: maxSourceEdge
                ) {
                    return resolved
                }
                throw ResolveError.fileMissing
            }

            switch decoder.decode(span: payload) {
            case .success(let image):
                return ResolvedImage(image: image)
            case .failure(let error):
                throw ResolveError.texture(error)
            }
        }

        let payload = try providerData(resolvedPath)
        return try decodeRasterImage(payload, maxSourceEdge: maxSourceEdge)
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

    private func resolveRasterSiblingImage(
        forMissingTexPath texPath: String,
        maxSourceEdge: Int? = nil
    ) throws -> ResolvedImage? {
        for candidate in rasterSiblingPaths(forMissingTexPath: texPath) {
            do {
                let payload = try providerData(candidate)
                return try decodeRasterImage(payload, maxSourceEdge: maxSourceEdge)
            } catch ResolveError.fileMissing {
                continue
            }
        }
        return nil
    }

    private func rasterSiblingPaths(forMissingTexPath texPath: String) -> [String] {
        let basePath = (texPath as NSString).deletingPathExtension
        return ["\(basePath).png", "\(basePath).jpg", "\(basePath).jpeg"]
    }

    private func decodeRasterImage(_ payload: Data, maxSourceEdge: Int? = nil) throws -> ResolvedImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(payload as CFData, sourceOptions) else {
            throw ResolveError.decodeFailed
        }
        if let maxSourceEdge,
           maxSourceEdge > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) > maxSourceEdge,
           min(width, height) > 64 {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Match `CreateImageAtIndex(..., nil)`: do not apply EXIF
                // orientation (the uncapped path does not).
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxSourceEdge
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                return ResolvedImage(image: thumbnail)
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResolveError.decodeFailed
        }
        return ResolvedImage(image: image)
    }

    private func resolveImageReference(relativePath: String, depth: Int) throws -> String {
        let lowered = (relativePath as NSString).pathExtension.lowercased()
        if lowered != "json" {
            return relativePath
        }
        if depth >= 4 {
            throw ResolveError.materialUnresolved(reason: String(localized: "Reference depth exceeded for \(relativePath)", bundle: .appLanguage, comment: "Scene asset resolve failure. Placeholder is the reference path."))
        }

        let payload: Data
        do {
            payload = try providerData(relativePath)
        } catch ResolveError.pathEscape {
            // An escaping reference aborts the multi-root cascade (unlike a plain
            // miss, which falls through to built-ins / engine assets).
            throw ResolveError.pathEscape
        } catch {
            if relativePath.contains("models/util/") {
                throw ResolveError.builtinLayerUnavailable(reason: String(localized: "Built-in WPE layer \(relativePath) is not available on macOS", bundle: .appLanguage, comment: "Scene asset resolve failure. Placeholder is the layer path."))
            }
            throw ResolveError.fileMissing
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            throw ResolveError.materialUnresolved(reason: String(localized: "Couldn't parse \(relativePath) as JSON", bundle: .appLanguage, comment: "Scene asset resolve failure. Placeholder is the file path."))
        }
        guard let dict = parsed as? [String: Any] else {
            throw ResolveError.materialUnresolved(reason: String(localized: "\(relativePath) is not a JSON object", bundle: .appLanguage, comment: "Scene asset resolve failure. Placeholder is the file path."))
        }

        if let materialPath = dict["material"] as? String, !materialPath.isEmpty {
            return try resolveImageReference(relativePath: materialPath, depth: depth + 1)
        }

        if let textureName = firstTextureName(in: dict) {
            return "materials/\(textureName).tex"
        }

        throw ResolveError.materialUnresolved(reason: String(localized: "\(relativePath) has no `material` or `passes[].textures[]`", bundle: .appLanguage, comment: "Scene asset resolve failure. Placeholder is the file path."))
    }

    private func firstTextureName(in dict: [String: Any]) -> String? {
        guard let passes = dict["passes"] as? [[String: Any]] else { return nil }
        for pass in passes {
            guard let textures = pass["textures"] as? [Any] else { continue }
            for entry in textures {
                if let name = entry as? String, !name.isEmpty { return name }
                if let nested = entry as? [String: Any],
                   let name = nested["name"] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
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

    private func providerWindow(_ relativePath: String) throws -> WPEMappedByteSpan {
        do {
            return try provider.mappedWindow(atRelativePath: relativePath)
        } catch WPESceneAssetProviderError.invalidRelativePath {
            throw ResolveError.pathEscape
        } catch {
            throw ResolveError.fileMissing
        }
    }
}
#endif
