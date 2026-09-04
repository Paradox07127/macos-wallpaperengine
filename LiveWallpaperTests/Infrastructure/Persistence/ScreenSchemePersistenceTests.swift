import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Screen scheme persistence")
@MainActor
struct ScreenSchemePersistenceTests {
    private func sampleConfiguration() -> ScreenConfiguration {
        ScreenConfiguration(
            screenID: 91,
            wallpaper: .video(bookmarkData: Data([0xC0, 0xDE]))
        )
    }

    @Test("Saved schemes survive a fresh manager reading the same directory")
    func schemesRoundTripThroughSettingsManager() async throws {
        let scratch = try TestScratch.defaultsSuite("LiveWallpaperTests.screenSchemesRoundTrip")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenSchemes-\(UUID().uuidString)", isDirectory: true)

        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root),
            defaults: defaults
        )
        let scheme = ScreenScheme(
            name: "Desk setup",
            configuration: sampleConfiguration(),
            overlay: MonitorOverlayConfiguration(enabled: true, level: .front),
            sourceDisplayName: "Studio Display"
        )
        manager.saveScreenSchemes([scheme])
        #expect(manager.loadScreenSchemes().count == 1)

        // The write is queued off the MainActor; draining it is what makes the
        // second manager read a file rather than an empty directory.
        await manager.flushPendingConfigurationWrites()

        let reloaded = SettingsManager(
            directory: ConfigurationDirectory(root: root),
            defaults: defaults
        )
        let loaded = reloaded.loadScreenSchemes()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == scheme.id)
        #expect(loaded.first?.name == "Desk setup")
        #expect(loaded.first?.overlay.level == .front)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("screen-schemes.json")
                    .path(percentEncoded: false)
            )
        )

        await TestScratch.discard(root, flushing: manager, reloaded)
    }

    @Test("Resetting settings clears saved schemes and the shared store")
    func resetClearsSchemes() {
        // Reset already wipes bookmarks; a scheme archive left behind would be
        // orphaned state the user has no way to reach.
        let store = SchemeStore.shared
        store.add(
            name: "Desk setup",
            configuration: sampleConfiguration(),
            overlay: .default,
            sourceDisplayName: "Studio Display"
        )
        #expect(!store.schemes.isEmpty)

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)

        #expect(store.schemes.isEmpty)
        #expect(SettingsManager.shared.loadScreenSchemes().isEmpty)
    }
}
