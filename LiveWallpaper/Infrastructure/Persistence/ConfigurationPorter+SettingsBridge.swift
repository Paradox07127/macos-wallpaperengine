import Foundation
import LiveWallpaperCore

@MainActor
extension ConfigurationPorter {
    static func currentBundle() -> ConfigurationBundle {
        let manager = SettingsManager.shared
        var bundle = ConfigurationBundle(
            screenConfigurations: manager.loadConfigurations(),
            globalSettings: manager.loadGlobalSettings(),
            wallpaperBookmarks: manager.loadWallpaperBookmarks(),
            screenSchemes: manager.loadScreenSchemes()
        )
        let libraryBookmarks = LibraryBookmarkStore.shared.ids
        bundle.libraryBookmarks = libraryBookmarks.isEmpty ? nil : libraryBookmarks
        #if !LITE_BUILD
        let workshopBookmarks = WorkshopBookmarkStore.shared.bookmarks
        bundle.workshopBookmarks = workshopBookmarks.isEmpty ? nil : workshopBookmarks
        #endif
        return bundle
    }

    /// The sections this SKU accepts, shared by confirmation and the result of applying the bundle.
    static func importSummary(for bundle: ConfigurationBundle) -> ApplySummary {
        #if LITE_BUILD
        let workshopBookmarkCount: Int? = nil
        #else
        let workshopBookmarkCount = bundle.workshopBookmarks?.count
        #endif
        // Library bookmarks are reported on the saved-bookmarks line.
        let bookmarkCounts = [bundle.wallpaperBookmarks?.count, bundle.libraryBookmarks?.count].compactMap(\.self)
        return ApplySummary(
            displayCount: bundle.screenConfigurations?.count,
            bookmarkCount: bookmarkCounts.isEmpty ? nil : bookmarkCounts.reduce(0, +),
            workshopBookmarkCount: workshopBookmarkCount,
            schemeCount: bundle.screenSchemes?.count,
            didRestoreGlobalSettings: bundle.globalSettings != nil
        )
    }

    @discardableResult
    static func apply(_ bundle: ConfigurationBundle) -> ApplySummary {
        let manager = SettingsManager.shared
        let summary = importSummary(for: bundle)

        if let configurations = bundle.screenConfigurations {
            manager.replaceAllConfigurations(configurations)
        }

        if let global = bundle.globalSettings {
            manager.saveGlobalSettings(global)
            // The imported library may rename or delete presets the cached
            // configurations still carry snapshots of.
            manager.reconcileScenePresetSnapshots()
        }

        if let bookmarks = bundle.wallpaperBookmarks {
            let merged = mergingWallpaperBookmarks(
                existing: manager.loadWallpaperBookmarks(),
                imported: bookmarks
            )
            manager.saveWallpaperBookmarks(merged)
            BookmarkStore.shared.reload()
        }

        // Schemes are per-machine archives like bookmarks, so a backup that
        // ignored them would silently drop every saved scheme on restore.
        if let schemes = bundle.screenSchemes {
            let merged = mergingScreenSchemes(
                existing: manager.loadScreenSchemes(),
                imported: schemes
            )
            manager.saveScreenSchemes(merged)
            SchemeStore.shared.reload()
        }

        bundle.mergeLibraryBookmarks(into: .shared)

        #if !LITE_BUILD
        bundle.mergeWorkshopBookmarks(into: .shared)
        #endif

        Logger.info(
            "Configuration import applied (displays=\(summary.displayCount ?? 0), global=\(summary.didRestoreGlobalSettings), bookmarks=\(summary.bookmarkCount ?? 0), schemes=\(bundle.screenSchemes?.count ?? 0))",
            category: .settings
        )

        return summary
    }

    /// Import merges: an existing entry with the same identity or content source is kept; only backup entries pointing at new sources are appended.
    static func mergingWallpaperBookmarks(
        existing: [WallpaperBookmark],
        imported: [WallpaperBookmark]
    ) -> [WallpaperBookmark] {
        var merged = existing
        var ids = Set(existing.map(\.id))
        var contents = Dictionary(grouping: existing.map(\.content), by: mergeBucket)
        for candidate in imported {
            let bucket = mergeBucket(candidate.content)
            guard !ids.contains(candidate.id), !(contents[bucket] ?? []).contains(candidate.content) else { continue }
            merged.append(candidate)
            ids.insert(candidate.id)
            contents[bucket, default: []].append(candidate.content)
        }
        return merged
    }

    /// Built only from fields `WallpaperContent.==` compares, so equal contents always share a bucket.
    private static func mergeBucket(_ content: WallpaperContent) -> [AnyHashable] {
        switch content {
        case let .video(bookmarkData, packageEntryName):
            ["video", bookmarkData, packageEntryName]
        case let .html(source, _):
            switch source {
            case let .file(bookmarkData): ["html.file", bookmarkData]
            case let .folder(bookmarkData, indexFileName): ["html.folder", bookmarkData, indexFileName]
            case let .url(url): ["html.url", url]
            case let .inline(html): ["html.inline", html]
            }
        case let .scene(descriptor):
            ["scene", descriptor.workshopID, descriptor.cacheRelativePath]
        }
    }

    /// Same merge rule as bookmarks: an existing scheme wins over an imported
    /// one with the same id, and only genuinely new archives are appended.
    static func mergingScreenSchemes(
        existing: [ScreenScheme],
        imported: [ScreenScheme]
    ) -> [ScreenScheme] {
        var merged = existing
        for candidate in imported where !merged.contains(where: { $0.id == candidate.id }) {
            merged.append(candidate)
        }
        return merged
    }
}
