import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("GlobalSettings: persisted app preferences") @MainActor
struct GlobalSettingsAppPreferencesTests {
    @Test("Dock visibility round-trips through encode/decode")
    func dockVisibilityRoundTrips() {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.showInDock = true
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.showInDock == true)

        settings.showInDock = false
        SettingsManager.shared.saveGlobalSettings(settings)
        #expect(SettingsManager.shared.loadGlobalSettings().showInDock == false)
    }

    @Test("Legacy settings without showInDock decode safely")
    func legacySettingsWithoutShowInDockDecodeSafely() throws {
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "pauseOnFullScreen": true,
          "recentWPEImports": []
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(decoded.showInDock == false)
        #expect(decoded.weatherLocation == .default)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Weather location preference round-trips through encode/decode")
    func weatherLocationPreferenceRoundTrips() {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual,
            manual: .init(latitude: 35.6762, longitude: 139.6503, name: "Tokyo, Japan")
        )
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.weatherLocation.source == .manual)
        #expect(reloaded.weatherLocation.manual?.name == "Tokyo, Japan")
        #expect(abs((reloaded.weatherLocation.manual?.latitude ?? 0) - 35.6762) < 0.0001)
    }

    @Test("Shortcut bindings round-trip through encode/decode")
    func shortcutBindingsRoundTrip() {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.globalShortcuts = [
            GlobalShortcutAction.togglePlayback.rawAction:
                GlobalShortcutBinding(keyCode: 49, modifiers: [.command, .shift]),
            GlobalShortcutAction.nextWallpaper.rawAction: nil,
            GlobalShortcutAction.toggleMute.rawAction:
                GlobalShortcutBinding(keyCode: 46, modifiers: [.option]),
        ]
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        let toggle = reloaded.globalShortcuts[GlobalShortcutAction.togglePlayback.rawAction]
        #expect(toggle??.keyCode == 49)
        #expect(toggle??.modifiers == [.command, .shift])

        let next = reloaded.globalShortcuts[GlobalShortcutAction.nextWallpaper.rawAction]
        #expect(next == .some(nil))

        let mute = reloaded.globalShortcuts[GlobalShortcutAction.toggleMute.rawAction]
        #expect(mute??.modifiers == [.option])
    }
}
