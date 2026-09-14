import Foundation

public enum WallpaperSessionDefinition: Equatable, Sendable {
    /// `packageEntryName` non-nil ⇒ an in-place packaged video: `bookmarkData` resolves
    /// to a `scene.pkg` and the entry is served windowed from it.
    case video(bookmarkData: Data, packageEntryName: String?)
    case html(HTMLSource, HTMLConfig)
    case scene(SceneDescriptor)

    public init?(configuration: ScreenConfiguration) {
        switch configuration.activeWallpaper {
        case .video(let bookmarkData, let packageEntryName):
            guard !bookmarkData.isEmpty else { return nil }
            self = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
        case .html(let source, let config):
            if case .inline(let raw) = source, raw.isEmpty { return nil }
            self = .html(source, config)
        case .scene(let descriptor):
            guard !descriptor.workshopID.isEmpty,
                  !descriptor.cacheRelativePath.isEmpty,
                  !descriptor.entryFile.isEmpty else { return nil }
            self = .scene(descriptor)
        }
    }

    public func displayName(using bookmarkNameResolver: (Data) -> String?) -> String? {
        switch self {
        case .video(let bookmarkData, _):
            return bookmarkNameResolver(bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .scene(let descriptor):
            return "Scene \(descriptor.workshopID)"
        }
    }
}
