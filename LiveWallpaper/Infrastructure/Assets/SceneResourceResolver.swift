#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperProWPE

/// Scene asset resolver via `WPESceneAssetProvider` (directory or in-place scene.pkg).
struct SceneResourceResolver: Sendable {
    enum ResolveError: Error, Equatable, Sendable {
        case pathEscape
        case fileMissing
        case decodeFailed
        case unsupportedTexture                          // legacy alias
        case texture(WPETexDecodeError)
        /// image → model/material JSON with no resolvable texture (engine-built layer).
        case materialUnresolved(reason: String)
    }

    /// Directory-backed cache root for diagnostics only (reads use `provider`).
    let cacheRootURL: URL?
    private let provider: any WPESceneAssetProvider
    private let decoder: WPETexDecoder
    private static let rawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    private static func isTexturePayloadPath(_ relativePath: String) -> Bool {
        let extensionName = (relativePath as NSString).pathExtension.lowercased()
        return extensionName == "tex" || extensionName.isEmpty
    }

    init(cacheRootURL: URL, decoder: WPETexDecoder = WPETexDecoder()) {
        let normalized = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheRootURL = normalized
        self.provider = WPEDirectorySceneAssetProvider(rootURL: normalized)
        self.decoder = decoder
    }

    init(provider: any WPESceneAssetProvider, cacheRootURL: URL? = nil, decoder: WPETexDecoder = WPETexDecoder()) {
        self.cacheRootURL = cacheRootURL
        self.provider = provider
        self.decoder = decoder
    }

    /// Opt-in TEXI/TEXB header dump for scene-debug sessions.
    private func dumpRawTexMetadataIfActive(payload: WPEMappedByteSpan, targetName: String) {
        guard WPESceneDebugArtifacts.shared.activeSessionFolder != nil else { return }
        guard case .success(let metadata) = decoder.extractRawMetadata(span: payload) else { return }
        WPESceneDebugArtifacts.shared.dumpRawTexMetadata(
            name: (targetName as NSString).lastPathComponent,
            info: metadata.info,
            bitmap: metadata.bitmap
        )
    }

    func resolveImage(relativePath: String) throws -> CGImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        var lastMissing: ResolveError?
        for candidate in imageStorageCandidates(for: relativePath) {
            do {
                return try resolveImageCandidate(relativePath: candidate)
            } catch ResolveError.fileMissing {
                lastMissing = .fileMissing
                continue
            }
        }
        throw lastMissing ?? ResolveError.fileMissing
    }

    private func resolveImageCandidate(relativePath: String) throws -> CGImage {
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)

        if (resolvedPath as NSString).pathExtension.lowercased() == "tex" {
            let payload: WPEMappedByteSpan
            do {
                payload = try providerWindow(resolvedPath)
            } catch ResolveError.fileMissing {
                if let image = try resolveRasterSiblingImage(forMissingTexPath: resolvedPath) {
                    return image
                }
                throw ResolveError.fileMissing
            }
            dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
            switch decoder.decode(span: payload) {
            case .success(let image):
                return image
            case .failure(let error):
                throw ResolveError.texture(error)
            }
        }

        let payload = try providerData(resolvedPath)
        return try decodeRasterImage(payload)
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

    private func resolveRasterSiblingImage(forMissingTexPath texPath: String) throws -> CGImage? {
        let basePath = (texPath as NSString).deletingPathExtension
        for candidate in ["\(basePath).png", "\(basePath).jpg", "\(basePath).jpeg"] {
            do {
                let payload = try providerData(candidate)
                return try decodeRasterImage(payload)
            } catch ResolveError.fileMissing {
                continue
            }
        }
        return nil
    }

    private func decodeRasterImage(_ payload: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResolveError.decodeFailed
        }
        return image
    }

    /// Raw texture payload for Metal-backed renderers.
    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        guard Self.isTexturePayloadPath(resolvedPath) else {
            throw ResolveError.unsupportedTexture
        }

        let payload = try providerWindow(resolvedPath)
        dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
        switch decoder.extractTexturePayload(span: payload) {
        case .success(let texture):
            return texture
        case .failure(let error):
            throw ResolveError.texture(error)
        }
    }

    /// Streaming TEXS payload for lazy animated textures (mappedIfSafe when directory-backed).
    func resolveStreamingTexturePayload(relativePath: String) throws -> WPETexStreamingPayload {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        guard Self.isTexturePayloadPath(resolvedPath) else {
            throw ResolveError.unsupportedTexture
        }

        let payload = try providerWindow(resolvedPath)
        dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
        switch decoder.extractStreamingPayload(span: payload) {
        case .success(let streaming):
            return streaming
        case .failure(let error):
            throw ResolveError.texture(error)
        }
    }

    /// Walks WPE's image-reference chain (material/model JSON) until it reaches a
    /// real asset path (`.tex` / `.png` / `.jpg` / `.gif`).
    private func resolveImageReference(relativePath: String, depth: Int) throws -> String {
        let lowered = (relativePath as NSString).pathExtension.lowercased()
        if lowered != "json" {
            return relativePath
        }
        if depth >= 4 {
            throw ResolveError.materialUnresolved(reason: "Reference depth exceeded for \(relativePath)")
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
                throw ResolveError.materialUnresolved(reason: "Built-in WPE layer \(relativePath) is not available on macOS")
            }
            throw ResolveError.fileMissing
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            throw ResolveError.materialUnresolved(reason: "Couldn't parse \(relativePath) as JSON")
        }
        guard let dict = parsed as? [String: Any] else {
            throw ResolveError.materialUnresolved(reason: "\(relativePath) is not a JSON object")
        }

        if let materialPath = dict["material"] as? String, !materialPath.isEmpty {
            return try resolveImageReference(relativePath: materialPath, depth: depth + 1)
        }

        if let textureName = firstTextureName(in: dict) {
            return "materials/\(textureName).tex"
        }

        throw ResolveError.materialUnresolved(reason: "\(relativePath) has no `material` or `passes[].textures[]`")
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

    /// Decode-backed probe used by `WallpaperEngineImportService` during capability tier classification.
    func probeImage(relativePath: String) -> Result<WPETexInfo, ResolveError> {
        guard !relativePath.isEmpty else { return .failure(.fileMissing) }
        guard provider.exists(atRelativePath: relativePath) else {
            return .failure(.fileMissing)
        }
        guard (relativePath as NSString).pathExtension.lowercased() == "tex" else {
            return .failure(.unsupportedTexture)
        }
        let span: WPEMappedByteSpan
        do {
            span = try provider.mappedWindow(atRelativePath: relativePath)
        } catch {
            return .failure(.fileMissing)
        }
        switch decoder.probe(span: span) {
        case .success(let info):
            guard info.format?.isPhase21Decodable == true else {
                return .success(info)
            }
            switch decoder.decode(span: span) {
            case .success:
                break
            case .failure(let error):
                return .failure(.texture(error))
            }
            return .success(info)
        case .failure(let error):
            return .failure(.texture(error))
        }
    }

    #if DEBUG
    /// Test-only capability probe; no production reader.
    func probeRenderableImage(relativePath: String) -> Result<Void, ResolveError> {
        guard !relativePath.isEmpty else { return .failure(.fileMissing) }
        let resolvedPath: String
        do {
            resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        } catch let error as ResolveError {
            return .failure(error)
        } catch {
            return .failure(.fileMissing)
        }

        let lowered = (resolvedPath as NSString).pathExtension.lowercased()
        if lowered == "tex" {
            switch probeImage(relativePath: resolvedPath) {
            case .success(let info):
                return info.format?.isPhase21Decodable == true ? .success(()) : .failure(.unsupportedTexture)
            case .failure(let error):
                return .failure(error)
            }
        }

        return exists(relativePath: resolvedPath) ? .success(()) : .failure(.fileMissing)
    }
    #endif

    /// Used by tests + the import service to decide whether a scene's declared
    /// image layers are actually shipped.
    func exists(relativePath: String) -> Bool {
        imageStorageCandidates(for: relativePath).contains { candidate in
            provider.exists(atRelativePath: candidate)
        }
    }

    /// Raw asset bytes; `.fileMissing` continues multi-root fallback.
    func data(relativePath: String) throws -> Data {
        try providerData(relativePath)
    }

    /// File URL for fonts/audio/video (package-backed stages a temp file).
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
