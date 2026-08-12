import Foundation
import LiveWallpaperCore

/// What a picked-or-dropped URL turns out to be.
///
/// `sceneLibrary` is the batch case the Workshop folder button used to own: a
/// folder that is not itself a project but holds numbered project folders.
enum WallpaperImportRoute: Equatable {
    case video(URL)
    case sceneProject(URL)
    case sceneLibrary(URL)
    case html(HTMLSource)
    case unsupported
}

/// One classifier for every import surface — the toolbar picker, the display
/// page's drop target, and the onboarding picker. Each of those grew its own
/// copy of "is this a scene folder?", and they had already drifted: the drop
/// handler checked HTML first, and `isSupportedHTMLResourceURL` answers `true`
/// for *any* directory, so a scene folder became a web wallpaper.
///
/// Classification only. Applying the result differs per caller (one display vs
/// every display vs the Workshop library), so that stays with the caller.
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

        // Scene checks precede the HTML folder fallback, which accepts anything.
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

    /// The manifest `WorkshopFolderImportCoordinator` keys on, so a folder that
    /// imports here imports there too.
    static func isWallpaperEngineProjectFolder(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.json").path
        )
    }

    /// A library root: not a project itself, but holding at least one.
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
