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
        await manager.flushPendingWrites()

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

    @Test("A scheme neither stores nor restores the weather layer")
    func schemeCarriesNoWeather() throws {
        var configuration = sampleConfiguration()
        configuration.particleEffect = .snow
        configuration.effectConfig.weatherReactive = true
        configuration.effectConfig.warmth = 5000
        let scheme = ScreenScheme(name: "Desk setup", configuration: configuration, overlay: .default)
        #expect(scheme.configuration.legacyWeatherOverlay == .default)
        #expect(scheme.configuration.effectConfig.warmth == 5000)

        // An archive written by an older build still has the weather values inside.
        var legacy = try JSONDecoder().decode(ScreenScheme.self, from: JSONEncoder().encode(scheme))
        legacy.configuration = configuration
        let applied = legacy.rebound(to: 7, fingerprint: "fp-7")
        #expect(applied.legacyWeatherOverlay == .default)
        #expect(applied.effectConfig.warmth == 5000)
    }

    @Test("Resetting settings clears saved schemes and the shared store")
    func resetClearsSchemes() {
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
