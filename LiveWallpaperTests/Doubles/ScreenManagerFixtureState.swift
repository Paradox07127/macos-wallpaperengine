import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore

/// Per-fixture state: no process-global snapshot, reset, or restore.
@MainActor
final class ScreenManagerFixtureState: ScreenConfigurationPersisting, GlobalSettingsPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private var settings = GlobalSettings()
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }

    func loadGlobalSettings() -> GlobalSettings {
        settings
    }

    func saveGlobalSettings(_ settings: GlobalSettings) {
        self.settings = settings
    }
}
