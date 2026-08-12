import Foundation

public enum WallpaperContent: Equatable, Sendable {
    /// Loose file when `packageEntryName` is nil; else bookmark → `scene.pkg` entry (no extract).
    case video(bookmarkData: Data, packageEntryName: String?)
    case html(source: HTMLSource, config: HTMLConfig)
    case scene(SceneDescriptor)

    public static func video(bookmarkData: Data) -> WallpaperContent {
        .video(bookmarkData: bookmarkData, packageEntryName: nil)
    }

    public var wallpaperType: WallpaperType {
        switch self {
        case .video:
            return .video
        case .html:
            return .html
        case .scene:
            return .scene
        }
    }

    public var activeVideoBookmarkData: Data? {
        guard case .video(let bookmarkData, _) = self else { return nil }
        return bookmarkData
    }

    public var packageVideoEntryName: String? {
        guard case .video(_, let entryName) = self else { return nil }
        return entryName
    }

    public var htmlSource: HTMLSource? {
        guard case .html(let source, _) = self else { return nil }
        return source
    }

    public var htmlConfig: HTMLConfig? {
        guard case .html(_, let config) = self else { return nil }
        return config
    }

    public var sceneDescriptor: SceneDescriptor? {
        guard case .scene(let descriptor) = self else { return nil }
        return descriptor
    }

    /// Live `scene.pkg` dependency (not just a cache copy). Prefer over-report:
    /// under-report + reclaim breaks the wallpaper. `.html(.folder)` is always true
    /// (folder import may serve package; content does not record which path).
    public var mayReadFromSourcePackage: Bool {
        switch self {
        case .video(_, let packageEntryName):
            return packageEntryName != nil
        case .html(let source, _):
            if case .folder = source { return true }
            return false
        case .scene(let descriptor):
            if case .packageSource = descriptor.assetStorage { return true }
            return false
        }
    }
}

// MARK: - Codable

extension WallpaperContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case video, html, scene
    }

    private enum VideoCodingKeys: String, CodingKey {
        case bookmarkData
        case packageEntryName
    }

    private enum HTMLCodingKeys: String, CodingKey {
        case source
        case config
    }

    private enum SceneCodingKeys: String, CodingKey {
        case descriptor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let videoNested = try? container.nestedContainer(keyedBy: VideoCodingKeys.self, forKey: .video) {
            let bookmark = try videoNested.decode(Data.self, forKey: .bookmarkData)
            // Legacy payloads omit this → loose file.
            let packageEntryName = try videoNested.decodeIfPresent(String.self, forKey: .packageEntryName)
            self = .video(bookmarkData: bookmark, packageEntryName: packageEntryName)
            return
        }

        if let htmlNested = try? container.nestedContainer(keyedBy: HTMLCodingKeys.self, forKey: .html) {
            if let source = try? htmlNested.decode(HTMLSource.self, forKey: .source) {
                let config = try htmlNested.decodeIfPresent(HTMLConfig.self, forKey: .config) ?? HTMLConfig()
                self = .html(source: source, config: config)
                return
            }
        }

        if let sceneNested = try? container.nestedContainer(keyedBy: SceneCodingKeys.self, forKey: .scene) {
            let descriptor = try sceneNested.decode(SceneDescriptor.self, forKey: .descriptor)
            self = .scene(descriptor)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "WallpaperContent decode failed: no recognised case in container"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let bookmarkData, let packageEntryName):
            var nested = container.nestedContainer(keyedBy: VideoCodingKeys.self, forKey: .video)
            try nested.encode(bookmarkData, forKey: .bookmarkData)
            try nested.encodeIfPresent(packageEntryName, forKey: .packageEntryName)
        case .html(let source, let config):
            var nested = container.nestedContainer(keyedBy: HTMLCodingKeys.self, forKey: .html)
            try nested.encode(source, forKey: .source)
            try nested.encode(config, forKey: .config)
        case .scene(let descriptor):
            var nested = container.nestedContainer(keyedBy: SceneCodingKeys.self, forKey: .scene)
            try nested.encode(descriptor, forKey: .descriptor)
        }
    }
}
