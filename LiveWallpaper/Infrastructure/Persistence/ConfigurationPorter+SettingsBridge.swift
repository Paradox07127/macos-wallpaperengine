import Foundation
import LiveWallpaperCore

/// Connects the core configuration porter to app settings and bookmarks.
@MainActor
extension ConfigurationPorter {
    static func currentBundle() -> ConfigurationBundle {
        let manager = SettingsManager.shared
        return ConfigurationBundle(
            screenConfigurations: manager.loadConfigurations(),
            globalSettings: manager.loadGlobalSettings(),
            wallpaperBookmarks: manager.loadWallpaperBookmarks(),
            screenSchemes: manager.loadScreenSchemes()
        )
    }

    @discardableResult
    static func apply(_ bundle: ConfigurationBundle) -> ApplySummary {
        let manager = SettingsManager.shared
        var summary = ApplySummary(displayCount: nil, bookmarkCount: nil, didRestoreGlobalSettings: false)

        if let configurations = bundle.screenConfigurations {
            manager.replaceAllConfigurations(configurations)
            summary.displayCount = configurations.count
        }

        if let global = bundle.globalSettings {
            manager.saveGlobalSettings(global)
            // The imported library may rename or delete presets the cached
            // configurations still carry snapshots of.
            manager.reconcileScenePresetSnapshots()
            summary.didRestoreGlobalSettings = true
        }

        if let bookmarks = bundle.wallpaperBookmarks {
            let merged = mergingWallpaperBookmarks(
                existing: manager.loadWallpaperBookmarks(),
                imported: bookmarks
            )
            manager.saveWallpaperBookmarks(merged)
            BookmarkStore.shared.reload()
            summary.bookmarkCount = bookmarks.count
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

        Logger.info(
            "Configuration import applied (displays=\(summary.displayCount ?? 0), global=\(summary.didRestoreGlobalSettings), bookmarks=\(summary.bookmarkCount ?? 0), schemes=\(bundle.screenSchemes?.count ?? 0))",
            category: .settings
        )

        return summary
    }

    /// Import merges into the existing library, matching the Settings copy:
    /// an existing entry with the same identity or the same content source is
    /// kept as-is; only backup entries pointing at new sources are appended.
    static func mergingWallpaperBookmarks(
        existing: [WallpaperBookmark],
        imported: [WallpaperBookmark]
    ) -> [WallpaperBookmark] {
        var merged = existing
        for candidate in imported {
            let alreadyPresent = merged.contains {
                $0.id == candidate.id || $0.content == candidate.content
            }
            if !alreadyPresent {
                merged.append(candidate)
            }
        }
        return merged
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
