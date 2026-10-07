import CoreGraphics
import Foundation
import LiveWallpaperCore


@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    var manager: SettingsManager = .shared

    func load() -> [WallpaperBookmark] {
        manager.loadWallpaperBookmarks()
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        manager.saveWallpaperBookmarks(bookmarks)
    }
}

extension BookmarkStore {
    static let shared = BookmarkStore(persistence: SettingsManagerBookmarkPersistence())
}

@MainActor
struct SettingsManagerSchemePersistence: SchemePersisting {
    var manager: SettingsManager = .shared

    func load() -> [ScreenScheme] {
        manager.loadScreenSchemes()
    }

    func save(_ schemes: [ScreenScheme]) {
        manager.saveScreenSchemes(schemes)
    }
}

extension SchemeStore {
    static let shared = SchemeStore(persistence: SettingsManagerSchemePersistence())
}

@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ origins: [String]) { SettingsManager.shared.saveTrustedHosts(origins) }
}

extension TrustedHostStore {
    static let shared = TrustedHostStore(persistence: SettingsManagerTrustedHostPersistence())
}

@MainActor
struct SettingsManagerScreenConfigurationPersistence: ScreenConfigurationPersisting {
    var manager: SettingsManager = .shared

    func configurationRevision(for screenID: CGDirectDisplayID) -> UInt64? {
        manager.configurationMemoryRevision(for: screenID)
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        manager.getConfiguration(for: screenID)
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        manager.saveConfiguration(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        manager.cleanSettingsForScreen(screenID)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        manager.loadConfigurations()
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        manager.replaceAllConfigurations(configurations)
    }
}

extension WallpaperConfigurationStore {
    convenience init() {
        self.init(persistence: SettingsManagerScreenConfigurationPersistence())
    }
}

@MainActor
protocol GlobalSettingsPersisting: AnyObject {
    func loadGlobalSettings() -> GlobalSettings
    func saveGlobalSettings(_ settings: GlobalSettings)
}

extension SettingsManager: GlobalSettingsPersisting {}
