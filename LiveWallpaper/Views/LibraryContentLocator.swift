import Foundation
import LiveWallpaperCore

/// Where a saved library entry's media actually lives, and whether it is still
/// there. Bookmarks and schemes both need this for two things at once — the
/// Show in Finder action and the unavailable veil — so they resolve it once.
struct LibraryContentLocation {
    /// Folder or file to select in Finder. Nil for content with no local file
    /// (a remote page, inline HTML) and for content whose grant no longer resolves.
    var revealURL: URL?
    /// False once the entry can no longer be applied: the file was deleted, the
    /// security-scoped grant died, or a scene lost the Workshop folder behind it.
    var isAvailable: Bool

    static let unknown = LibraryContentLocation(revealURL: nil, isAvailable: true)
}

enum LibraryContentLocator {
    /// Resolving a security-scoped bookmark touches the filesystem, so call this
    /// from the tile's `.task`, never from `body`.
    @MainActor
    static func locate(
        content: WallpaperContent,
        wpeOrigin: WPEOrigin?
    ) -> LibraryContentLocation {
        switch content {
        case let .video(bookmarkData, _):
            return located(bookmarkData)
        case let .html(source, _):
            // A remote page has no file to reveal and never goes "missing" the
            // way a local one does — reachability there is the network's problem.
            guard let bookmarkData = source.localBookmarkData else {
                return LibraryContentLocation(revealURL: nil, isAvailable: true)
            }
            return located(bookmarkData)
        case .scene:
            // Scene files live in the Steam library, reached only through the
            // origin's source-folder grant; without one the scene is unusable.
            guard let wpeOrigin else {
                return LibraryContentLocation(revealURL: nil, isAvailable: false)
            }
            return located(wpeOrigin.sourceFolderBookmark)
        }
    }

    private static func located(_ bookmarkData: Data?) -> LibraryContentLocation {
        guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmarkData,
            target: .transient
        ) else {
            return LibraryContentLocation(revealURL: nil, isAvailable: false)
        }
        // The grant can resolve to a path whose file has since been deleted, so
        // resolution alone is not existence.
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        let exists = FileManager.default.fileExists(atPath: resolved.url.path)
        return LibraryContentLocation(
            revealURL: exists ? resolved.url : nil,
            isAvailable: exists
        )
    }
}
