#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// A location reference, not a retained security-scope lease. Revealing a source
/// resolves its bookmark again and holds access only for the Finder operation.
struct StorageLinkedSource: Identifiable, Sendable {
    let url: URL
    let bookmark: Data
    var id: String {
        url.standardizedFileURL.path
    }
}

@MainActor
enum StorageLinkedSources {
    static func current(excluding roots: [URL]) -> (sources: [StorageLinkedSource], unresolved: Int) {
        let settings = SettingsManager.shared
        var data = Set<Data>()
        func add(_ content: WallpaperContent) {
            if let bookmark = content.activeVideoBookmarkData {
                data.insert(bookmark)
            }
            if let bookmark = content.htmlSource?.localBookmarkData {
                data.insert(bookmark)
            }
        }
        func add(_ entry: WallpaperQueueEntry?) {
            guard let entry else { return }
            add(entry.content)
            if let origin = entry.origin {
                data.insert(origin.sourceFolderBookmark)
            }
        }
        func add(_ configuration: ScreenConfiguration) {
            add(configuration.activeWallpaper)
            if let origin = configuration.wpeOrigin {
                data.insert(origin.sourceFolderBookmark)
            }
            if let bookmark = configuration.savedVideoBookmarkData {
                data.insert(bookmark)
            }
            if let bookmark = configuration.savedHTMLSource?.localBookmarkData {
                data.insert(bookmark)
            }
            configuration.combinedPlaylist.forEach { data.insert($0) }
            configuration.wallpaperQueue?.forEach { add($0) }
            add(configuration.scheduleFallback)
            for slot in configuration.scheduleSlots ?? [] {
                add(slot.wallpaper)
                if let bookmark = slot.videoBookmarkData {
                    data.insert(bookmark)
                }
            }
            configuration.automationFailures.values.forEach { add($0.entry) }
        }
        settings.loadConfigurations().forEach { add($0) }
        SchemeStore.shared.schemes.forEach { add($0.configuration) }
        for bookmark in BookmarkStore.shared.bookmarks {
            add(bookmark.content)
            if let origin = bookmark.wpeOrigin {
                data.insert(origin.sourceFolderBookmark)
            }
        }
        settings.loadGlobalSettings().recentWPEImports.forEach { data.insert($0.origin.sourceFolderBookmark) }
        if let bookmark = settings.loadAerialsDirectoryBookmark() {
            data.insert(bookmark)
        }
        var byPath: [String: StorageLinkedSource] = [:]
        var unresolved = 0
        let rootPaths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        for bookmark in data where !bookmark.isEmpty {
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient) else {
                unresolved += 1
                continue
            }
            let path = resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !rootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            byPath[path] = StorageLinkedSource(url: URL(fileURLWithPath: path), bookmark: bookmark)
        }
        return (distinctRoots(Array(byPath.values)), unresolved)
    }

    nonisolated static func distinctRoots(_ sources: [StorageLinkedSource]) -> [StorageLinkedSource] {
        var roots: [StorageLinkedSource] = []
        for source in sources.sorted(by: { $0.id < $1.id }) {
            guard !roots.contains(where: { source.id == $0.id || source.id.hasPrefix($0.id + "/") }) else { continue }
            roots.append(source)
        }
        return roots
    }

    /// Hold the original scoped URL while the scanner reads its canonical target.
    static func scan(_ sources: [StorageLinkedSource], locations: [AppStorageLocation], excluding roots: [URL]) async -> [AppStorageMeasurement] {
        var leases: [URL] = []
        var authorized: [AppStorageLocation] = []
        var unavailable: [AppStorageMeasurement] = []
        for source in sources {
            let location = AppStorageLocation(kind: .localWallpapers, url: source.url)
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(source.bookmark, target: .transient) else {
                unavailable.append(.init(location: location, bytes: 0, fileCount: 0, status: .unavailable))
                continue
            }
            let didStart = resolved.url.startAccessingSecurityScopedResource()
            if didStart {
                leases.append(resolved.url)
            }
            guard !resolved.isSecurityScoped || didStart else {
                unavailable.append(.init(location: location, bytes: 0, fileCount: 0, status: .unavailable))
                continue
            }
            authorized.append(location)
        }
        defer { leases.forEach { $0.stopAccessingSecurityScopedResource() } }
        return await AppStorageScanner.shared.scan(locations + authorized, excluding: roots) + unavailable
    }
}
#endif
