import Foundation
import UniformTypeIdentifiers

/// Versioned Export/Import payload. Readers accept `schemaVersion` ≤ current;
/// optional blobs allow subset backups; `appBundleID` rejects foreign exports.
public struct ConfigurationBundle: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "lwconfig"

    /// Probe order, and it is load-bearing: this bundle's own `*.config` first (each app
    /// exports its own id, so the self probe wins), then the historical ids. The UTI probe
    /// and the import guard read this same list.
    public static let productFamilyBundleIDs = [
        "com.loomscreen.pro",
        "com.taijia.livewallpaper",
        "com.loomscreen",
    ]

    public static let contentType: UTType = {
        var candidates: [String] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            candidates.append(bundleID + ".config")
        }
        candidates.append(contentsOf: productFamilyBundleIDs.map { $0 + ".config" })
        for identifier in candidates {
            if let registered = UTType(identifier) {
                return registered
            }
        }
        return .json
    }()

    public var schemaVersion: Int
    public var appBundleID: String
    public var appVersion: String?
    public var exportedAt: Date
    public var screenConfigurations: [ScreenConfiguration]?
    public var globalSettings: GlobalSettings?
    public var wallpaperBookmarks: [WallpaperBookmark]?
    /// Absent in every backup written before schemes existed. Optional, so an
    /// old `.lwconfig` still decodes — it just restores no schemes.
    public var screenSchemes: [ScreenScheme]?
    /// nil = the backup carries no Workshop bookmarks: written before they existed, by Lite, or with none saved.
    public var workshopBookmarks: [WorkshopBookmark]?
    /// `LibraryBookmarkStore.ids`, empty when none are marked; nil = written before library bookmarks existed.
    public var libraryBookmarks: [String]?

    public init(
        schemaVersion: Int = ConfigurationBundle.currentSchemaVersion,
        appBundleID: String = Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        exportedAt: Date = Date(),
        screenConfigurations: [ScreenConfiguration]? = nil,
        globalSettings: GlobalSettings? = nil,
        wallpaperBookmarks: [WallpaperBookmark]? = nil,
        screenSchemes: [ScreenScheme]? = nil,
        workshopBookmarks: [WorkshopBookmark]? = nil,
        libraryBookmarks: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appBundleID = appBundleID
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.screenConfigurations = screenConfigurations
        self.globalSettings = globalSettings
        self.wallpaperBookmarks = wallpaperBookmarks
        self.screenSchemes = screenSchemes
        self.workshopBookmarks = workshopBookmarks
        self.libraryBookmarks = libraryBookmarks
    }
}

public extension ConfigurationBundle {
    /// Import merges by Workshop id: a bookmark already saved keeps its entry, and nothing saved is cleared.
    @MainActor
    func mergeWorkshopBookmarks(into store: WorkshopBookmarkStore) {
        store.merge(workshopBookmarks ?? [])
    }

    /// Import adds the backup's marks; nothing marked here is cleared.
    /// `renaming` maps a backup mark to the ID of the entry it was merged into.
    @MainActor
    func mergeLibraryBookmarks(into store: LibraryBookmarkStore, renaming: [String: String] = [:]) {
        store.merge((libraryBookmarks ?? []).map { renaming[$0] ?? $0 })
    }
}
