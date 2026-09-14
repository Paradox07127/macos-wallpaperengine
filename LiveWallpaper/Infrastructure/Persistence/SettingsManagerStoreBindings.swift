import CoreGraphics
import Foundation
import LiveWallpaperCore


@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] { SettingsManager.shared.loadWallpaperBookmarks() }
    func save(_ bookmarks: [WallpaperBookmark]) { SettingsManager.shared.saveWallpaperBookmarks(bookmarks) }
}

extension BookmarkStore {
    static let shared = BookmarkStore(persistence: SettingsManagerBookmarkPersistence())
}

@MainActor
struct SettingsManagerSchemePersistence: SchemePersisting {
    func load() -> [ScreenScheme] {
        SettingsManager.shared.loadScreenSchemes()
    }

    func save(_ schemes: [ScreenScheme]) {
        SettingsManager.shared.saveScreenSchemes(schemes)
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
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        SettingsManager.shared.getConfiguration(for: screenID)
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        SettingsManager.shared.saveConfiguration(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        SettingsManager.shared.cleanSettingsForScreen(screenID)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        SettingsManager.shared.loadConfigurations()
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        SettingsManager.shared.replaceAllConfigurations(configurations)
    }
}

extension WallpaperConfigurationStore {
    convenience init() {
        self.init(persistence: SettingsManagerScreenConfigurationPersistence())
    }
}
