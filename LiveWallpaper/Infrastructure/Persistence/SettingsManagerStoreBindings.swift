import CoreGraphics
import Foundation
import LiveWallpaperCore

// Every binding that hands a LiveWallpaperCore store its app-side persistence.
// One concept, previously one file per store.

/// Wires the shared bookmark store to the app's settings persistence.
@MainActor
struct SettingsManagerBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] { SettingsManager.shared.loadWallpaperBookmarks() }
    func save(_ bookmarks: [WallpaperBookmark]) { SettingsManager.shared.saveWallpaperBookmarks(bookmarks) }
}

extension BookmarkStore {
    /// App-wide singleton backed by `SettingsManager.shared`.
    static let shared = BookmarkStore(persistence: SettingsManagerBookmarkPersistence())
}

/// Wires the shared trusted-host store to app settings persistence.
@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ origins: [String]) { SettingsManager.shared.saveTrustedHosts(origins) }
}

extension TrustedHostStore {
    /// Shared app-wide trusted-host store.
    static let shared = TrustedHostStore(persistence: SettingsManagerTrustedHostPersistence())
}

/// Connects the core wallpaper configuration store to app settings persistence.
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
