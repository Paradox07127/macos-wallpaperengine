import Foundation
import LiveWallpaperCore

struct DirectoryBookmarkResolution {
    let url: URL
    let isStale: Bool
}

/// Read-only security-scoped directory grants, shared by the Aerials and
/// Wallpaper Engine asset libraries.
enum DirectoryBookmarks {
    static func resolveDirectoryBookmark(_ bookmarkData: Data) throws -> DirectoryBookmarkResolution {
        let (url, isStale) = try SecurityScopedBookmarkResolver.shared.resolveData(bookmarkData)
        return DirectoryBookmarkResolution(url: url, isStale: isStale)
    }

    static func createReadOnlyBookmark(for url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let noKeys: Set<URLResourceKey>? = nil
        let noRelativeURL: URL? = nil
        return try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: noKeys,
            relativeTo: noRelativeURL
        )
    }

    static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
