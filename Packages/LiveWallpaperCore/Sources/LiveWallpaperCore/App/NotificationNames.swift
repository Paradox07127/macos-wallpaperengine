import Foundation

// MARK: - Centralized Notification Names

public extension Notification.Name {
    static let screensRefreshed = Notification.Name("ScreensRefreshed")

    static let selectScreenInSettings = Notification.Name("SelectScreenInSettings")

    static let openGeneralSettings = Notification.Name("OpenGeneralSettings")

    /// `userInfo["destination"]`: a `SettingsNavigation` raw value; `userInfo["anchor"]`: an
    /// optional `SettingsSearchAnchor` raw value — raw because both enums live in the app target.
    static let openSettingsSection = Notification.Name("OpenSettingsSection")

    static let showOnboarding = Notification.Name("ShowOnboarding")

    /// Announces a persisted configuration change; `userInfo["screenID"]` identifies the display.
    static let wallpaperConfigurationDidChange = Notification.Name("WallpaperConfigurationDidChange")

    /// Announces a WPE import result with `screenID` and original `type` in `userInfo`.
    static let wpeImportDidComplete = Notification.Name("WPEImportDidComplete")

    /// The recent WPE import history (LRU) was mutated; reload from
    /// `SettingsManager.shared.loadGlobalSettings().recentWPEImports`.
    static let wpeHistoryDidChange = Notification.Name("WPEHistoryDidChange")

    /// Requests an Add Wallpaper picker from the main window; `userInfo["kind"]` identifies the source type.
    static let promptAddWallpaper = Notification.Name("PromptAddWallpaper")

    /// A scene preset was added, renamed, or deleted.
    static let scenePresetLibraryDidChange = Notification.Name("ScenePresetLibraryDidChange")

    /// Wallpaper Engine install-root bookmark was set or cleared.
    static let wpeEngineAssetsBookmarkDidChange = Notification.Name("WPEEngineAssetsBookmarkDidChange")

    /// `GlobalSettings.showInDock` changed.
    static let dockVisibilityDidChange = Notification.Name("DockVisibilityDidChange")

    /// User-configurable global shortcut bindings changed.
    static let globalShortcutsDidChange = Notification.Name("GlobalShortcutsDidChange")

    /// User changed the weather location preference (source / manual coord).
    static let weatherLocationPreferenceDidChange = Notification.Name("WeatherLocationPreferenceDidChange")

    /// `GlobalSettings.showsWorkshopPresetsInBrowse` changed. Browse reads the
    /// setting per request, so the grid already on screen only refreshes on this.
    static let workshopPresetVisibilityDidChange = Notification.Name("WorkshopPresetVisibilityDidChange")

    static let openWorkshopPane = Notification.Name("OpenWorkshopPane")

    static let openAppleAerials = Notification.Name("OpenAppleAerials")

    /// `SMAppService.register/unregister` produced an outcome needing user-visible
    /// follow-up. `userInfo["reason"]: LoginItemFailure`.
    static let loginItemRegistrationDidFail = Notification.Name("LoginItemRegistrationDidFail")
}
