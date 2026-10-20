import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("GlobalSettings partial update preserves WPE history", .serialized) @MainActor
struct GeneralSettingsRegressionTests {
    @Test("Saving with only pause/lock flags preserved must keep recentWPEImports")
    func savingPartialFieldsPreservesWPEHistory() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared

            let entry = WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: "preserve-me",
                    title: "Preserved",
                    originalType: .video,
                    sourceFolderBookmark: Data([0xAA]),
                    cacheRelativePath: "wpe-cache/preserve-me",
                    previewFileName: "preview.gif"
                ),
                importedAt: Date(timeIntervalSince1970: 100),
                lastUsedAt: Date(timeIntervalSince1970: 100)
            )
            manager.recordWPEImport(entry)
            #expect(manager.loadGlobalSettings().recentWPEImports.count == 1)

            var settings = manager.loadGlobalSettings()
            settings.globalPauseOnBattery = true
            settings.preservePlaybackOnLock = true
            settings.pauseOnFullScreen = false
            manager.saveGlobalSettings(settings)

            let after = manager.loadGlobalSettings()
            #expect(after.globalPauseOnBattery == true)
            #expect(after.recentWPEImports.count == 1)
            #expect(after.recentWPEImports.first?.origin.workshopID == "preserve-me")
        }
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }
}
