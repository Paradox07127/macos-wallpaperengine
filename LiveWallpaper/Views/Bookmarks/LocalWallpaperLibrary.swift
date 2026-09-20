#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import SwiftUI

/// Directory contents are the source of truth; neither saved bookmarks nor the
/// capped import history decides which downloaded projects appear here.
@MainActor
@Observable
final class LocalWallpaperLibrary {
    private(set) var entries: [WPEHistoryEntry] = []
    private(set) var isScanning = false
    private(set) var unreadableCount = 0
    private var generation = 0

    func reload(using doctor: SteamCMDDoctorService) async {
        generation += 1
        let ticket = generation
        isScanning = true
        defer {
            if generation == ticket {
                isScanning = false
            }
        }
        var found: [String: WPEHistoryEntry] = [:]
        var unreadable = 0
        func read(_ folder: URL) {
            guard !Task.isCancelled else { return }
            do {
                if let entry = try Self.readEntry(in: folder) {
                    found[entry.id] = entry
                }
            } catch {
                unreadable += 1
                Logger.warning("Could not read a local wallpaper project", category: .fileAccess)
            }
        }
        // External project folders retain their existing security-scoped grant.
        // A missing folder is omitted, rather than displaying a stale history row.
        for entry in SettingsManager.shared.loadGlobalSettings().recentWPEImports {
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                entry.origin.sourceFolderBookmark, target: .transient
            ) else { continue }
            SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                guard FileManager.default.fileExists(atPath: resolved.url.path) else { return }
                read(resolved.url)
            }
        }
        await doctor.enumerateDownloadedItemFolders { folder in read(folder) }
        guard !Task.isCancelled, generation == ticket else { return }
        entries = Array(found.values)
        unreadableCount = unreadable
        WPEPreviewURLCache.shared.prefetch(entries)
    }

    static func readEntry(
        in folder: URL,
        makeBookmark: (URL) -> Data? = { ResourceUtilities.createBookmark(for: $0) }
    ) throws -> WPEHistoryEntry? {
        let project = try WallpaperEngineProject.read(from: folder)
        guard project.scenePreset() == nil,
              [.video, .web, .scene].contains(project.type) else { return nil }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(project.entryFile).path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let bookmark = makeBookmark(folder) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let origin = WPEOrigin(
            workshopID: project.workshopID, title: project.title, originalType: project.type,
            sourceFolderBookmark: bookmark, cacheRelativePath: nil,
            previewFileName: project.previewFileName, entryFile: project.entryFile,
            resourceLocation: .sourceFolder, dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            requiresWindowsPlugin: project.requiresWindowsPlugin
        )
        let dates = try folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return WPEHistoryEntry(origin: origin, importedAt: dates.creationDate ?? dates.contentModificationDate ?? .distantPast)
    }
}

extension WPEHistoryEntry {
    var localWallpaperType: WallpaperType {
        switch origin.originalType {
        case .video: .video
        case .web: .html
        default: .scene
        }
    }
}
#endif
