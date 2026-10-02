import Foundation
import LiveWallpaperCore

@MainActor
extension ConfigurationPorter {
    static func currentBundle() -> ConfigurationBundle {
        let manager = SettingsManager.shared
        var global = manager.loadGlobalSettings()
        // Paused displays belong to this machine; a backup never carries them.
        global.pausedDisplayKeys = []
        var bundle = ConfigurationBundle(
            screenConfigurations: manager.loadConfigurations(),
            globalSettings: global,
            wallpaperBookmarks: manager.loadWallpaperBookmarks(),
            screenSchemes: manager.loadScreenSchemes()
        )
        bundle.libraryBookmarks = LibraryBookmarkStore.shared.ids
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
        // Library bookmarks are reported on the saved-bookmarks line; a mark on an entry of this backup is that entry.
        let entryMarks = Set((bundle.wallpaperBookmarks ?? []).map { "bookmark:\($0.id)" })
        let otherMarkCount = bundle.libraryBookmarks?.count(where: { !entryMarks.contains($0) })
        let bookmarkCounts = [bundle.wallpaperBookmarks?.count, otherMarkCount].compactMap(\.self)
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

        if let configurations = bundle.screenConfigurations {
            manager.replaceAllConfigurations(configurations)
        }

        if var global = bundle.globalSettings {
            global.pausedDisplayKeys = manager.loadGlobalSettings().pausedDisplayKeys
            manager.saveGlobalSettings(global)
            // The imported library may rename or delete presets the cached
            // configurations still carry snapshots of.
            manager.reconcileScenePresetSnapshots()
        }

        var renamedLibraryBookmarks: [String: String] = [:]
        if let bookmarks = bundle.wallpaperBookmarks {
            let merged = mergingWallpaperBookmarks(
                existing: manager.loadWallpaperBookmarks(),
                imported: bookmarks
            )
            manager.saveWallpaperBookmarks(merged.bookmarks)
            BookmarkStore.shared.reload()
            for (dropped, kept) in merged.keptIDs {
                renamedLibraryBookmarks["bookmark:\(dropped)"] = "bookmark:\(kept)"
            }
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

        bundle.mergeLibraryBookmarks(into: .shared, renaming: renamedLibraryBookmarks)

        #if !LITE_BUILD
        // A backup from before library bookmarks: this machine's one-time carry-over has long run.
        if bundle.libraryBookmarks == nil, bundle.wallpaperBookmarks != nil {
            let installed = Set(manager.loadGlobalSettings().recentWPEImports.map(\.id))
            LibraryBookmarkStore.shared.merge(
                SavedLibraryModel.foldedBookmarkMarks(manager.loadWallpaperBookmarks(), installed: installed)
            )
        }
        bundle.mergeWorkshopBookmarks(into: .shared)
        #endif

        // An unreadable archive refused every imported mark.
        var counted = bundle
        if LibraryBookmarkStore.shared.isArchiveUnreadable {
            counted.libraryBookmarks = nil
        }
        let summary = importSummary(for: counted)

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
    ) -> (bookmarks: [WallpaperBookmark], keptIDs: [UUID: UUID]) {
        var merged = existing
        var ids = Set(existing.map(\.id))
        var entries = Dictionary(grouping: existing, by: { mergeBucket($0.content) })
        var keptIDs: [UUID: UUID] = [:]
        for candidate in imported where !ids.contains(candidate.id) {
            let bucket = mergeBucket(candidate.content)
            if let kept = entries[bucket]?.first(where: { $0.content == candidate.content }) {
                keptIDs[candidate.id] = kept.id
                continue
            }
            merged.append(candidate)
            ids.insert(candidate.id)
            entries[bucket, default: []].append(candidate)
        }
        return (merged, keptIDs)
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
