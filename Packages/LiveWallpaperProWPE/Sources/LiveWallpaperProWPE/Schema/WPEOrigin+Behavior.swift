import Foundation
import LiveWallpaperCore

extension WPEOrigin {
    public var sourcePreviewURL: URL? {
        guard previewFileName != nil,
              let sourceFolder = try? SecurityScopedBookmarkResolver.shared.resolve(sourceFolderBookmark, target: .transient).get().url else {
            return nil
        }
        return sourcePreviewURL(in: sourceFolder)
    }

    public var sourceEntryURL: URL? {
        guard entryFile != nil,
              let sourceFolder = try? SecurityScopedBookmarkResolver.shared.resolve(sourceFolderBookmark, target: .transient).get().url else {
            return nil
        }
        return sourceEntryURL(in: sourceFolder)
    }

    /// Best-effort check.
    public static func matchesBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        switch origin.resourceLocation {
        case .cache:
            return matchesCacheBookmark(bookmarkData, origin: origin)
        case .sourceFolder:
            return matchesSourceFolderBookmark(bookmarkData, origin: origin)
        case .unsupported:
            return false
        }
    }

    private static func matchesCacheBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let cacheRel = origin.cacheRelativePath,
              WPEPathSafety.isSafeCacheRelativePath(cacheRel) else {
            return false
        }
        guard let resolved = try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get().url else { return false }

        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }

        let rootURL = appSupport
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .standardizedFileURL
        let expectedURL = rootURL
            .appendingPathComponent(cacheRel)
            .standardizedFileURL
        guard WPEPathSafety.contains(expectedURL, in: rootURL) else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.path
        let expectedPath = expectedURL.path
        return resolvedPath == expectedPath || resolvedPath.hasPrefix(expectedPath + "/")
    }

    private static func matchesSourceFolderBookmark(_ bookmarkData: Data, origin: WPEOrigin) -> Bool {
        guard let resolved = try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get().url,
              let source = try? SecurityScopedBookmarkResolver.shared.resolve(origin.sourceFolderBookmark, target: .transient).get().url else {
            return false
        }
        let resolvedPath = resolved.standardizedFileURL.resolvingSymlinksInPath().path
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePath = sourceURL.path

        switch origin.originalType {
        case .video:
            // Loose video: bookmark points at the entry file in the folder.
            if let expected = origin.sourceEntryURL(in: source), resolvedPath == expected.path {
                return true
            }
            // In-place packaged video: bookmark points at the source
            // `scene.pkg` (the entry is read windowed from it, not extracted).
            let packagePath = sourceURL
                .appendingPathComponent("scene.pkg")
                .standardizedFileURL
                .path
            return resolvedPath == packagePath
        case .web:
            return resolvedPath == sourcePath
        case .scene, .application, .unknown:
            return false
        }
    }
}

public extension WPEOrigin {
    /// The preview inside an already resolved source folder; saves a second resolve of the same bookmark.
    func sourcePreviewURL(in sourceFolder: URL) -> URL? {
        previewFileName.flatMap { WPEPathSafety.resourceURL(root: sourceFolder, relativePath: $0) }
    }

    /// The entry file inside an already resolved source folder.
    func sourceEntryURL(in sourceFolder: URL) -> URL? {
        entryFile.flatMap { WPEPathSafety.resourceURL(root: sourceFolder, relativePath: $0) }
    }
}
