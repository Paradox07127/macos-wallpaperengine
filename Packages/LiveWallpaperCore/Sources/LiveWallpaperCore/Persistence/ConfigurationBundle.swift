import Foundation
import UniformTypeIdentifiers

/// Versioned Export/Import payload. Readers accept `schemaVersion` ≤ current;
/// optional blobs allow subset backups; `appBundleID` rejects foreign exports.
public struct ConfigurationBundle: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "lwconfig"

    /// Host-registered UTType. Probe order: this bundle's own `*.config` (each app exports its own
    /// id, so the self probe wins deterministically), then the historical ids, then `.json`. The old
    /// "does the bundle id contain loomscreen" SKU discriminator broke when Pro became
    /// `com.loomscreen.pro` and started matching Lite's UTI, whose extension is not `lwconfig`.
    public static let contentType: UTType = {
        var candidates: [String] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            candidates.append(bundleID + ".config")
        }
        candidates.append("com.loomscreen.pro.config")
        candidates.append("com.taijia.livewallpaper.config")
        candidates.append("com.loomscreen.config")
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

    public init(
        schemaVersion: Int = ConfigurationBundle.currentSchemaVersion,
        appBundleID: String = Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        exportedAt: Date = Date(),
        screenConfigurations: [ScreenConfiguration]? = nil,
        globalSettings: GlobalSettings? = nil,
        wallpaperBookmarks: [WallpaperBookmark]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appBundleID = appBundleID
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.screenConfigurations = screenConfigurations
        self.globalSettings = globalSettings
        self.wallpaperBookmarks = wallpaperBookmarks
    }
}
