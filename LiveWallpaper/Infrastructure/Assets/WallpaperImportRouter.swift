import Foundation
import LiveWallpaperCore

enum WallpaperImportRoute: Equatable {
    case video(URL)
    case sceneProject(URL)
    case sceneLibrary(URL)
    case html(HTMLSource)
    case unsupported
}

/// Scene checks must precede the HTML folder fallback: `isSupportedHTMLResourceURL` answers true for any directory, so a scene folder would become a web wallpaper.
@MainActor
enum WallpaperImportRouter {
    static func route(_ url: URL, sceneCapable: Bool) -> WallpaperImportRoute {
        guard url.isFileURL else { return .unsupported }

        if ResourceUtilities.isSupportedVideoURL(url) {
            return .video(url)
        }

        guard isDirectory(url) else {
            guard ResourceUtilities.isSupportedHTMLResourceURL(url),
                  let source = ResourceUtilities.htmlSourceFromPickedFile(url) else {
                return .unsupported
            }
            return .html(source)
        }

        if sceneCapable {
            if isWallpaperEngineProjectFolder(url) { return .sceneProject(url) }
            if containsWallpaperEngineProjects(url) { return .sceneLibrary(url) }
        }

        guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
            return .unsupported
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return .html(
            .folder(
                bookmarkData: bookmark,
                indexFileName: ResourceUtilities.inferHTMLIndexFileName(from: entries)
            )
        )
    }

    static func isWallpaperEngineProjectFolder(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.json").path
        )
    }

    static func containsWallpaperEngineProjects(_ url: URL) -> Bool {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        return children.contains { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fileManager.fileExists(
                atPath: child.appendingPathComponent("project.json").path
            )
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
